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

import SharedAdGuardSDK

// MARK: - FiltersUpdateResult

/**
 This object is needed to provide user with information about filters and groups meta updates
 If you want to get more info about filters or groups themselves you can searh them by filter or group id respectively
 */
public struct FiltersUpdateResult {
    public var updatedFilterIds: [Int] = [] // Identifiers of filters that were successfully updated
    public var failedFilterIds: [Int] = [] // Identifiers of filters that failed to update
    public var addedFilterIds: [Int] = [] // Identifiers of filters that were successfully added while updating
    public var removedFiltersIds: [Int] = [] // Identifiers of filters that were successfully removed
    public var error: Error? // If this object exists and was passed till SafariProtection the only step where error can occur is Reloading CBs

    public init(updatedFilterIds: [Int] = [], failedFilterIds: [Int] = [], addedFilterIds: [Int] = [], removedFiltersIds: [Int] = [], error: Error? = nil) {
        self.updatedFilterIds = updatedFilterIds
        self.failedFilterIds = failedFilterIds
        self.addedFilterIds = addedFilterIds
        self.removedFiltersIds = removedFiltersIds
        self.error = error
    }
}

// MARK: - FiltersService

protocol FiltersServiceProtocol: ResetableAsyncProtocol {
    /**
     Returns all Groups objects
     */
    var groups: [SafariGroup] { get }

    /**
     Returns last safari filters update date
     */
    var lastFiltersUpdateCheckDate: Date { get }

    /**
     Checks update conditions for meta and updates them if needed
     - Parameter forcibly: ignores update conditions and immediately updates filters
     - Parameter onFiltersUpdated: closure to handle update **result**
     */
    func updateAllMeta(forcibly: Bool, onFiltersUpdated: @escaping (_ result: Result<FiltersUpdateResult>) -> Void)

    /**
     Enables or disables group by **group id**
     - Parameter id: id of the group that should be enabled/disabled
     - Parameter enabled: new group state
     */
    func setGroup(withId id: Int, enabled: Bool) throws

    /**
     Enables or disables filter by **filter id** and **group id**
     - Parameter id: id of the filter that should be enabled/disabled
     - Parameter groupId: id of the group that filter belongs
     - Parameter enabled: new filter state
     */
    func setFilter(withId id: Int, _ groupId: Int, enabled: Bool) throws


    // MARK: - Custom filters methods

    /**
     Adds **customFilter**
     - Parameter customFilter: Meta data of filter
     - Parameter enabled: new filter state
     - Parameter onFilterAdded: closure to handle error if exists
     */
    func add(customFilter: ExtendedCustomFilterMetaProtocol, enabled: Bool, _ onFilterAdded: @escaping (_ error: Error?) -> Void)

    /**
     Deletes filter with **id**
     - Parameter id: id of the filter that should be deleted
     - throws: Can throw error if error occured while deleting filter
     */
    func deleteCustomFilter(withId id: Int) throws

    /**
     Renames filter with **id** to **name**
     - Parameter id: id of the filter that should be deleted
     - Parameter name: new filter name
     - throws: Can throw error if error occured while renaming filter
     */
    func renameCustomFilter(withId id: Int, to name: String) throws

    /**
     Enable predefined groups and filters
     - throws: Can throw error if error occured while setuping
     */
    func enablePredefinedGroupsAndFilters() throws
    // TODO: - Refactor it later
    // It is a crutch because we add some data to DB while migrating custom filters
    // If we don't reinitialize groups after migration we'll get inconsistency of states

    /// Reinitializes groups with filters with actual info from database
    func reinitializeGroups() throws
}

/*
 This class is a proxy between filters, groups objects and SQLite database.
 It is used to get or modify filters objects.
 */
final class FiltersService: FiltersServiceProtocol {

    // MARK: - FilterServiceError

    enum FilterServiceError: Error, CustomDebugStringConvertible {
        case invalidCustomFilterId(filterId: Int)
        case updatePeriodError(lastUpdateTime: Int)
        case missedFilterDownloadPage(filterName: String)
        case nonExistingGroupId(groupId: Int)
        case nonExistingFilterId(filterId: Int)
        case customFilterAlreadyExists(downloadUrl: String)
        case unknownError

        var debugDescription: String {
            switch self {
            case .invalidCustomFilterId(let filterId): return "Custom filter id must be greater or equal than \(CustomFilterMeta.baseCustomFilterId), actual filter id=\(filterId)"
            case .updatePeriodError(let lastUpdateTime): return "Last update was \(lastUpdateTime) hours ago. Minimum update period is \(Int(FiltersService.updatePeriod / 3600)) hours"
            case .missedFilterDownloadPage(let filterName): return "Filter download page is missed for filter with name \(filterName)"
            case .nonExistingGroupId(groupId: let id): return "Group with id: \(id) not exists"
            case .nonExistingFilterId(filterId: let id): return "Filter with id: \(id) not exists"
            case .customFilterAlreadyExists(let downloadUrl): return "Custom filter with download URL = \(downloadUrl) already exists"
            case .unknownError: return "Unknown error"
            }
        }
    }

    // MARK: - Public properties

    var groups: [SafariGroup] { _groupsAtomic.wrappedValue }

    var lastFiltersUpdateCheckDate: Date {
        workingQueue.sync { userDefaultsStorage.lastFiltersUpdateCheckDate }
    }

