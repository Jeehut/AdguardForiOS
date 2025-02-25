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

import SafariAdGuardSDK
import DnsAdGuardSDK

/// This service initializes all shared services and puts them into ServiceLocator
final class StartupService : NSObject {

    static func initResources() -> AESharedResourcesProtocol {
        let locator = ServiceLocator.shared

        // init services
        
        let sharedResources: AESharedResourcesProtocol = AESharedResources()
        locator.addService(service: sharedResources)

        // Registering standard Defaults
        if let path = Bundle.main.path(forResource: "defaults", ofType: "plist"),
            let defs = NSDictionary(contentsOfFile: path)  as? [String: Any] {
            sharedResources.sharedDefaults().register(defaults: defs)
        }

        return sharedResources
    }

    static func start() {

        let locator = ServiceLocator.shared

        // init services

        let sharedResources: AESharedResourcesProtocol = locator.getService()!
        
        let networkService = ACNNetworking()
        locator.addService(service: networkService)

        let productInfo: ADProductInfoProtocol = ADProductInfo()
        locator.addService(service: productInfo)

        let httpRequestService = HttpRequestService()
        let adServiceWrapper = AdServicesWrapper()
        let adClientWrapper = AdClientWrapper()

        let adServiceHelper = AdServicesHelper(httpRequestService: httpRequestService,
                                               adServicesWrapper: adServiceWrapper)
        let iAdFrameworkHelper = IAdFrameworkHelper(adClientWrapper: adClientWrapper)
        let appleSearchAdsService = AppleSearchAdsService(adServicesHelper: adServiceHelper,
                                            iAdFrameworkHelper: iAdFrameworkHelper)

        let purchaseService: PurchaseServiceProtocol = PurchaseService(network: networkService, resources: sharedResources, productInfo: productInfo, appleSearchAdsService: appleSearchAdsService)
        purchaseService.start()
        locator.addService(service: purchaseService)

        let sharedUrls = SharedStorageUrls()
        let preloadedFilesManager = PreloadedFilesManager(sharedStorageUrls: sharedUrls)
        try! preloadedFilesManager.processPreloadedFiles()

        /* Initializing SDK */
        let safariProtectionConfiguration = SafariConfiguration(
            resources: sharedResources,
            isProPurchased: purchaseService.isProPurchased
        )
        let defaultConfiguration = SafariConfiguration.defaultConfiguration()

        let dnsProtectionConfiguration = DnsConfiguration(
            resources: sharedResources,
            isProPurchased: purchaseService.isProPurchased
        )
        let defaultDnsProtectionConfiguration = DnsConfiguration.defaultConfiguration()

        // TODO: - try! is bad
        let dnsProtection: DnsProtectionProtocol = try! DnsProtection(configuration: dnsProtectionConfiguration,
                                          defaultConfiguration: defaultDnsProtectionConfiguration,
                                          userDefaults: sharedResources.sharedDefaults(),
                                          filterFilesDirectoryUrl: sharedUrls.dnsFiltersFolderUrl)

        // TODO: - try! is bad
        let safariProtection: SafariProtectionProtocol = try! SafariProtection(
            configuration: safariProtectionConfiguration,
            defaultConfiguration: defaultConfiguration,
            filterFilesDirectoryUrl: sharedUrls.filtersFolderUrl,
            dbContainerUrl: sharedUrls.dbFolderUrl,
            jsonStorageUrl: sharedUrls.cbJsonsFolderUrl,
            userDefaults: sharedResources.sharedDefaults(),
            dnsBackgroundFetchUpdater: dnsProtection)

        let networkUtils: NetworkUtilsProtocol = NetworkUtils()
        locator.addService(service: networkUtils)

        let dnsProvidersManager: DnsProvidersManagerProtocol = try! DnsProvidersManager(configuration: dnsProtectionConfiguration, userDefaults: sharedResources.sharedDefaults(), networkUtils: networkUtils)

        locator.addService(service: safariProtection)
        locator.addService(service: dnsProtection)
        locator.addService(service: dnsProvidersManager)

        let bootstrapsHelper: BootstrapsHelperProtocol = BootstrapsHelper(networkUtils: networkUtils)
        locator.addService(service: bootstrapsHelper)

        /* End of initializing SDK */

        let configuration: ConfigurationServiceProtocol = ConfigurationService(purchaseService: purchaseService, resources: sharedResources, safariProtection: safariProtection)
        locator.addService(service: configuration)

        let networkSettingsService: NetworkSettingsServiceProtocol = NetworkSettingsService(resources: sharedResources)
        locator.addService(service: networkSettingsService)

        let nativeDnsManager: NativeDnsSettingsManagerProtocol = NativeDnsSettingsManager(networkSettingsService: networkSettingsService, dnsProvidersManager: dnsProvidersManager, configuration: configuration, resources: sharedResources)
        locator.addService(service: nativeDnsManager)

        let vpnManager: VpnManager = VpnManager(resources: sharedResources, configuration: configuration, networkSettings: networkSettingsService)
        locator.addService(service: vpnManager as VpnManagerProtocol)

        let dnsConfigAssistant: DnsConfigManagerAssistantProtocol = DnsConfigManagerAssistant(vpnManager: vpnManager, nativeDnsManager: nativeDnsManager, resource: sharedResources)
        locator.addService(service: dnsConfigAssistant)

        let complexProtection: ComplexProtectionServiceProtocol = ComplexProtectionService(resources: sharedResources, configuration: configuration, vpnManager: vpnManager, productInfo: productInfo, nativeDnsSettingsManager: nativeDnsManager, safariProtection: safariProtection)
        locator.addService(service: complexProtection)

        vpnManager.complexProtection = complexProtection
        vpnManager.checkVpnInstalled { _ in }

        let themeService: ThemeServiceProtocol = ThemeService(configuration)
        locator.addService(service: themeService)

        let keyChainService: KeychainServiceProtocol = KeychainService(resources: sharedResources)
        locator.addService(service: keyChainService)

        let supportService: SupportServiceProtocol = SupportService(resources: sharedResources, configuration: configuration, complexProtection: complexProtection, productInfo: productInfo, keyChainService: keyChainService, safariProtection: safariProtection, networkSettings: networkSettingsService, dnsProvidersManager: dnsProvidersManager, dnsProtection: dnsProtection)
        locator.addService(service: supportService)

        let userNotificationService: UserNotificationServiceProtocol = UserNotificationService()
        locator.addService(service: userNotificationService)

        let dnsTrackers: DnsTrackersProviderProtocol = try! DnsTrackersProvider()
        locator.addService(service: dnsTrackers)

        let rateService: RateAppServiceProtocol = RateAppService(resources: sharedResources, configuration: configuration)
        locator.addService(service: rateService)

        let domainsParserService: DomainParserServiceProtocol = DomainParserService()
        locator.addService(service: domainsParserService)

        let setappService: SetappServiceProtocol = SetappService(purchaseService: purchaseService, resources: sharedResources)
        locator.addService(service: setappService)

        let activityStatistics: ActivityStatisticsProtocol = try! ActivityStatistics(statisticsDbContainerUrl: sharedUrls.statisticsFolderUrl)
        locator.addService(service: activityStatistics)

        let chartStatistics: ChartStatisticsProtocol = try! ChartStatistics(statisticsDbContainerUrl: sharedUrls.statisticsFolderUrl)
        locator.addService(service: chartStatistics)

        let dnsLogStatistics: DnsLogStatisticsProtocol = try! DnsLogStatistics(statisticsDbContainerUrl: sharedUrls.statisticsFolderUrl)
        locator.addService(service: dnsLogStatistics)

        let dnsLogRecordsHelper = DnsLogRecordHelper(dnsProtection: dnsProtection, dnsTrackers: dnsTrackers, domainConverter: DomainConverter(), dnsConfigAssistant: dnsConfigAssistant)
        locator.addService(service: dnsLogRecordsHelper)

        let settingsReset: SettingsResetServiceProtocol = SettingsResetService(
            vpnManager: vpnManager,
            resources: sharedResources,
            purchaseService: purchaseService,
            safariProtection: safariProtection,
            dnsProtection: dnsProtection,
            dnsProvidersManager: dnsProvidersManager,
            nativeDnsManager: nativeDnsManager,
            chartStatistics: chartStatistics,
            activityStatistics: activityStatistics,
            dnsLogStatistics: dnsLogStatistics
        )
        locator.addService(service: settingsReset)

        let migrationService: MigrationServiceProtocol = MigrationService(
            resources: sharedResources,
            networking: networkService,
            configurationService: configuration,
            productInfo: productInfo,
            safariProtection: safariProtection,
            dnsProvidersManager: dnsProvidersManager,
            networkSettings: networkSettingsService,
            dnsConfigAssistant: dnsConfigAssistant,
            settingsResetor: settingsReset,
            dnsProtection: dnsProtection
        )
        locator.addService(service: migrationService)
    }
}
