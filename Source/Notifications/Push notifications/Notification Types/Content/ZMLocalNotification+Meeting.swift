//
//  ZMLocalNotification+Meeting.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2021/3/11.
//  Copyright © 2021 Zeta Project Gmbh. All rights reserved.
//

import Foundation

extension MeetingReserved.RemindTimeType {
    
    var notificationDescription: String {
        switch self {
        case .none:
            return ""
        case .start:
            return "马上"
        case .t5mAgo:
            return "5分钟后"
        case .t15mAgo:
            return "15分钟后"
        case .t30mAgo:
            return "半小时后"
        case .t1hAgo:
            return "1小时后"
        case .t1dAgo:
            return "一天后"
        }
    }
}

class MeetingNotificationBuilder :NotificationBuilder {
        
    let notificationType: LocalNotificationType
    
    private var _titleText: String?
    private var _bodyText: String?
    
    init?(event: ZMUpdateEvent, managedObjectContext moc: NSManagedObjectContext) {
        guard let data = event.payload["data"] as? [String: Any],
              let timeString = event.payload["time"] as? String,
              let eventTime = NSDate(transport: timeString) as Date?,
              let msgType = data["msgType"] as? String,
              let msgData = data["msgData"] as? [String: Any],
              let noticeType = UserNoticeMessageType(msgType: msgType, data: msgData) else { return nil }
        guard eventTime.compare(Date(timeIntervalSinceNow: -90)) != .orderedAscending else {
            //超过90s之后才接收到通知，就不提示
            return nil
        }
        switch noticeType {
        case .meetingNotice(let meetingNotice):
            switch meetingNotice {
            case .appoint(let appointState, let notifyConfiguration):
                switch appointState {
                case .appointMeetStateChange:
                    let selfIsOwner: Bool = notifyConfiguration.appoint.owner.userID == ZMUser.selfUser(in: moc).remoteIdentifier.transportString()
                    // 别人预约了一个会议，并邀请了自己
                    if !selfIsOwner, notifyConfiguration.appoint.state == .normal {
                        self.notificationType = .event(.inversedMeetingInvite)
                        self._titleText = "预约会议邀请"
                        self._bodyText = "\(notifyConfiguration.fromUser!.nickname)邀请你加入预约会议:\(notifyConfiguration.appoint.title)"
                    } else {
                        return nil
                    }
                case .appointRemind:
                    self.notificationType = .event(.inversedMeetingWillStart)
                    self._titleText = "预约会议即将开始"
                    let remindType = notifyConfiguration.remindType!
                    self._bodyText = "您的会议:\(notifyConfiguration.appoint.title)\(remindType.notificationDescription)开始"
                default:
                    return nil
                }
            case .meetingRoom(let roomState, let roomInfo):
                switch roomState {
                case .meetingRoomStateChange:
                    switch roomInfo.state {
                    case .on:
                        self.notificationType = .event(.meetingRoomInvite)
                        self._titleText = "会议已开始"
                        self._bodyText = "\(roomInfo.holder.nickname)发起了会议:\(roomInfo.title)"
                    case .off:
                        self.notificationType = .event(.meetingRoomClosed)
                        self._titleText = "会议已结束"
                        self._bodyText = "会议:\(roomInfo.title)已结束"
                    case .wait:
                        return nil
                    }
                case .meetingRoomCallingMember:
                    self.notificationType = .event(.meetingRoomCalling)
                    self._titleText = "会议邀请"
                    self._bodyText = "\(roomInfo.holder.nickname)邀请你参加会议"
                }
            }
        }
   }
    
    func shouldCreateNotification() -> Bool {
        true
    }
    
    func titleText() -> String? {
        return _titleText
    }
    
    func bodyText() -> String {
        return _bodyText ?? ""
    }
    
    func userInfo() -> NotificationUserInfo? {
        return nil
    }
    
}