    /// Sometimes we don't want some filters to exist in our app
    /// So this list of identifiers is for such filters
    /// 208 - Online Malicious URL Blocklist; Should be removed because it contains `malware` word in it's description;
    /// There was a case when Apple declined our app because there can't be any malware on iOS :)
    private static let restrictedFilterIds = [208]

    // MARK: - Private properties

    // Filters update period; We should check filters updates once per 6 hours
    private static let updatePeriod: TimeInterval = 3600 * 6

    // Helper variable to make groups variable thread safe
    @Atomic private var groupsAtomic: [SafariGroup] = []

    // Working queue
    private let workingQueue = DispatchQueue(label: "AdGuardSDK.FiltersService.workingQueue")

    // Queue to call completion blocks
    private let completionQueue = DispatchQueue(label: "AdGuardSDK.FiltersService.completionQueue")

    /* Services */
    let configuration: SafariConfigurationProtocol
    let filterFilesStorage: FilterFilesStorageProtocol
    let metaStorage: MetaStorageProtocol
    let userDefaultsStorage: UserDefaultsStorageProtocol
    let metaParser: CustomFilterMetaParserProtocol
    let apiMethods: SafariProtectionApiMethodsProtocol

    private lazy var suitableLanguages: [String] = {
        return configuration.currentLocale.getSuitableLanguages(delimiter: .underScore)
    }()

    // MARK: - Initialization

    init(
        configuration: SafariConfigurationProtocol,
        filterFilesStorage: FilterFilesStorageProtocol,
        metaStorage: MetaStorageProtocol,
        userDefaultsStorage: UserDefaultsStorageProtocol,
        metaParser: CustomFilterMetaParserProtocol = CustomFilterMetaParser(),
        apiMethods: SafariProtectionApiMethodsProtocol) throws {

        Logger.logInfo("(FiltersService) - init start")

        self.configuration = configuration
        self.filterFilesStorage = filterFilesStorage
        self.metaStorage = metaStorage
        self.userDefaultsStorage = userDefaultsStorage
        self.metaParser = metaParser
        self.apiMethods = apiMethods

        try initGroups()

        Logger.logInfo("(FiltersService) - init end")
    }

    // MARK: - Public methods

    func updateAllMeta(forcibly: Bool, onFiltersUpdated: @escaping (_ result: Result<FiltersUpdateResult>) -> Void) {
        var preconditionError: Error?
        var updateMetadataError: Error?
        var groupsUpdateError: Error?

        var updateResult = FiltersUpdateResult()

        let comletionGroup = DispatchGroup()

        workingQueue.async(group: comletionGroup) { [weak self] in
            guard let self = self else {
                preconditionError = CommonError.missingSelf
                return
            }

            // Check update conditions
            let now = Date().timeIntervalSince(self.userDefaultsStorage.lastFiltersUpdateCheckDate)
            if now < Self.updatePeriod && !forcibly {
                preconditionError = FilterServiceError.updatePeriodError(lastUpdateTime: Int(now / 3600))
                Logger.logError("(FiltersService) - Update period error: \(preconditionError!)")
                return
            }

            // Notify that filters started to update
            NotificationCenter.default.filtersUpdateStarted()

            var updatedFilterFilesIds: Set<Int> = []

            // Update predefined filters file content
            let group = DispatchGroup()
            group.enter()
            self.updatePredefinedFiltersFileContent { result in
                updatedFilterFilesIds = result.0
                updateResult.failedFilterIds = result.1.sorted()

                group.leave()
            }
            // Wait when files finish updating
            group.wait()

            // Update predefined filters metadata
            group.enter()
            self.updateMetadataForPredefinedFilters(withIds: updatedFilterFilesIds) { result in
                switch result {
                case .success(let metaResult):
                    updateResult.addedFilterIds = metaResult.0
                    updateResult.removedFiltersIds = metaResult.1
                    updateResult.updatedFilterIds = metaResult.2
                case .error(let error):
                    updateMetadataError = error
                }
                group.leave()
            }
            // Wait when predefined meta finishes updating
            group.wait()

            // Update custom filters files and meta
            group.enter()
            self.updateCustomFilters { result in
                updateResult.updatedFilterIds += result.updatedFilterIds
                updateResult.failedFilterIds += result.failedFilterIds
                group.leave()
            }
            group.wait()

            // Fill groups with actual objects
            // Even if updateMetadataError exists we update groups variable to make it actual as DB could change
            do {
                try self.initGroups()
            } catch {
                groupsUpdateError = error
                Logger.logError("(FiltersService) - updateAllMeta; Localized groups fetching error: \(error)")
            }

            // Notify that filters finished updating
            NotificationCenter.default.filtersUpdateFinished()

            // Save filters update time if filters were successfully updated
            if preconditionError == nil, updateMetadataError == nil, groupsUpdateError == nil {
                self.userDefaultsStorage.lastFiltersUpdateCheckDate = Date()
            }
        }
        comletionGroup.notify(queue: completionQueue) {
            if let preconditionError = preconditionError {
                onFiltersUpdated(.error(preconditionError))
            }
            else if let updateMetadataError = updateMetadataError {
                onFiltersUpdated(.error(updateMetadataError))
            }
            else if let groupsUpdateError = groupsUpdateError {
                onFiltersUpdated(.error(groupsUpdateError))
            }
            else {
                onFiltersUpdated(.success(updateResult))
            }
        }
    }

