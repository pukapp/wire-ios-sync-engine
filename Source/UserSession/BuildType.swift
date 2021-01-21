//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import WireSystem

enum BuildType: Equatable {
    case production
    case alpha
    case custom(bundleID: String)

    init(bundleID: String) {
        switch bundleID {
        case "security.itask.group": self = .production
        case "security.itask.group-alpha": self = .alpha
        default: self = .custom(bundleID: bundleID)
        }
    }
    
    var certificateName: String {
        switch self {
        case .production:
            return "itask.production"
        case .alpha:
            return "itask.alpha"
        case .custom(let bundleID):
            return bundleID
        }
    }
    
    var bundleID: String {
        switch self {
        case .production:
            return "security.itask.group"
        case .alpha:
            return "security.itask.group-alpha"
        case .custom(let bundleID):
            return bundleID
        }
        
    }
}
