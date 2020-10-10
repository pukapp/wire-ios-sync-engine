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

//目前成员分为普通群聊音视频中的成员以及会议模式下的成员，所以这里将成员抽象出来
public protocol CallMemberProtocol {
    var remoteId: UUID { get }
    var networkQuality: NetworkQuality { set get }
    var callParticipantState: CallParticipantState { set get }
    var isMute: Bool { set get }
    var videoState: VideoState { set get }
    var audioEstablished: Bool { get }
    var isSelf: Bool { get }
    //用作会议的排序
    var isTop: Bool { get }
    var sortLevel: Int { get }
}

/**
 * An object that represents the member of an AVS call.
 */

public struct AVSCallMember: CallMemberProtocol {

    /// The remote identifier of the user.
    public let remoteId: UUID

    /// Whether an audio connection was established.
    //public let audioEstablished: Bool
    
    public var isMute: Bool
    
    /// The state of video connection.
    public var videoState: VideoState

    /// Netwok quality of this leg
    public var networkQuality: NetworkQuality

    public var callParticipantState: CallParticipantState
    
    public var isSelf: Bool = false //由于普通聊天中，成员列表不存储自己的信息，所以这里统一为false，此属性在会议成员列表中需要用到
    
    public var isTop: Bool = false
    public var sortLevel: Int = 0
    // MARK: - Initialization
    
    /**
     * Creates the call member from its values.
     * - parameter userId: The remote identifier of the user.
     * - parameter audioEstablished: Whether an audio connection was established. Defaults to `false`.
     * - parameter videoState: The state of video connection. Defaults to `stopped`.
     */
    /*
    public init?(wcallMember: wcall_member) {
        guard let remoteId = UUID(cString: wcallMember.userid) else { return nil }
        self.remoteId = remoteId
        audioEstablished = (wcallMember.audio_estab != 0)
        videoState = VideoState(rawValue: wcallMember.video_recv) ?? .stopped
        networkQuality = .normal
    }
 */

    public init(userId : UUID, callParticipantState: CallParticipantState, isMute: Bool, videoState: VideoState, networkQuality: NetworkQuality = .normal) {
        self.remoteId = userId
        self.callParticipantState = callParticipantState
        self.isMute = isMute
        self.videoState = videoState
        self.networkQuality = networkQuality
    }

    // MARK: - Properties

    /// The state of the participant.
//    var callParticipantState: CallParticipantState {
//        if audioEstablished {
//            return .connected(videoState: videoState)
//        } else {
//            return .connecting
//        }
//    }
    public var audioEstablished: Bool {
        switch self.callParticipantState {
        case .connected:
            return true
        default:
            return false
        }
    }

}
