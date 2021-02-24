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

private let zmLog = ZMSLog(tag: "calling")

/**
 * The media state of call.
 */

@objc public enum CallMediaType: Int {
    case none = 0
    case audioOnly = 1
    case bothAudioAndVideo = 2
    case forceAudio = 3 //强制音频-目前暂时用不到，只是为了适配之前的avs
    case videoOnly = 4
    
    public var isMute: Bool {
        return self == .none || self == .videoOnly
    }
    
    public var needSendVideo: Bool {
        return self == .videoOnly || self == .bothAudioAndVideo
    }
    
    public static func getState(isMute: Bool, video: Bool) -> CallMediaType {
        switch (isMute, video) {
        case (true, true):
            return .videoOnly
        case (true, false):
            return .none
        case (false, true):
            return .bothAudioAndVideo
        case (false, false):
            return .audioOnly
        }
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
 * The state of a participant in a call.
 */

public enum CallParticipantState: Equatable, Hashable {
    /// Participant is not in the call
    case unconnected
    /// Participant is in the process of connecting to the call
    case connecting
    /// Participant is connected to call and audio is flowing
    case connected
}

/**
 * The state of video in the call.
 */

public enum VideoState: Int32 {
    /// Sender is not sending video
    case stopped = 0
    /// Sender is sending video
    case started = 1
    /// Sender is sending video but currently has a bad connection
    case badConnection = 2
    /// Sender has paused the video
    case paused = 3
    /// Sender is sending a video of his/her desktop
    case screenSharing = 4
}

/**
 * The current state of a call.
 */

public enum CallState: Equatable {

    /// There's no call
    case none
    /// Outgoing call is pending
    case outgoing(degraded: Bool)
    /// Call is answered
    case answered(degraded: Bool)
    /// Incoming call is pending
    case incoming(video: Bool, shouldRing: Bool, degraded: Bool)
    /// answeredIncomingCall
    case answeredIncomingCall
    /// Call is established (data is flowing)
    case establishedDataChannel
    /// Call is established (media is flowing)
    case established
    /// Call is over and audio/video is guranteed to be stopped
    case mediaStopped
    /// Call in process of being terminated
    case terminating(reason: CallClosedReason)
    /// Unknown call state
    case unknown

    case reconnecting

    /**
     * Logs the current state to the calling logs.
     */

    func logState() {
        switch self {
        case .answered(degraded: let degraded):
            zmLog.debug("calling-state:answered call, degraded: \(degraded)")
        case .incoming(video: let isVideo, shouldRing: let shouldRing, degraded: let degraded):
            zmLog.debug("calling-state:incoming call, isVideo: \(isVideo), shouldRing: \(shouldRing), degraded: \(degraded)")
        case .answeredIncomingCall:
            zmLog.debug("calling-state:answeredIncomingCall")
        case .establishedDataChannel:
            zmLog.debug("calling-state:established data channel")
        case .established:
            zmLog.debug("calling-state:established call")
        case .outgoing(degraded: let degraded):
            zmLog.debug("calling-state:outgoing call, , degraded: \(degraded)")
        case .terminating(reason: let reason):
            zmLog.debug("calling-state:terminating call reason: \(reason)")
        case .mediaStopped:
            zmLog.debug("calling-state:media stopped")
        case .reconnecting:
            zmLog.debug("calling-state:reconnecting")
        case .none:
            zmLog.debug("calling-state:no call")
        case .unknown:
            zmLog.debug("calling-state:unknown call state")
        }
    }

    /**
     * Updates the state of the call when the security level changes.
     * - parameter securityLevel: The new security level of the conversation for the call.
     * - returns: The current status, updated with the appropriate degradation information.
     */

    func update(withSecurityLevel securityLevel: ZMConversationSecurityLevel) -> CallState {
        let degraded = securityLevel == .secureWithIgnored

        switch self {
        case .incoming(video: let video, shouldRing: let shouldRing, degraded: _):
            return .incoming(video: video, shouldRing: shouldRing, degraded: degraded)
        case .outgoing:
            return .outgoing(degraded: degraded)
        case .answered:
            return .answered(degraded: degraded)
        default:
            return self
        }
    }
    
    private var compareNumber: Int {
        switch self {
        case .none:
            return 0
        case .outgoing:
            return 1
        case .incoming:
            return 2
        case .answered:
            return 3
        case .establishedDataChannel:
            return 4
        case .established:
            return 5
        case .mediaStopped:
            return 6
        case .terminating(let reason):
            if reason == .stillOngoing {
                return 7
            } else {
                return 8
            }
        case .unknown:
            return 9
        case .reconnecting:
            return 10
        case .answeredIncomingCall:
            return 11
        }
    }

    
    public static func == (lhs: CallState, rhs: CallState) -> Bool {
        return lhs.compareNumber == rhs.compareNumber
    }
}
