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
    case development
    case `internal`
    case custom(bundleID: String)

    init(bundleID: String) {
        switch bundleID {
        case "com.secrect.qhsj": self = .production
        case "com.secret.alpha": self = .alpha
        case "com.secret.development": self = .development
        case "com.secret.beta": self = .internal
        default: self = .custom(bundleID: bundleID)
        }
    }
    
    var certificateName: String {
        switch self {
        case .production:
            return "Qhsj"
        case .alpha:
            return "Alpha"
        case .development:
            return "Development"
        case .internal:
            return "Beta"
        case .custom(let bundleID):
            return bundleID
        }
    }
    
    var bundleID: String {
        switch self {
        case .production:
            return "com.secrect.qhsj"
        case .alpha:
            return "com.secret.alpha"
        case .development:
            return "com.secret.development"
        case .internal:
            return "com.secret.beta"
        case .custom(let bundleID):
            return bundleID
        }
        
    }
}
