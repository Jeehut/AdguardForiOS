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

/// Parser to parse data from `FiltersMetadataRequest` and returns `ExtendedFiltersMeta`
struct FiltersMetadataParser: ParserProtocol {
    typealias Model = ExtendedFiltersMeta

    func parse(data: Data, response: URLResponse?) -> Model? {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            Logger.logError("(FiltersMetadataParser) bad response")
            return nil
        }

        let decoder = JSONDecoder()
        return try? decoder.decode(ExtendedFiltersMeta.self, from: data)
    }
}
