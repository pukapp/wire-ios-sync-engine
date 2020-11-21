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
    case left         = "left"
    
    public var description: String {
        switch self {
        case .noResponse:
            return "无响应"
        case .accepted:
            return ""
        case .reject:
            return "已拒绝"
        case .calling:
            return "呼叫中"
        case .callLimit:
            return "呼叫受限"
        case .left:
            return "已离开"
        }
    }
}

//获取排序状态
extension MeetingParticipantInviteState {
    var sortValue: Int {
        switch self {
        case .accepted:
            return 6
        case .calling:
            return 5
        case .left:
            return 4
        case .noResponse:
            return 3
        case .callLimit:
            return 2
        case .reject:
            return 1
        }
    }
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
    public var isSelf: Bool
    public var isTop: Bool = false
    //排序状态，排序由多种属性决定
    public var sortLevel: Int {
        let establishedSortValue: Int = audioEstablished ? 10000 : 0
        let selfSortValue: Int = isSelf ? 1000 : 0
        let topSortValue: Int = isTop ? 100 : 0
        let hasVideoSortValue: Int = (videoState == .started) ? 10 : 0
        return establishedSortValue + selfSortValue + topSortValue + hasVideoSortValue + state.sortValue
    }
    public var isScreenShare: Bool = false//当前正在屏幕分享
    
    //服务器返回状态
    public let userId: String
    public let inviteLink: String
    public var state: MeetingParticipantInviteState
    public var isMute: Bool
    public var nickName: String
    public var avatar: String
    
    public var isSpeaking: Bool = false//判断用户当前时候正在说话,仅用于九宫格模式下
    
    public init(json: JSON, isSelf: Bool) {
        self.isSelf = isSelf
        userId = json["user_id"].stringValue
        inviteLink = json["invite_link"].stringValue
        state = MeetingParticipantInviteState(rawValue: json["state"].stringValue)!
        isMute = json["is_mute"].intValue == 1
        nickName = json["nickname"].stringValue
        avatar = json["avatar"].stringValue
        
        if isSelf {
            callParticipantState = .connected
        } else {
            callParticipantState = (state == .accepted) ? .connecting : .unconnected
        }
        networkQuality = .normal
    }
    
    mutating func update(with json: JSON) {
        if let stateValue = json["state"].string,
            let state = MeetingParticipantInviteState(rawValue: stateValue) {
            self.state = state
        }
        if let nickName = json["nickname"].string {
            self.nickName = nickName
        }
    }
}