    func setGroup(withId id: Int, enabled: Bool) throws {
        try workingQueue.sync {
            do {
                try metaStorage.setGroup(withId: id, enabled: enabled)
                if let groupIndex = groupsAtomic.firstIndex(where: { $0.groupId == id }) {
                    _groupsAtomic.mutate { $0[groupIndex].isEnabled = enabled }
                    Logger.logDebug("(FiltersService) - setGroup; Group with id=\(id) was successfully set to enabled=\(enabled)")
                } else {
                    Logger.logDebug("(FiltersService) - setGroup; Group with id=\(id) not exists")
                    throw FilterServiceError.nonExistingGroupId(groupId: id)
                }
            } catch {
                Logger.logError("(FiltersService) - setGroup; Error setting group with id=\(id) to enabled=\(enabled): \(error)")
                throw error
            }
        }
    }

    func setFilter(withId id: Int, _ groupId: Int, enabled: Bool) throws {
        try workingQueue.sync {
            do {
                try metaStorage.setFilter(withId: id, enabled: enabled)
                if let groupIndex = groupsAtomic.firstIndex(where: { $0.groupType.id == groupId }),
                   let filterIndex = groupsAtomic[groupIndex].filters.firstIndex(where: { $0.filterId == id }) {

                    _groupsAtomic.mutate { $0[groupIndex].filters[filterIndex].isEnabled = enabled }
                    Logger.logDebug("(FiltersService) - setFilter; Filter id=\(id); group id=\(groupId) was successfully set to enabled=\(enabled)")
                } else {
                    Logger.logDebug("(FiltersService) - setFilter; Filter id=\(id) or group id=\(groupId) not exists")
                    throw FilterServiceError.nonExistingFilterId(filterId: id)
                }

            } catch {
                Logger.logError("(FiltersService) - setFilter; Error setting filtrer with id=\(id); group id=\(groupId) to enabled=\(enabled): \(error)")
                throw error
            }
        }
    }

    func add(customFilter: ExtendedCustomFilterMetaProtocol, enabled: Bool, _ onFilterAdded: @escaping (_ error: Error?) -> Void) {
        workingQueue.async { [weak self] in
            guard let self = self,
                  let filterDownloadPage = customFilter.filterDownloadPage,
                  let subscriptionUrl = URL(string: filterDownloadPage)
            else {
                let error = FilterServiceError.missedFilterDownloadPage(filterName: customFilter.name ?? "nil")
                Logger.logError("(FiltersService) - add custom filter; \(error)")
                DispatchQueue.main.async { onFilterAdded(error) }
                return
            }

            // check filter already exists
            let customGroup = self.groupsAtomic.first(where: { $0.groupType == .custom })!

            let exists = customGroup.filters.contains { $0.filterDownloadPage == customFilter.filterDownloadPage }

            if exists {
                onFilterAdded(FilterServiceError.customFilterAlreadyExists(downloadUrl: customFilter.filterDownloadPage ?? ""))
                return
            }

            let filterId = self.metaStorage.nextCustomFilterId
            let filterToAdd = ExtendedFiltersMeta.Meta(customFilterMeta: customFilter, filterId: filterId, displayNumber: filterId, group: customGroup)

            do {
                try self.addCustomFilterSync(withId: filterId, subscriptionUrl: subscriptionUrl)
                try self.metaStorage.add(filter: filterToAdd, enabled: enabled)
            }
            catch {
                Logger.logError("(FiltersService) - add custom filter; Error while adding: \(error)")
                self.completionQueue.async { onFilterAdded(error) }
                return
            }

            let customGroupIndex = self.groupsAtomic.firstIndex(where: { $0.groupType == .custom })!
            let safariFilter = SafariGroup.Filter(customFilter: customFilter,
                                                  filterId: filterId,
                                                  isEnabled: true,
                                                  group: self.groupsAtomic[customGroupIndex],
                                                  displayNumber: filterId)
            self._groupsAtomic.mutate { $0[customGroupIndex].filters.append(safariFilter) }

            Logger.logInfo("(FiltersService) - add customFilter; Custom filter with id = \(filterId) was successfully added")
            self.completionQueue.async { onFilterAdded(nil) }
        }
    }

    func deleteCustomFilter(withId id: Int) throws {
        try workingQueue.sync {
            guard id >= CustomFilterMeta.baseCustomFilterId else {
                let error = FilterServiceError.invalidCustomFilterId(filterId: id)
                Logger.logError("(FiltersService) - deleteCustomFilter; Invalid custom filter id: \(error)")
                throw error
            }
            try metaStorage.deleteFilter(withId: id)
            try filterFilesStorage.deleteFilter(withId: id)

            let customGroupIndex = groupsAtomic.firstIndex(where: { $0.groupType == .custom })!
            _groupsAtomic.mutate { $0[customGroupIndex].filters.removeAll(where: { $0.filterId == id }) }
            Logger.logDebug("(FiltersService) - deleteCustomFilter; Custom filter with id = \(id) was successfully deleted")
        }
    }

