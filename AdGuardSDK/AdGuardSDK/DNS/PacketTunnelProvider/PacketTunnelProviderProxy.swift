//
// This file is part of Adguard for iOS (https://github.com/AdguardTeam/AdguardForiOS).
// Copyright © Adguard Software Limited. All rights reserved.
//
// Adguard for iOS is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Adguard for iOS is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Adguard for iOS. If not, see <http://www.gnu.org/licenses/>.
//

import NetworkExtension
import AGDnsProxy
import SharedAdGuardSDK

protocol PacketTunnelProviderProxyDelegate: AnyObject {
    func setTunnelSettings(_ settings: NETunnelNetworkSettings?, _ completionHandler: ((Error?) -> Void)?)
    func readPackets(completionHandler: @escaping ([Data], [NSNumber]) -> Void)
    func writePackets(_ packets: [Data], _ protocols: [NSNumber])
    func cancelTunnel(with error: Error?)
}

// MARK: - PacketTunnelProviderProxy

/// This methods are taken from `NEPacketTunnelProvider`, look it up for more information
protocol PacketTunnelProviderProxyProtocol: AnyObject {
    var delegate: PacketTunnelProviderProxyDelegate? { get set }
    func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void)
    func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void)
    func sleep(completionHandler: @escaping () -> Void)
    func wake()
    func networkChanged()
}

/**
 Proxy is a design pattern, that perfectly fits it this case. You can find more info here https://refactoring.guru/design-patterns/proxy
 We use this tunnel proxy to be able to test tunnel behaviour
 */
final class PacketTunnelProviderProxy: PacketTunnelProviderProxyProtocol {

    weak var delegate: PacketTunnelProviderProxyDelegate?

    // MARK: - Private variables

    private var shouldProcessPackets = false
    private let readPacketsQueue = DispatchQueue(label: "DnsAdGuardSDK.PacketTunnelProviderProxy.readPacketsQueue")
    private let restartQueue = DispatchQueue(label: "DnsAdGuardSDK.PacketTunnelProviderProxy.restartQueue")

    /* Services */
    private let tunnelAddresses: PacketTunnelProvider.Addresses
    private let dnsProxy: DnsProxyProtocol
    private let dnsConfiguration: DnsConfigurationProtocol
    private let tunnelSettings: PacketTunnelSettingsProviderProtocol
    private let providersManager: DnsProvidersManagerProtocol
    private let networkUtils: NetworkUtilsProtocol
    private let addresses: PacketTunnelProvider.Addresses

    // MARK: - Initialization

    init(
        isDebugLogs: Bool,
        tunnelAddresses: PacketTunnelProvider.Addresses,
        dnsProxy: DnsProxyProtocol,
        dnsConfiguration: DnsConfigurationProtocol,
        tunnelSettings: PacketTunnelSettingsProviderProtocol,
        providersManager: DnsProvidersManagerProtocol,
        networkUtils: NetworkUtilsProtocol,
        addresses: PacketTunnelProvider.Addresses
    ) {
        self.tunnelAddresses = tunnelAddresses
        self.dnsProxy = dnsProxy
        self.dnsConfiguration = dnsConfiguration
        self.tunnelSettings = tunnelSettings
        self.providersManager = providersManager
        self.networkUtils = networkUtils
        self.addresses = addresses

        setupLogger(isDebugLogs: isDebugLogs)
    }

    // MARK: - Internal methods

