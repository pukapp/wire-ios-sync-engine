//
//  WireCallCenterV3+Meeting.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/9/9.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

private var meetingChannelAssociatedKey: UInt8 = 0

public extension ZMMeeting {
    
    /// NOTE: this object is transient, and will be re-created periodically. Do not hold on to this object, hold on to the owning conversation instead.
    var voiceChannel : VoiceChannel? {
        get {
            if let voiceChannel = objc_getAssociatedObject(self, &meetingChannelAssociatedKey) as? VoiceChannel {
                return voiceChannel
            } else {
                let voiceChannel = WireCallCenterV3Factory.voiceChannelClass.init(relyModel: self)
                objc_setAssociatedObject(self, &meetingChannelAssociatedKey, voiceChannel, .OBJC_ASSOCIATION_RETAIN)
                return voiceChannel
            }
        }
    }
    
}


extension WireCallCenterV3 {
    
    /// Returns the meetingParticipants currently in the meeting
    func meetingParticipants(meetingId: UUID) -> [MeetingParticipant] {
        if let participants = callSnapshots[meetingId]?.callParticipants.members as? [MeetingParticipant] {
            return participants
        } else {
            return []
        }
    }
    
}

public enum MeetingParticipantInviteState: String {
    case noResponse    = "no_response"
    case accepted      = "accepted"
    case reject        = "reject"
    case calling       = "calling"
    case callLimit     = "call_limit"
}

public struct MeetingParticipant: CallMemberProtocol {
    
    //协议属性
    public var remoteId: UUID {
        return UUID(uuidString: self.userId)!
    }
    public var networkQuality: NetworkQuality
    public var callParticipantState: CallParticipantState
    public var videoState: VideoState = .stopped
    public var audioEstablished: Bool {
        switch self.callParticipantState {
        case .connected:
            return true
        default:
            return false
        }
    }
    
    //服务器返回状态
    let userId: String
    let inviteLink: String
    let inviteState: MeetingParticipantInviteState
    let isMute: Bool
    let nickName: String
    let avatar: String
    
    public init(json: JSON) {
        userId = json["user_id"].stringValue
        inviteLink = json["invite_link"].stringValue
        inviteState = MeetingParticipantInviteState(rawValue: json["invite_state"].stringValue)!
        isMute = json["is_mute"].intValue == 1
        nickName = json["nickname"].stringValue
        avatar = json["avatar"].stringValue
        
        callParticipantState = (inviteState == .accepted) ? .connecting : .unconnected
        networkQuality = .normal
    }
}