    func renameCustomFilter(withId id: Int, to name: String) throws {
        try workingQueue.sync {
            guard id >= CustomFilterMeta.baseCustomFilterId else {
                let error = FilterServiceError.invalidCustomFilterId(filterId: id)
                Logger.logError("(FiltersService) - renameCustomFilter; Invalid custom filter id: \(error)")
                throw error
            }
            try metaStorage.renameFilter(withId: id, name: name)
            let customGroupIndex = groupsAtomic.firstIndex(where: { $0.groupType == .custom })!
            let filterIndex = groupsAtomic[customGroupIndex].filters.firstIndex(where: { $0.filterId == id })!
            let filter = groupsAtomic[customGroupIndex].filters[filterIndex]
            let newFilter = SafariGroup.Filter(name: name,
                                               description: filter.description,
                                               isEnabled: filter.isEnabled,
                                               filterId: filter.filterId,
                                               version: filter.version,
                                               lastUpdateDate: filter.lastUpdateDate,
                                               group: filter.group,
                                               displayNumber: filter.displayNumber,
                                               languages: filter.languages,
                                               tags: filter.tags,
                                               homePage: filter.homePage,
                                               filterDownloadPage: filter.filterDownloadPage,
                                               rulesCount: filter.rulesCount)

            _groupsAtomic.mutate { $0[customGroupIndex].filters[filterIndex] = newFilter }
            Logger.logDebug("(FiltersService) - renameCustomFilter; Custom filter with id = \(id) was successfully renamed")
        }
    }

    func reinitializeGroups() throws {
        try workingQueue.sync {
            try self.initGroups()
        }
    }

    /* Resets all data stored to default */
    func reset(_ onResetFinished: @escaping (Error?) -> Void) {
        workingQueue.async { [weak self] in
            Logger.logInfo("(FiltersService) - reset start")

            guard let self = self else {
                onResetFinished(CommonError.missingSelf)
                return
            }

            do {
                try self.metaStorage.reset()
                try self.filterFilesStorage.reset()
                try self.filterFilesStorage.unzipPredefinedFiltersIfNeeded()
            }
            catch {
                Logger.logInfo("(FiltersService) - reset; Error: \(error)")
                onResetFinished(error)
                return
            }

            self.userDefaultsStorage.lastFiltersUpdateCheckDate = Date(timeIntervalSince1970: 0.0)

            self.updateAllMeta(forcibly: true) { result in
                if case .error(let error) = result {
                    Logger.logError("(FiltersService) - reset; Error updating meta after reset; Error: \(error)")
                } else {
                    Logger.logInfo("(FiltersService) - reset; Successfully reset all groups")
                }

                do {
                    try self.initGroups()
                    Logger.logInfo("(FiltersService) - reset; Successfully updated groups")
                }
                catch {
                    Logger.logError("(FiltersService) - reset; Error updating groups; Error: \(error)")
                    onResetFinished(error)
                    return
                }

                switch result {
                case .success(_): onResetFinished(nil)
                case .error(let error): onResetFinished(error)
                }
            }
        }
    }

    func enablePredefinedGroupsAndFilters() throws {
        try workingQueue.sync {
            // The first element of the `suitableLanguages` list is the language code with the highest priority.
            let lang = suitableLanguages.first ?? Locale.defaultLanguageCode
            try enablePredefinedGroupsAndFiltersInternal(with: groups, currentLanguage: lang)
            try self.initGroups()
        }
    }

    // MARK: - Private methods

    private func initGroups() throws {
        try _groupsAtomic.mutate { $0 = try getAllLocalizedGroups() }
        workingQueue.async {
            // Schedule an async operation that updates filters rule counts.
            // The problem is that this is a very slow operation and we keep it async for now.
            // TODO: rulesCount should be stored in the database in the next versions.

            var updatedGroups: [SafariGroup] = []
            for group in self._groupsAtomic.wrappedValue {
                var updatedGroup = group
                var updatedFilters: [SafariGroup.Filter] = []
                for filter in group.filters {
                    var updatedFilter = filter
                    updatedFilter.rulesCount = self.getRulesCountForFilter(withId: filter.filterId)
                    updatedFilters.append(updatedFilter)
                }
                updatedGroup.filters = updatedFilters
                updatedGroups.append(updatedGroup)
            }
            self._groupsAtomic.mutate { $0 = updatedGroups }
        }
    }

    /**
     Adds info about filter to all storages
     First it downloads the filter file from the server and saves it to our file system
     Than it saves all filter meta to the database
     */
    private func add(filter: ExtendedFilterMetaProtocol, _ onFilterAdded: @escaping (_ error: Error?) -> Void) {
        Logger.logInfo("(FiltersService) - addFilter; Received new filter with id=\(filter.filterId) from server, add it now")

        filterFilesStorage.updateFilter(withId: filter.filterId) { [weak self] error in
            guard let self = self else {
                onFilterAdded(CommonError.missingSelf)
                return
            }

            if let error = error {
                Logger.logError("(FiltersService) - addFilter; Content for filter with id=\(filter.filterId) wasn't loaded. Error: \(error)")
                onFilterAdded(error)
                return
            }
            Logger.logInfo("(FiltersService) - addFilter; Content for filter with id=\(filter.filterId) was loaded and saved")

            do {
                try self.metaStorage.add(filter: filter, enabled: false)
                try self.metaStorage.updateAll(tags: filter.tags, forFilterWithId: filter.filterId)
                try self.metaStorage.updateAll(langs: filter.languages, forFilterWithId: filter.filterId)
                Logger.logInfo("(FiltersService) - addFilter; Filter with id=\(filter.filterId) was added")
                onFilterAdded(nil)
            }
            catch {
                Logger.logError("(FiltersService) - addFilter; Meta for filter with id=\(filter.filterId) wasn't updated. Error: \(error)")
                onFilterAdded(error)
                return
            }
        }
    }

