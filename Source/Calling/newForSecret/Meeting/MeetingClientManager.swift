//
//  MeetingClientManager.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/9/9.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

private let zmLog = ZMSLog(tag: "calling")

public enum MeetingProperty {
    case userOnline(String) //用户上线了
    case mute(MeetingMuteState) //当前会议状态
    case mutedByHoster(Bool)    //自己被管理静音或请求取消静音
    case lockmMeeting(Bool) //是否锁定会议
    case setInternal(Bool) //是否开启内部会议
    case onlyHosterCanShareScreen(Bool) //是否允许开启屏幕共享
    case screenShareUser(String?) //设置屏幕共享用户-为空 说明用户取消了共享或者当前无人屏幕共享
    case watchUser(String?) //全员看他 -为空逻辑同上
    case holder(String) //主持人
    case speaker(String) //主讲人
    case removeUser(String) //移除用户
    case terminateMeet
    case inviteUser //邀请了用户
}


public protocol WireCallCenterrMeetingPropertyChangedObserver : class {
    
    func callMeetingPropertyDidChange(meeting: ZMMeeting, property: MeetingProperty)
}

public struct WireCallCenterMeetingPropertyChangedNotification : SelfPostingNotification {
    
    static let notificationName = Notification.Name("WireCallCenterMeetingInfoChangedNotification")
    
    let meetingId : UUID
    let property: MeetingProperty
    
    init(meetingId: UUID, property: MeetingProperty) {
        self.meetingId = meetingId
        self.property = property
    }
    
}

extension WireCallCenterV3 {
    
    public class func addMeetingPropertyChangedObserver(observer: WireCallCenterrMeetingPropertyChangedObserver, for meeting: ZMMeeting, context: NSManagedObjectContext) -> Any {
        return NotificationInContext.addObserver(name: WireCallCenterMeetingPropertyChangedNotification.notificationName, context: context.notificationContext, queue: .main) { [weak observer] note in
            guard let note = note.userInfo[WireCallCenterMeetingPropertyChangedNotification.userInfoKey] as? WireCallCenterMeetingPropertyChangedNotification,
                  let observer = observer,
                note.meetingId == UUID.init(uuidString: meeting.meetingId)
            else { return }
            
            observer.callMeetingPropertyDidChange(meeting: meeting, property: note.property)
        }
    }
    
}

extension MediasoupClientManager {
    
    func onReceiveMeetingNotification(with action: MeetingSignalAction.Notification, info: JSON) {
        if action != .activeSpeaker {
            zmLog.info("MediasoupClientManager:onReceiveMeetingNotification---\(action) -- \(info)")
        }
        var property: MeetingProperty? = nil
        switch action {
        case .peerOpened:
            guard let userId = info["peerId"].string,
                  let uid = UUID(uuidString: userId),
                  self.membersManagerDelegate.containUser(with: uid) else {
                return
            }
            property = .userOnline(userId)
        case .peerClosed:
            guard let userId = info["peerId"].string,
                  let uid = UUID(uuidString: userId),
                  var member = self.membersManagerDelegate.user(with: uid) else {
                return
            }
            member.callParticipantState = .connecting
            self.membersManagerDelegate.replaceMember(with: member)
        case .openMute:
            property = .mute(.soft)
        case .openForceMute:
            property = .mute(.hard)
        case .closeMute:
            property = .mute(.no)
        case .peerOpenMute:
            guard let userId = info["peerId"].string,
                  let uid = UUID(uuidString: userId),
                  let peer = self.membersManagerDelegate.user(with: uid) else { return }
            if peer.isSelf {
                //别人被静音的状态是根据consumer的paused推送来设置，收到自己被静音的话，需要手动的设置自己的状态
                AVSMediaManager.sharedInstance.isMicrophoneMuted = true
                self.membersManagerDelegate.setMemberAudio(true, mid: UUID(uuidString: userId)!)
                property = .mutedByHoster(true)
            }
        case .peerCloseMute:
            guard let userId = info["peerId"].string,
                  let uid = UUID(uuidString: userId),
                  let peer = self.membersManagerDelegate.user(with: uid) else { return }
            if peer.isSelf {
                property = .mutedByHoster(false)
            }
        case .changeRoomProperty:
            //更改房间属性
            let changedProperty = MeetingSignalAction.Notification.ChangeRoomProperty(rawValue: info["field"].stringValue)!
            switch changedProperty {
            case .lockMeet:
                guard let isLocked = info["roomProperties"]["lock_meeting"].int else { return }
                property = .lockmMeeting(isLocked == 1)
            case .setInternal:
                guard let isInternal = info["roomProperties"]["internal"].int else { return }
                property = .setInternal(isInternal == 1)
            case .newSpeaker, .cancelSpeaker:
                break
            case .onlyHosterCanShareScreen:
                guard let canShare = info["roomProperties"]["screen_share"].int else { return }
                property = .onlyHosterCanShareScreen(canShare == 1)
            case .newHolder:
                guard let userId = info["roomProperties"]["holder"]["user_id"].string,
                      let uid = UUID(uuidString: userId),
                      let _ = self.membersManagerDelegate.user(with: uid) else {
                    return
                }
                property = .holder(userId)
            case .watchUser:
                property = .watchUser(info["roomProperties"]["watch_user"]["user_id"].string)
            case .screenShareUser:
                property = .screenShareUser(info["roomProperties"]["screen_share_user"]["user_id"].string)
            }
        case .changeUserProperty:
            let userProperty = info["property"]
            guard let userId = userProperty["user_id"].string,
                  let uid = UUID(uuidString: userId),
                  var member = self.membersManagerDelegate.user(with: uid) as? MeetingParticipant else {
                return
            }
            member.update(with: userProperty)
            self.membersManagerDelegate.replaceMember(with: member)
        case .kickoutMeet:
            guard let userId = info["peerId"].string, let uid = UUID(uuidString: userId),
                self.membersManagerDelegate.containUser(with: uid) else {
                return
            }
            property = .removeUser(userId)
            self.membersManagerDelegate.removeMember(with: uid)
        case .terminateMeet:
            self.membersManagerDelegate.clear()
            property = .terminateMeet
        case .inviteUser:
            guard let userJsons = info["property"].array, userJsons.count > 0 else {
                return
            }
            property = .inviteUser
            userJsons.forEach({
                self.membersManagerDelegate.addNewMember(MeetingParticipant(json: $0, isSelf: false))
            })
        case .activeSpeaker:
            guard let userId = info["peerId"].string, let uid = UUID(uuidString: userId),
                self.membersManagerDelegate.containUser(with: uid),
                let volume = info["volume"].int else {
                return
            }
            self.membersManagerDelegate.setActiveSpeaker(uid, volume: volume)
        }
        if let property = property {
            self.onReceivePropertyChange(with: property)
        }
    }
    
    func onReceivePropertyChange(with property: MeetingProperty) {
        connectStateObserver.onReceivePropertyChange(with: property)
    }
}
