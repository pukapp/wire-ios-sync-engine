//
// Wire
// Copyright (C) 2018 Wire Swiss GmbH
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

import Foundation

// MARK: - Call center transport

/// A block of code executed when the config request finishes.
public typealias CallConfigRequestCompletion = (String?, Int) -> Void

/**
 * An object that can perform requests on behalf of the call center.
 */

@objc public protocol WireCallCenterTransport: class {
    func send(newCalling: ZMNewCalling, conversationId: UUID, userId: UUID, completionHandler: @escaping ((_ status: Int) -> Void))
    func requestCallConfig(completionHandler: @escaping CallConfigRequestCompletion)
}