    /**
     It's a wrapper for **addFilter** function to add multiple filters syncroniously
     - Returns ids of filters that were successfully added to our storage
     */
    func add(filters: [ExtendedFilterMetaProtocol]) -> [Int] {
        Logger.logInfo("(FiltersService) - addFilters; Trying to add \(filters.count) filters")

        @Atomic var addedFiltersIds: [Int] = []

        let group = DispatchGroup()
        for filter in filters {
            group.enter()
            add(filter: filter) { error in
                if let error = error {
                    Logger.logError("(FiltersService) - addFilters; Filter with id=\(filter.filterId) wasn't added. Error: \(error)")
                } else {
                    _addedFiltersIds.mutate { $0.append(filter.filterId) }
                }
                group.leave()
            }
        }
        group.wait()

        return addedFiltersIds
    }

    /// Internal method to remove restricted filters meta from meta downloaded from our server
    func removeRestrictedFilters(from meta: ExtendedFiltersMeta) -> ExtendedFiltersMeta {
        let filtersWithoutRestricted = meta.filters.filter { !FiltersService.restrictedFilterIds.contains($0.filterId) }
        let metaWithoutRestricted = ExtendedFiltersMeta(groups: meta.groups, tags: meta.tags, filters: filtersWithoutRestricted)
        return metaWithoutRestricted
    }

    /// Internal method to remove restricted filters localizations from localizations downloaded from our server
    func removeRestrictedFilters(from localizations: ExtendedFiltersMetaLocalizations) -> ExtendedFiltersMetaLocalizations {
        var filtersLocalizationsWithoutRestricted = localizations.filters
        FiltersService.restrictedFilterIds.forEach {
            filtersLocalizationsWithoutRestricted[$0] = nil
        }
        let localizationsWithoutRestricted = ExtendedFiltersMetaLocalizations(groups: localizations.groups, tags: localizations.tags, filters: filtersLocalizationsWithoutRestricted)
        return localizationsWithoutRestricted
    }

    /**
     Removes all filters data for passed filter ids
     - Parameter ids: ids of filters that should be deleted
     - Returns ids of filters that were successfully removed from our storage
     */
    private func removeFilters(withIds ids: [Int]) -> [Int] {
        Logger.logInfo("(FiltersService) - removeFilters; Trying to remove \(ids.count) filters")

        var removedFiltersIds: [Int] = []
        for id in ids {
            do {
                try metaStorage.deleteFilter(withId: id)
                try filterFilesStorage.deleteFilter(withId: id)
                removedFiltersIds.append(id)
            }
            catch {
                Logger.logError("(FiltersService) - removeFilters; Filter with id=\(id) wasn't removed. Error: \(error)")
            }
        }

        return removedFiltersIds
    }

    /* Returns all groups from database with filters and localizations */
    private func getAllLocalizedGroups() throws -> [SafariGroup] {
        let localizedGroupsMeta = try metaStorage.getAllLocalizedGroups(forSuitableLanguages: suitableLanguages)
        return try localizedGroupsMeta.map { groupMeta in
            let group = SafariGroup(dbGroup: groupMeta, filters: [])
            let groupFilters = try getFilters(forGroup: group)

            return SafariGroup(filters: groupFilters,
                               isEnabled: group.isEnabled,
                               groupType: group.groupType,
                               groupName: group.groupName,
                               displayNumber: group.displayNumber)
        }
    }

    /* Returns filters meta for specified group */
    private func getFilters(forGroup group: SafariGroupProtocol) throws -> [SafariGroup.Filter] {
        let localizedFiltersMeta = try metaStorage.getLocalizedFiltersForGroup(withId: group.groupId, forSuitableLanguages: suitableLanguages)
        return try localizedFiltersMeta.map { dbFilter in
            // Note that we initialize rulesCount with 0 here because the rulesCount will be updated asynchronously.
            // Check the initGroup function to see why.
            // TODO: We should store rulesCount in the database instead of counting it every time.
            let rulesCount = 0
            let languages = try metaStorage.getLangsForFilter(withId: dbFilter.filterId)
            let tags = try metaStorage.getTagsForFilter(withId: dbFilter.filterId)
            return SafariGroup.Filter(dbFilter: dbFilter,
                    group: group,
                    rulesCount: rulesCount,
                    languages: languages,
                    tags: tags,
                    filterDownloadPage: dbFilter.subscriptionUrl)
        }
    }

    /**
     Relatively quick function to count rules in a filter list.
     - Parameter id: filter identifier
     - Returns the number of rules in the filter list
     */
    private func getRulesCountForFilter(withId id: Int) -> Int {
        guard let filterContent = filterFilesStorage.getFilterContentForFilter(withId: id) else {
            Logger.logError("(FiltersService) - getRulesCountForFilter; received nil for filter with id=\(id)")
            return 0
        }

        // Use NSString to count lines in the filter content because Swift's String
        // is extremely slow.
        var rulesCount: Int = 0
        let commentChar1 = "!".utf16.first!
        let commentChar2 = "#".utf16.first!
        let nsString = filterContent as NSString
        nsString.enumerateLines { str, _ in
            let line = str as NSString
            if line.length > 0 {
                let firstChar = line.character(at: 0)
                if firstChar != commentChar1 && firstChar != commentChar2 {
                    rulesCount += 1
                }
            }
        }

        return rulesCount
    }

