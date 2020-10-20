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

/// An opaque OTR calling message.
public typealias WireCallMessageToken = UnsafeMutableRawPointer

/**
 * The possible types of call.
 */

@objc public enum AVSCallMediaState: Int {
    case none = 0
    case audioOnly = 1
    case videoOnly = 2
    case bothAudioAndVideo = 3
    
    public var isMute: Bool {
        return self == .none || self == .videoOnly
    }
    
    public var needSendVideo: Bool {
        return self == .videoOnly || self == .bothAudioAndVideo
    }
    
    public static func getState(isMute: Bool, video: Bool) -> AVSCallMediaState {
        let audioValue: Int = isMute ? 0 : 1
        let videoValue: Int = video ? 2 : 0
        return AVSCallMediaState.init(rawValue: audioValue + videoValue)!
    }
    
    public mutating func videoStateChanged(_ videoState: VideoState) {
        switch (self, videoState) {
        case (.none, .started):
            self = .videoOnly
        case (.audioOnly, .started):
            self = .bothAudioAndVideo
        case (.videoOnly, .stopped):
            self = .none
        case (.bothAudioAndVideo, .stopped):
            self = .audioOnly
        default:break
        }
    }
    
    public mutating func audioMuted(_ isMute: Bool) {
        switch (self, isMute) {
        case (.none, !isMute):
            self = .audioOnly
        case (.audioOnly, isMute):
            self = .none
        case (.videoOnly, !isMute):
            self = .bothAudioAndVideo
        case (.bothAudioAndVideo, isMute):
            self = .videoOnly
        default:break
        }
    }
}

/**
 * Possible types of conversation in which calls can be initiated.
 */

public enum AVSConversationType: Int32 {
    case oneToOne = 0
    case group = 1
    case conference = 2
}

/**
 * An object that represents a calling event.
 */

public struct CallEvent {
    let data: Data
    let currentTimestamp: Date
    let serverTimestamp: Date
    let conversationId: UUID
    let userId: UUID
    let clientId: String
}

// MARK: - Call center transport

/// A block of code executed when the config request finishes.
public typealias CallConfigRequestCompletion = (String?, Int) -> Void

/**
 * An object that can perform requests on behalf of the call center.
 */

@objc public protocol WireCallCenterTransport: class {
    func send(data: Data, conversationId: UUID, userId: UUID, completionHandler: @escaping ((_ status: Int) -> Void))
    func requestCallConfig(completionHandler: @escaping CallConfigRequestCompletion)
}
