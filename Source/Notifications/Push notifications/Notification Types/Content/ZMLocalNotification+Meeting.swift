//
//  ZMLocalNotification+Meeting.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2021/3/11.
//  Copyright © 2021 Zeta Project Gmbh. All rights reserved.
//

import Foundation

public enum LocalNotificationMeetingType {
    case meetingRoomInvite, meetingRoomCalling
    case inversedMeetingInvite, inversedMeetingWillStart, inversedMeetingContentChanged, inversedMeetingHasBeenCancelled
}

extension MeetingReserved.RemindTimeType {
    
    var notificationDescription: String {
        let prefix: String = "距离会议开始还有"
        switch self {
        case .none:
            return ""
        case .start:
            return "会议马上开始"
        case .t5mAgo:
            return "\(prefix)5分钟"
        case .t15mAgo:
            return "\(prefix)15分钟"
        case .t30mAgo:
            return "\(prefix)半小时"
        case .t1hAgo:
            return "\(prefix)1小时"
        case .t1dAgo:
            return "\(prefix)一天"
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
                    guard !selfIsOwner else {
                        return nil
                    }
                    switch notifyConfiguration.appoint.state {
                    case .normal:
                        // 别人预约了一个会议，并邀请了自己
                        self.notificationType = .meeting(.inversedMeetingInvite)
                        self._titleText = "[会议邀请]\(notifyConfiguration.appoint.owner.nickname)创建了会议：\(notifyConfiguration.appoint.title)"
                        self._bodyText = "时间：\(notifyConfiguration.appoint.startTime.formattedDate)"
                    case .cancel:
                        // 预约会议被取消
                        self.notificationType = .meeting(.inversedMeetingHasBeenCancelled)
                        self._titleText = "[会议取消]\(notifyConfiguration.appoint.owner.nickname)取消了会议：\(notifyConfiguration.appoint.title)"
                        self._bodyText = "时间：\(notifyConfiguration.appoint.startTime.formattedDate)"
                    }
                case .appointRemind:
                    self.notificationType = .meeting(.inversedMeetingWillStart)
                    self._titleText = "[会议提醒]\(notifyConfiguration.appoint.title)"
                    self._bodyText = "时间：\(notifyConfiguration.appoint.startTime.formattedDate)\n\(notifyConfiguration.remindType!.notificationDescription)"
                case .appointMeetContentChange:
                    self.notificationType = .meeting(.inversedMeetingWillStart)
                    self._titleText = "[会议修改]\(notifyConfiguration.appoint.owner.nickname)修改了会议：\(notifyConfiguration.appoint.title)"
                    self._bodyText = "时间：\(notifyConfiguration.appoint.startTime.formattedDate)"
                default: return nil
                }
            case .meetingRoom(let roomState, let roomInfo):
                switch roomState {
                case .meetingRoomStateChange:
                    return nil
                case .meetingRoomCallingMember:
                    self.notificationType = .meeting(.meetingRoomCalling)
                    self._titleText = "[会议邀请]\(roomInfo.holder.nickname)创建了会议：\(roomInfo.title)"
                    self._bodyText = "时间：\(roomInfo.startTime.formattedDate)"
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