    /**
     Updates custom filters files and metadata
     - Provides ids of groups which filters were updated; ids of filters that were updated; ids of filters that failed to update
     */
    private func updateCustomFilters(onCustomFiltersUpdated: @escaping (FiltersFileUpdateResult) -> Void) {
        // Get custom group
        guard
            let customGroup = groupsAtomic.first(where: { $0.groupType == .custom }),
            customGroup.isEnabled
        else {
            Logger.logInfo("(FiltersService) - updateCustomFilters; custom group is missing or disabled")
            onCustomFiltersUpdated(([], []))
            return
        }

        // Get enabled custom filters
        let enabledCustomFilters = customGroup.filters.filter { $0.isEnabled }
        if enabledCustomFilters.isEmpty {
            Logger.logInfo("(FiltersService) - updateCustomFilters; There are 0 custom filters enabled")
            onCustomFiltersUpdated(([], []))
            return
        }

        // Update result
        @Atomic var updatedFilterIds: Set<Int> = []
        @Atomic var failedFilterIds: Set<Int> = []

        // Start updating custom filters concurrently
        let op = BlockOperation()
        enabledCustomFilters.forEach { customFilter in
            op.addExecutionBlock { [weak self] in
                guard let self = self else { return }
                let filterIsUpdated = self.updateCustomFilterSync(customFilter, customGroup)
                if filterIsUpdated {
                    _updatedFilterIds.mutate { $0.insert(customFilter.filterId) }
                } else {
                    _failedFilterIds.mutate { $0.insert(customFilter.filterId) }
                }
            }
        }
        // Handle custom filters update finish
        op.completionBlock = {
            let result = (_updatedFilterIds.wrappedValue, _failedFilterIds.wrappedValue)
            onCustomFiltersUpdated(result)
        }
        op.start()
    }

    /// Helper method for `updateCustomFilters`
    /// Updates custom filter meta and content
    /// - Returns true if filter was updated
    private func updateCustomFilterSync(_ customFilter: SafariGroup.Filter, _ customGroup: SafariGroup) -> Bool {
        guard
            let filterUrlString = customFilter.filterDownloadPage,
            let filterUrl = URL(string: filterUrlString),
            let filterContent = try? String(contentsOf: filterUrl)
        else {
            return false
        }

        do {
            // Get custom filter meta from filter content; If meta is invalid parsing'll fail and filter won't be updated
            let filterMeta = try metaParser.parse(filterContent, for: .safari, filterDownloadPage: filterUrlString)

            // Save new custom filter content
            try filterFilesStorage.saveFilter(withId: customFilter.filterId, filterContent: filterContent)

            // Creating custom filter object
            let filter = ExtendedFiltersMeta.Meta(
                customFilterMeta: filterMeta,
                filterId: customFilter.filterId,
                displayNumber: customFilter.displayNumber,
                group: customGroup
            )

            // Update custom filter meta
            let isUpdated = try metaStorage.update(filter: filter)
            Logger.logInfo("(FiltersService) - updateCustomFilter; Custom filter with id=\(customFilter.filterId) was updated successfully=\(isUpdated)")
            return isUpdated
        } catch {
            Logger.logError("(FiltersService) - updateCustomFilter; Error parsing new meta for custom filter with id=\(customFilter.filterId); Error: \(error)")
            return false
        }
    }

    /**
     Updates predefined filters files content
     - Returns ids of filters which files were updated; ids of filters which files failed to update
     */
    private typealias FiltersFileUpdateResult = (updatedFilterIds: Set<Int>, failedFilterIds: Set<Int>)
    private func updatePredefinedFiltersFileContent(onFilesUpdated: @escaping (FiltersFileUpdateResult) -> Void) {
        @Atomic var successfullyLoadedFilterIds: Set<Int> = []
        @Atomic var failedFilterIds: Set<Int> = []

        // Update only enabled filters in enabled groups ignoring custom filters
        let group = DispatchGroup()
        let enabledGroups = groupsAtomic.filter { $0.isEnabled }
        let enabledFilters = enabledGroups.flatMap { $0.filters }.filter { $0.isEnabled && !$0.isCustom }

        // TODO: - Write tests for it
        guard enabledFilters.count > 0 else {
            onFilesUpdated(([], []))
            return
        }

        enabledFilters.forEach { filter in
            group.enter()

            // Update filter file
            updateFilterFileContent(filter: filter) { error in
                if let error = error {
                    Logger.logError("(FiltersService) - updateFiltersFileContent; Failed to download content of filter with id=\(filter.filterId); Error: \(error)")
                    _failedFilterIds.mutate { $0.insert(filter.filterId) }
                } else {
                    Logger.logDebug("(FiltersService) - updateFiltersFileContent; Successfully downloaded content of filter with id=\(filter.filterId)")
                    _successfullyLoadedFilterIds.mutate { $0.insert(filter.filterId) }
                }
                group.leave()
            }
        }
        group.notify(queue: completionQueue) {
            let result = (_successfullyLoadedFilterIds.wrappedValue, _failedFilterIds.wrappedValue)
            onFilesUpdated(result)
        }
    }

