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

import SQLite
import SharedAdGuardSDK

extension ChartStatistics {
    /// Compresses table if there are more than 1000 records
    func compressTableIfNeeded() throws {
        let recordsCount = try statisticsDb.scalar(ChartStatisticsTable.table.count)
        if recordsCount >= 1000 {
            Logger.logInfo("(ChartStatistics) - compressTableIfNeeded; Number of records is greater 1500, compress now")
            try compressTable()
        }
    }

    func compressTable() throws {
        Logger.logInfo("(ChartStatistics) - compressTable; Trying to compress the table")

        let recordsCountBeforeCompression = try statisticsDb.scalar(ChartStatisticsTable.table.count)
        let compressedRecords = try getCompressedRecords()
        try reset()
        try compressedRecords.forEach { try add(record: $0) }

        Logger.logInfo("(ChartStatistics) - compressTable; Successfully compressed the table; from \(recordsCountBeforeCompression) to \(compressedRecords.count)")
    }

    /// Returns specified `intervalsCount` number of  date intervals for specified `period`
    func chartIntervals(for period: StatisticsPeriod, intervalsCount: Int) -> [DateInterval] {
        var interval: DateInterval

        /// `.all` period is not defined strictly because we don't know how long is it `all` so we've made a workaround
        if period == .all {
            let monthInterval = StatisticsPeriod.month.interval

            /// We're trying to get oldest record date from db
            if let oldestDate = oldestRecordDate {
                /// If oldestDate is older than month interval start than we should set interval as month interval
                /// Because it is the biggest one, and month interval can't be smaller than all interval
                if monthInterval.start < oldestDate {
                    interval = monthInterval
                } else {
                    /// If oldest date is greater than month interval start than oldest date will be the start of the interval
                    interval = DateInterval(start: oldestDate, end: Date())
                }
            } else {
                /// If there is no records in db - set interval as the biggest one
                interval = monthInterval
            }
        } else {
            interval = period.interval
        }

        var start = interval.start
        let end = interval.end
        let targetSegments: Int

        /// There can occur a case when the `.today` period is requested and now is 00.01
        /// It means that we should devide 1 second into `intervalsCount` segments and it is bad case
        let datesDiff = end.timeIntervalSinceReferenceDate - start.timeIntervalSinceReferenceDate

        /// Check if dates difference is at least `intervalsCount` seconds to make one segment at least 1 second
        if datesDiff < Double(intervalsCount) {
            let segments = Int(datesDiff)
            /// Dates difference can also be less than 1 second
            targetSegments = segments > 1 ? segments : 1
        } else {
            targetSegments = intervalsCount
        }

        /// Creating intervals
        let intervalDuration = (end.timeIntervalSinceReferenceDate - start.timeIntervalSinceReferenceDate) / Double(targetSegments)
        var segments: [DateInterval] = []

        for _ in 1...targetSegments {
            let dateInterval = DateInterval(start: start, duration: intervalDuration)
            segments.append(dateInterval)
            start = start.addingTimeInterval(intervalDuration)
        }
        return segments
    }

    /// Returns compressed records
    private func getCompressedRecords() throws -> [ChartStatisticsRecord] {
        let allRecords = try getRecords(for: .all)

        guard allRecords.count > 2 else {
            return []
        }

        let targetIntervalsCount = 100
        let oldestRerord = allRecords.first!
        let newestRecord = allRecords.last!
        let intervalDuration = (newestRecord.timeStamp.timeIntervalSinceReferenceDate - oldestRerord.timeStamp.timeIntervalSinceReferenceDate) / Double(targetIntervalsCount)

        var intervals: [DateInterval] = []
        var start = oldestRerord.timeStamp
        for _ in 1...targetIntervalsCount {
            let dateInterval = DateInterval(start: start, duration: intervalDuration)
            intervals.append(dateInterval)
            start = start.addingTimeInterval(intervalDuration)
        }

        let compressedRecords = try intervals.map { interval -> ChartStatisticsRecord in
            let start = interval.start
            let end = interval.end
            let query = ChartStatisticsTable.table
                .select([ChartStatisticsTable.timeStamp.avgDate,
                         ChartStatisticsTable.requests.sum,
                         ChartStatisticsTable.encrypted.sum,
                         ChartStatisticsTable.blocked.sum,
                         ChartStatisticsTable.elapsedSumm.sum])
                .where(start...end ~= ChartStatisticsTable.timeStamp)
                .order(ChartStatisticsTable.timeStamp)

            // Getting compressed record for the interval
            let result = try statisticsDb.prepare(query.asSQL()).compactMap { ChartStatisticsRecord(dbRecord: $0) }

            // The result always should be unique
            if result.count != 1 {
                // If there are multiple results or result is missing we return zero record with date in the middle of the interval
                return ChartStatisticsRecord(timeStamp: interval.middle, requests: 0, encrypted: 0, blocked: 0, elapsedSumm: 0)
            } else {
                return result.first!
            }
        }
        return compressedRecords
    }
}
