//
// Wire
// Copyright (C) 2019 Wire Swiss GmbH
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

extension ZMUserTranscoder {
    
    @objc
    public func processUpdateEvent(_ updateEvent: ZMUpdateEvent) {
        switch updateEvent.type {
        case .userUpdate:
            processUserUpdate(updateEvent)
        case .userDelete:
            processUserDeletion(updateEvent)
        case .userMomentUpdate:
            processUserMomentUpdate(updateEvent)
        case .userNoticeMessage:
            processUserNoticeMessage(updateEvent)
        default:
            break
        }
    }
    
    private func processUserUpdate(_ updateEvent: ZMUpdateEvent) {
        guard updateEvent.type == .userUpdate else { return }
        
        guard let userPayload = updateEvent.payload["user"] as? [String: Any],
              let userId = (userPayload["id"] as? String).flatMap(UUID.init)
        else {
            return Logging.eventProcessing.error("Malformed user.update update event, skipping...")
        }
        
        let user = ZMUser.fetchAndMerge(with: userId, createIfNeeded: true, in: managedObjectContext)
        user?.update(withTransportData: userPayload, authoritative: false)
    }
    
    private func processUserDeletion(_ updateEvent: ZMUpdateEvent) {
        guard updateEvent.type == .userDelete else { return }
        
        guard let userId = (updateEvent.payload["id"] as? String).flatMap(UUID.init),
              let user = ZMUser.fetchAndMerge(with: userId, createIfNeeded: false, in: managedObjectContext)
        else {
            return Logging.eventProcessing.error("Malformed user.delete update event, skipping...")
        }
        
        if user.isSelfUser {
            deleteAccount()
        } else {
            user.markAccountAsDeleted(at: updateEvent.timeStamp() ?? Date())
        }
    }
    
    private func deleteAccount() {
        PostLoginAuthenticationNotification.notifyAccountDeleted(context: managedObjectContext)
    }
    
    private func processUserMomentUpdate(_ updateEvent: ZMUpdateEvent) {
        guard updateEvent.type == .userMomentUpdate else { return }
        
        guard let msg_body = updateEvent.payload["msg_body"] as? [String: Any],
            let type = msg_body["type"] as? Int,
            let nid = msg_body["nid"] as? Int
            else {
                return Logging.eventProcessing.error("Malformed user.update update event, skipping...")
        }
        switch type {
        case 1:
            ///过滤私密社区
            guard let notify_type = msg_body["notify_type"] as? Int, notify_type != 3 else { return }
            ///朋友圈,公共社区，点赞，评论，转发消息通知
            
            ///这里由于每次推送了两条消息，所以采用本地去重处理，筛选nid
            let saveNidsKey = "UserMomentMetionMeSaveKeyNids"
            if var nids = UserDefaults.standard.value(forKey: saveNidsKey) as? [Int] {
                if nids.contains(nid) { return }
                if nids.count > 30 { nids = nids.dropLast() }
                nids.append(nid)
                UserDefaults.standard.setValue(nids, forKey: saveNidsKey)
            } else {
                UserDefaults.standard.setValue([nid], forKey: saveNidsKey)
            }
            
            let saveKey = UserMomentMetionMeSaveKey + "-account-\(ZMUser.selfUser(in: self.managedObjectContext).remoteIdentifier.transportString())"
            var count: Int = 1
            if let oldCount = UserDefaults.standard.value(forKey: saveKey) as? Int {
                count = oldCount + 1
            }
            UserDefaults.standard.set(count, forKey: saveKey)
            NotificationCenter.default.post(name: NSNotification.Name(UserMomentUpdate), object: nil)
        case 2:///多端同步，清除消息通知
            UserDefaults.standard.removeObject(forKey: UserMomentMetionMeSaveKey)
            NotificationCenter.default.post(name: NSNotification.Name(UserMomentSync), object: nil)
        case 3:///好友发布了朋友圈消息通知
            NotificationCenter.default.post(name: NSNotification.Name(UserMomentAdd), object: nil)
        default:
            break
        }
        
    }
    
    private func processUserNoticeMessage(_ updateEvent: ZMUpdateEvent) {
        guard updateEvent.type == .userNoticeMessage,
              let data = updateEvent.payload["data"] as? [String: Any],
              let timeString = updateEvent.payload["time"] as? String,
              let time = NSDate(transport: timeString) as Date?,
              let msgType = data["msgType"] as? String,
              let noticeType = UserNoticeMessageType(msgType: msgType) else { return }
        
        switch noticeType {
        case .meetingNotice(let meetingNotice):
            self.processMeetingNotification(with: meetingNotice, eventDate: data, eventTime: time)
        }
    }
}

enum UserNoticeMessageType {
    
    enum MeetingNotice: String {
        case appointMeetStateChange = "40201" //预约会议状态改变
        case appointMeetContentChange = "40202" //预约会议内容改变通知
        case appointRemind = "40203" //预约会议提醒通知
        case appointUserInviteStateChange = "40204" //用户邀请状态改变通知
        case appointMeetRoomStateChange = "40205" //预约会议的会议室的状态改变通知
        
        case meetingRoomStateChange = "40101" //会议室状态改变通知（当用户直接进入会议室而不经过预约会议时，会有这个通知）
        case meetingRoomCallingMember = "40102" //会议室中呼叫成员通知
    }
    
    case meetingNotice(MeetingNotice)
    
    

    init?(msgType: String) {
        if let notice = MeetingNotice(rawValue: msgType) {
            self = .meetingNotice(notice)
        } else {
            return nil
        }
    }
}