    /**
     Downloads predefined filters metadata and metadata localizations and saves it to database
     While updating meta we can obtain some new filters or find out that some filters no longer exist
     If update was successfull we return update result with new filter ids and removed filter ids in completion
     If update fails we provide an error in completion
     */
    private func updateMetadataForPredefinedFilters(withIds ids: Set<Int>, onFiltersMetaUpdated: @escaping (_ result: Result<FiltersMetaUpdateResult>) -> Void) {
        var resultError: Error?
        var metaUpdateResult: FiltersMetaUpdateResult?
        let group = DispatchGroup()

        group.enter()
        // The first element of the `suitableLanguages` list is the language code with the highest priority.
        let lang = suitableLanguages.first ?? Locale.defaultLanguageCode
        apiMethods.loadFiltersMetadata(
            version: configuration.appProductVersion,
            id: configuration.appId,
            cid: configuration.cid,
            lang: lang
        ) { [weak self] filtersMeta in
            guard let self = self else { return }

            if let meta = filtersMeta {
                let metaWithoutRestricted = self.removeRestrictedFilters(from: meta)

                do {
                    metaUpdateResult = try self.save(predefinedFiltersMeta: metaWithoutRestricted, filtersIdsToUpdate: ids)
                } catch {
                    resultError = error
                    Logger.logError("(FiltersService) - Saving filters metadata error: \(error)")
                }
            }
            group.leave()
        }

        group.enter()
        apiMethods.loadFiltersLocalizations { [weak self] filtersMetaLocalizations in
            guard let self = self else { return }

            if let localizations = filtersMetaLocalizations {
                let localizationsWithoutRestricted = self.removeRestrictedFilters(from: localizations)

                do {
                    try self.save(localizations: localizationsWithoutRestricted, filtersIdsToSave: ids)
                } catch {
                    resultError = error
                    Logger.logError("(FiltersService) - Saving filters localizations error: \(error)")
                }
            }
            group.leave()
        }

        group.notify(queue: completionQueue) {
            if let error = resultError {
                onFiltersMetaUpdated(.error(error))
            } else if let metaUpdateResult = metaUpdateResult {
                onFiltersMetaUpdated(.success(metaUpdateResult))
            } else {
                onFiltersMetaUpdated(.error(CommonError.missingData))
            }
        }
    }

    /**
     Updates filters and groups meta in database that were downloaded
     Also checks if new filters were received and existing became obsolete
     - Parameter predefinedFiltersMeta: Meta for all predefined filters that was loaded from the server
     - Parameter filtersIdsToUpdate: Ids of filters that were successfully downloaded from the server
     - Parameter groupIds: Ids of groups which filters were successfully downloaded from the server
     - Returns ids of filters that were successfully added; ids of filters that were successfully removed
     */
    private typealias FiltersMetaUpdateResult = (addedFilterIds: [Int], removedFiltersIds: [Int], updatedFiltersIds: [Int])
    private func save(predefinedFiltersMeta: ExtendedFiltersMeta, filtersIdsToUpdate: Set<Int>) throws -> FiltersMetaUpdateResult {
        // Meta received from the server
        let allGroupsMeta = predefinedFiltersMeta.groups
        let allFiltersMeta = predefinedFiltersMeta.filters

        // Meta we should try to update in database
        let filtersToUpdate = allFiltersMeta.filter { filtersIdsToUpdate.contains($0.filterId) }

        // Update Groups meta
        if !allGroupsMeta.isEmpty {
            try metaStorage.update(groups: allGroupsMeta)
        }

        // Update Filters meta
        var updatedFiltersIds: [Int] = []
        if !filtersToUpdate.isEmpty {
            updatedFiltersIds = try metaStorage.update(filters: filtersToUpdate)
        }

        // Update Tags and Langs meta only for updated filters
        let updatedFilters = filtersToUpdate.filter { updatedFiltersIds.contains($0.filterId) }
        try updatedFilters.forEach {
            try metaStorage.updateAll(tags: $0.tags, forFilterWithId: $0.filterId)
            try metaStorage.updateAll(langs: $0.languages, forFilterWithId: $0.filterId)
        }

        // Don't include custom filters in existing, they have their own update flow
        let existingFilterIds = groupsAtomic.flatMap { $0.filters }.compactMap { $0.isCustom ? nil : $0.filterId }
        let receivedMetaFilterIds = allFiltersMeta.map { $0.filterId }

        // Add new filters if appeared
        let newFilterIds = Set(receivedMetaFilterIds).subtracting(existingFilterIds)
        let filtersToAdd = allFiltersMeta.filter { newFilterIds.contains($0.filterId) }
        let addedFilterIds = add(filters: filtersToAdd)

        // Remove filters if removed on the server
        let obsoleteFilterIds = Set(existingFilterIds).subtracting(receivedMetaFilterIds)
        let removedFiltersIds = removeFilters(withIds: obsoleteFilterIds.sorted())

        return (addedFilterIds, removedFiltersIds, updatedFiltersIds)
    }

    /* Updates filters and groups localizations in database that were downloaded */
    private func save(localizations: ExtendedFiltersMetaLocalizations, filtersIdsToSave: Set<Int>) throws {
        // Groups localizations received from the server
        let allGroupsLocalizations = localizations.groups
        let allGroupIdsReceived = allGroupsLocalizations.keys

        // Updating groups localizations in database
        for groupId in allGroupIdsReceived {
            let localizationsByLangs = allGroupsLocalizations[groupId] ?? [:]
            let langs = localizationsByLangs.keys
            for lang in langs {
                let localization = localizationsByLangs[lang]!
                try metaStorage.updateLocalizationForGroup(withId: groupId, forLanguage: lang, localization: localization)
            }
        }

        // Filters localizations received from the server
        let allFilterLocalizations = localizations.filters
        let allFilterIdsReceived = allFilterLocalizations.keys

        // Updating filters localizations in database
        for filterId in allFilterIdsReceived {
            let localizationsByLangs = allFilterLocalizations[filterId] ?? [:]
            let langs = localizationsByLangs.keys
            for lang in langs {
                let localization = localizationsByLangs[lang]!
                try metaStorage.updateLocalizationForFilter(withId: filterId, forLanguage: lang, localization: localization)
            }
        }
    }

