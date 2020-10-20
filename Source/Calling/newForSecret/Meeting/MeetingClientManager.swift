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
    case mute(MeetingMuteState) //当前会议状态
    case mutedByHoster(Bool)    //自己被管理静音或请求取消静音
    case lockmMeeting(Bool) //是否锁定会议
    case setInternal(Bool) //是否开启内部会议
    case onlyHosterCanShareScreen(Bool) //是否允许开启屏幕共享
    case screenShareUser(String) //设置屏幕共享用户
    case watchUser(String) //全员看他
    case holder(String) //主持人
    case speaker(String) //主讲人
    case removeUser(String) //移除用户
    case terminateMeet
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
        zmLog.info("MediasoupClientManager:onReceiveMeetingNotification---\(action) -- \(info)")
        var property: MeetingProperty = .mute(.no)
        switch action {
        case .openMute:
            property = .mute(.soft)
            self.membersManagerDelegate.muteAll(isMute: true)
        case .openForceMute:
            property = .mute(.hard)
            self.membersManagerDelegate.muteAll(isMute: true)
        case .closeMute:
            property = .mute(.no)
        case .peerOpenMute:
            guard let userId = info["roomProperties"]["holder"]["user_id"].string, self.membersManagerDelegate.peer(with: userId)?.isSelf ?? false else { return }
            property = .mutedByHoster(true)
        case .peerCloseMute:
             guard let userId = info["roomProperties"]["holder"]["user_id"].string, self.membersManagerDelegate.peer(with: userId)?.isSelf ?? false else { return }
            property = .mutedByHoster(false)
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
                guard let userId = info["roomProperties"]["holder"]["user_id"].string, let uid = UUID(uuidString: userId),
                    self.membersManagerDelegate.containUser(with: uid) else {
                    return
                }
                property = .holder(userId)
            case .watchUser:
                guard let userId = info["roomProperties"]["watch_user"]["user_id"].string, let uid = UUID(uuidString: userId),
                    self.membersManagerDelegate.containUser(with: uid) else {
                    return
                }
                property = .watchUser(userId)
            }
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
            userJsons.forEach({
                self.membersManagerDelegate.addNewMember(MeetingParticipant(json: $0, isSelf: false))
            })
        }
        self.onReceivePropertyChange(with: property)
    }
    
    func onReceivePropertyChange(with property: MeetingProperty) {
        connectStateObserver.onReceivePropertyChange(with: property)
    }
}