    func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        startTunnel(completionHandler)
    }

    func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        stopPacketHanding()
        dnsProxy.stop()
        completionHandler()
    }

    func sleep(completionHandler: @escaping () -> Void) {
        // Maybe we will use it, like we do in VPN
    }

    func wake() {
        // Maybe we will use it, like we do in VPN
    }

    func networkChanged() {
        // Restarting tunnel synchronously in a separate queue to avoid races
        restartQueue.async { [weak self] in
            guard let self = self else { return }

            let shouldRestartWhenNetworkChanges = self.dnsConfiguration.lowLevelConfiguration.restartByReachability
            Logger.logInfo("(PacketTunnelProviderProxy) - networkChanged; shouldRestartWhenNetworkChanges=\(shouldRestartWhenNetworkChanges)")

            // Stop packet handling and dnsProxy right away
            Logger.logInfo("(PacketTunnelProviderProxy) - stopping packet handling")
            self.stopPacketHanding()

            Logger.logInfo("(PacketTunnelProviderProxy) - stopping dnsProxy")
            self.dnsProxy.stop()

            // If the user has enabled "restartByReachability", we reinitialize the whole PacketTunnelProvider on every network change
            // This is done by cancelling tunnel (it will be then restarted back automatically due to the on-demand rules)
            if shouldRestartWhenNetworkChanges {
                Logger.logInfo("(PacketTunnelProviderProxy) - cancelling tunnel")
                self.delegate?.cancelTunnel(with: nil)
                return
            }

            // This is the default behavior, we restart proxy internally without reinitializing PacketTunnelProvider.
            let group = DispatchGroup()
            group.enter()
            Logger.logInfo("(PacketTunnelProviderProxy) - starting the tunnel")
            self.startTunnel { [weak self] error in
                if let error = error {
                    Logger.logError("(PacketTunnelProviderProxy) - networkChanged; Error: \(error)")
                    self?.delegate?.cancelTunnel(with: error)
                } else {
                    Logger.logInfo("(PacketTunnelProviderProxy) - networkChanged; Successfully restarted proxy after the network change")
                }
                group.leave()
            }
            group.wait()
        }
    }

    // MARK: - Private methods

    /// Starts tunnel. Returns error if occurred
    private func startTunnel(_ onTunnelStarted: @escaping (Error?) -> Void) {
        updateTunnelSettings { [weak self] result in
            guard let self = self else {
                let error = CommonError.missingSelf
                Logger.logError("(PacketTunnelProviderProxy) - startTunnel; Error: \(error)")
                onTunnelStarted(error)
                return
            }

            switch result {
            case .success(let systemDnsAddresses):
                let error = self.startDnsProxy(with: systemDnsAddresses)
                if error == nil {
                    self.startPacketHanding()
                }
                onTunnelStarted(error)
            case .error(let error):
                onTunnelStarted(error)
            }
        }
    }

    /// Updates tunnel settings. Returns system DNS addresses if success and error occurred otherwise
    private func updateTunnelSettings(_ onSettingsUpdated: @escaping (_ result: Result<[String]>) -> Void) {
        let lowLevelConfig = dnsConfiguration.lowLevelConfiguration

        let allSystemServers = networkUtils.systemDnsServers

        Logger.logInfo("updateTunnelSettings with system servers: \(allSystemServers)")

        let systemDnsServers = allSystemServers.filter { $0 != addresses.localDnsIpv4 && $0 != addresses.localDnsIpv6 }

        let hasFallbacks = lowLevelConfig.fallbackServers?.isEmpty == false
        let hasBootstraps = lowLevelConfig.bootstrapServers?.isEmpty == false

        // Check if user's already provided all needed settings
        if providersManager.activeDnsServer.upstreams.count > 0 && hasFallbacks && hasBootstraps || !systemDnsServers.isEmpty {
            Logger.logInfo("(PacketTunnelProviderProxy) - updateTunnelSettings; All settings we need are set by the user, starting tunnel now")

            // Setting tunnel settings
            setTunnelSettings { error in
                if let error = error {
                    onSettingsUpdated(.error(error))
                } else {
                    onSettingsUpdated(.success(systemDnsServers))
                }
            }
            return
        }

        Logger.logInfo("(PacketTunnelProviderProxy) - updateTunnelSettings; Upstreams or fallbacks are not set by the user. Get system DNS now")

        // Setting empty settings to read system DNS servers
        // If we don't set them we wil be unable to read system DNS servers
        // and will be reading servers that we did set previously
        delegate?.setTunnelSettings(nil) { error in
            if let error = error {
                Logger.logError("(PacketTunnelProviderProxy) - updateTunnelSettings; Error setting empty settings; Error: \(error)")
                onSettingsUpdated(.error(error))
                return
            } else {
                Logger.logInfo("(PacketTunnelProviderProxy) - updateTunnelSettings; Successfully set empty settings")
            }

            // https://github.com/AdguardTeam/AdguardForiOS/issues/1499
            // sometimes we get empty list of system dns servers.
            // Here we add a pause after setting the empty settings.
            // Perhaps this will eliminate the situation with an empty dns list
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in

                // Reading system DNS servers with empty tunnel settings
                let systemIps = self?.networkUtils.systemDnsServers ?? []

                // Setting tunnel settings when system DNS servers obtained
                self?.setTunnelSettings { error in
                    if let error = error {
                        onSettingsUpdated(.error(error))
                    } else {
                        onSettingsUpdated(.success(systemIps))
                    }
                }
            }
        }
    }

    /// Sets tunnel settings based on user settings
    private func setTunnelSettings(_ onSettingsSet: @escaping (Error?) -> Void) {
        // Get tunnel mode user did select
        let tunnelMode = dnsConfiguration.lowLevelConfiguration.tunnelMode
        Logger.logInfo("(PacketTunnelProviderProxy) - setTunnelSettings; Start with tunnelMode=\(tunnelMode)")

        let full = tunnelMode != .split
        let withoutIcon = tunnelMode == .fullWithoutVpnIcon

        // Create tunnel settings based on user settings
        let tunnelSettings = tunnelSettings.createSettings(full: full, withoutVpnIcon: withoutIcon)

        // Tell tunnel to set new tunnel settings
        delegate?.setTunnelSettings(tunnelSettings) { error in
            if let error = error {
                Logger.logError("(PacketTunnelProviderProxy) - setTunnelSettings; Error setting settings=\(tunnelSettings); Error: \(error)")
            } else {
                Logger.logInfo("(PacketTunnelProviderProxy) - setTunnelSettings; Successfully set settings=\(tunnelSettings)")
            }
            onSettingsSet(error)
        }
    }

    /// Starts DNS-lib proxy. Returns error if occurred or nil otherwise
    private func startDnsProxy(with systemDnsAddresses: [String]) -> Error? {
        let systemUpstreams = getSystemDnsAddresses(systemDnsAddresses)
        return dnsProxy.start(systemUpstreams)
    }

    /// Initializes DNS-lib logger
    private func setupLogger(isDebugLogs: Bool) {
        AGLogger.setLevel(isDebugLogs ? .AGLL_DEBUG : .AGLL_INFO)
        AGLogger.setCallback { level, msg, length in
            guard let msg = msg else { return }
            let data = Data(bytes: msg, count: Int(length))
            if let str = String(data: data, encoding: .utf8) {
                switch (level) {
                case AGLogLevel.AGLL_INFO:
                    Logger.logInfo("(DnsLibs) - \(str)")
                case AGLogLevel.AGLL_ERR, AGLogLevel.AGLL_WARN:
                    Logger.logError("(DnsLibs) - \(str)")
                default:
                    Logger.logDebug("(DnsLibs) - \(str)")
                }
            }
        }
    }

    /// Returns `DnsUpstream` objects from system DNS servers
    private func getSystemDnsAddresses(_ systemDnsAddresses: [String]) -> [DnsUpstream] {
        var systemServers = systemDnsAddresses
        if systemServers.isEmpty {
            systemServers = tunnelAddresses.defaultSystemDnsServers
        }

        return systemServers.map {
            let prot = try? networkUtils.getProtocol(from: $0)
            return DnsUpstream(upstream: $0, protocol: prot ?? .dns)
        }
    }

    /// Starts processing packets
    private func startPacketHanding() {
        readPacketsQueue.async { [weak self] in
            guard self?.shouldProcessPackets == false else { return }

            self?.shouldProcessPackets = true
            self?.delegate?.readPackets { [weak self] packets, protocols in
                self?.handlePackets(packets, protocols)
            }
        }
    }

    /// Stops processing packets
    private func stopPacketHanding() {
        readPacketsQueue.async { [weak self] in
            self?.shouldProcessPackets = false
        }
    }

    /// Processes passed packets with DNS-lib, writes them if response is received
    private func handlePackets(_ packets: [Data], _ protocols: [NSNumber]) {
        for (index, packet) in packets.enumerated() {
            dnsProxy.resolve(dnsRequest: packet) { [weak self] reply in
                if let reply = reply {
                    self?.delegate?.writePackets([reply], [protocols[index]])
                }
            }
        }

        delegate?.readPackets { [weak self] packets, protocols in
            if self?.shouldProcessPackets == true {
                self?.handlePackets(packets, protocols)
            }
        }
    }
}