    /* Updates file filter's file content */
    private func updateFilterFileContent(filter: SafariFilterProtocol, onFilesUpdated: @escaping (_ error: Error?) -> Void) {
        if filter.group.groupId == SafariGroup.GroupType.custom.id {
            guard let filterDownloadPage = filter.filterDownloadPage,
                    let subscriptionUrl = URL(string: filterDownloadPage)
            else {
                Logger.logError("(FiltersService) - updateCustomFilter; filterDownloadPage is missed for filter with id = \(filter.filterId)")
                onFilesUpdated(FilterServiceError.missedFilterDownloadPage(filterName: "\(filter.name ?? "nil") and filter id = \(filter.filterId))"))
                return
            }

            filterFilesStorage.updateCustomFilter(withId: filter.filterId, subscriptionUrl: subscriptionUrl, onFilterUpdated: onFilesUpdated)
        } else {
            filterFilesStorage.updateFilter(withId: filter.filterId, onFilterUpdated: onFilesUpdated)
        }
    }

    /* Adds custom filter to files storage syncroniously */
    private func addCustomFilterSync(withId id: Int, subscriptionUrl: URL) throws {
        var resultError: Error?

        let group = DispatchGroup()
        group.enter()
        filterFilesStorage.updateCustomFilter(withId: id, subscriptionUrl: subscriptionUrl) { error in
            resultError = error
            group.leave()
        }
        group.wait()

        if let error = resultError {
            throw error
        }
    }

    //MARK: - Enabling predefined meta methods

    /* Enable predefined groups and filters. Throws error on setting enabled state in storage*/
    private func enablePredefinedGroupsAndFiltersInternal(with groups: [SafariGroup], currentLanguage: String) throws {
        let groupsToEnable: [SafariGroup.GroupType] = [.ads, .privacy, .languageSpecific]
        for group in groups {
            var recommendedCount = 0

            for filter in group.filters {
                guard isRecommended(filter: filter, currentLanguage: currentLanguage) else { continue }
                try metaStorage.setFilter(withId: filter.filterId, enabled: true)
                Logger.logInfo("(FiltersService) - enablePredefinedMeta; Filter with id=\(filter.filterId) were enabled for groupType=\(group.groupType)")
                recommendedCount += 1
            }

            /*
             Some disabled groups have enabled filters. Only these groups should be enabled by default: ads, privacy and language specific
             */
            let groupIsEnabled = recommendedCount > 0 && groupsToEnable.contains(group.groupType)
            try metaStorage.setGroup(withId: group.groupId, enabled: groupIsEnabled)
            Logger.logInfo("(FiltersService) - enablePredefinedMeta; Group with groupType=\(group.groupType) were enabled = \(groupIsEnabled)")
        }
    }

    /* Return true if filter is recommended as predefined filter */
    private func isRecommended(filter: SafariGroup.Filter, currentLanguage: String) -> Bool {
        let isRecommended = filter.tags.contains(where: { $0.tagType == .recommended })
        let containsLanguage = containsLanguage(currentLanguage: currentLanguage, inLanguages: filter.languages)
        return isRecommended && (filter.languages.isEmpty || containsLanguage)
    }

    /* Return true if current language contains in array of languages */
    private func containsLanguage(currentLanguage: String, inLanguages languages: [String]) -> Bool {
        return languages.contains {
            let lowercasedCurrentLanguage = currentLanguage.lowercased()
            let language = $0.lowercased()
            return lowercasedCurrentLanguage.contains(language)
        }
    }
}

// MARK: - UserDefaultsStorageProtocol + FilterService variables

fileprivate extension UserDefaultsStorageProtocol {
    private var lastFiltersUpdateCheckDateKey: String { "AdGuardSDK.lastFiltersUpdateCheckDateKey" }

    var lastFiltersUpdateCheckDate: Date {
        get {
            if let date = storage.value(forKey: lastFiltersUpdateCheckDateKey) as? Date {
                return date
            }
            return Date(timeIntervalSince1970: 0.0)
        }
        set {
            storage.setValue(newValue, forKey: lastFiltersUpdateCheckDateKey)
        }
    }
}

// MARK: - NotificationCenter + FilterService events

fileprivate extension NSNotification.Name {
    static var filtersUpdateStarted: NSNotification.Name { .init(rawValue: "AdGuardSDK.filtersUpdateStarted") }
    static var filtersUpdateFinished: NSNotification.Name { .init(rawValue: "AdGuardSDK.filtersUpdateFinished") }
}

fileprivate extension NotificationCenter {
    func filtersUpdateStarted() {
        self.post(name: .filtersUpdateStarted, object: self, userInfo: nil)
        Logger.logDebug("(FiltersService) - filtersUpdateStarted; Notification filtersUpdateStarted posted")
    }

    func filtersUpdateFinished() {
        self.post(name: .filtersUpdateFinished, object: self, userInfo: nil)
        Logger.logDebug("(FiltersService) - filtersUpdateFinished; Notification filtersUpdateFinished posted")
    }
}

public extension NotificationCenter {
    func filtersUpdateStart(queue: OperationQueue? = .main, handler: @escaping () -> Void) -> NotificationToken {
        return self.observe(name: .filtersUpdateStarted, object: nil, queue: queue) { _ in
            handler()
        }
    }

    func filtersUpdateFinished(queue: OperationQueue? = .main, handler: @escaping () -> Void) -> NotificationToken {
        return self.observe(name: .filtersUpdateFinished, object: nil, queue: queue) { _ in
            handler()
        }
    }
}
