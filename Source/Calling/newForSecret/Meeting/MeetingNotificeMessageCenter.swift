//
//  MeetingNotificeMessageCenter.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/12/23.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

public let ReceivedMeetingNotificationName: NSNotification.Name = NSNotification.Name("ReceivedMeetingNotificationName")

//TODO: 这是目前会议相关的im消息推送，需要更新ui，显示弹框，目前没有统一，先列举出来
public struct ReceivedMeetingNotification {
    public enum `Type` {
        case meetingStateChange //会议室状态改变，即开启或者关闭，目前通过监听数据库中meeting的state字段来实现ui的需求
        case receiveMeetingCalling //接收到了邀请加入会议室的呼叫，目前通过监听数据库中meeting的callDate字段来实现ui的需求
        case appointStateChange //预约会议的状态改变，目前通过服务端创建一个固定的conversation，每次根据推送创建systemMessage显示在该conversation下
        case receiveAppointInvited //接收到了预约会议的邀请,显示弹框提醒，由于appoint没有用数据库存储，所以目前使用NSNotification来通知到ui
        case receiveAppointRemind //预约会议即将开始，显示弹框提醒，同上用NSNotification来通知到ui
    }
    
    public let type: Type
    public let dataString: String
    
    init(type: Type, dataString: String) {
        self.type = type
        self.dataString = dataString
    }
    
    func postNotification() {
        NotificationCenter.default.post(name: ReceivedMeetingNotificationName, object: nil, userInfo: ["notification": self])
    }
}

extension ZMUserTranscoder {
    
    func processMeetingNotification(with noticeType: UserNoticeMessageType.MeetingNotice, eventDate: [String: Any], eventTime: Date) {
        guard let payload = eventDate["msgData"] as? [String: Any] else { return }
        switch noticeType {
        case .meetingRoomStateChange:
            self.meetingStateChanged(with: payload)
        case .meetingRoomCallingMember:
            guard eventTime.compare(Date(timeIntervalSinceNow: -90)) != .orderedAscending else {
                //超过90s之后才接收到信令，就不弹框
                return
            }
            if let meeting = ZMMeeting.createOrUpdateMeeting(with: payload, context: managedObjectContext) {
                meeting.callingDate = eventTime
            }
        case .appointMeetStateChange, .appointMeetContentChange, .appointUserInviteStateChange, .appointMeetRoomStateChange:
            guard let convId = eventDate["conversation"] as? String,
                  let from = eventDate["from"] as? String,
                  let uId = UUID(uuidString: from),
                  let user = ZMUser(remoteID: uId, createIfNeeded: true, in: managedObjectContext),
                  let conversation = createOrUpdateMeetingNoticeConversation(with: convId, from: user, serverTimestamp: eventTime) else { return }
            
            guard let appoint = payload["appoint"] as? [String: Any],
                let appointId = appoint["appoint_id"] as? String,
                let uAppointId = UUID(uuidString: appointId) else {
                return
            }
            ///创建系统消息并配置基本信息
            var sysMessage: ZMSystemMessage
            var previousInviteState: String?
            if let exitMessage = ZMSystemMessage.fetch(withNonce: uAppointId, for: conversation, in: managedObjectContext),
               let text = exitMessage.text {
                sysMessage = exitMessage
                previousInviteState = JSON(parseJSON: text)["inviteState"].string
            } else {
                sysMessage = ZMSystemMessage(nonce: uAppointId, managedObjectContext: managedObjectContext)
                sysMessage.systemMessageType = ZMSystemMessageType.meetingReservationMessage
                sysMessage.serverTimestamp = eventTime
            }
            sysMessage.sender = user
            sysMessage.visibleInConversation = conversation
            
            let owner = appoint["owner"] as? [String: Any]
            let ownerId = owner?["user_id"] as? String
            let selfIsOwner: Bool = ownerId == ZMUser.selfUser(in: managedObjectContext).remoteIdentifier.transportString()
            
            //用户的邀请状态，由于服务端只在appointUserInviteStateChange的时候才推送，所以这里相当于对于inviteState进行一次保存
            var currentInviteState: String? = payload["invite_state"] as? String ?? previousInviteState
            if selfIsOwner {
                //默认创建者为自己的邀请状态都是accepted
                currentInviteState = "accepted"
            } else if currentInviteState == nil || currentInviteState!.isEmpty {
                currentInviteState = "pending"
            }
            var meetingDate = payload
            meetingDate["invite_state"] = currentInviteState
            sysMessage.text = JSON(meetingDate).description
            
            if case .appointMeetStateChange = noticeType,
               !selfIsOwner,
               let appointState = appoint["state"] as? String,
               appointState == "normal",
               currentInviteState == "pending" {
                //别人预约了一个会议，并邀请了自己
                ReceivedMeetingNotification(type: .receiveAppointInvited, dataString: JSON(meetingDate).description).postNotification()
            }
            print("test-----processMeetingNotification:\(sysMessage.text)")
        case .appointRemind:
            //会议即将开始，发通知提醒自己
            ReceivedMeetingNotification(type: .receiveAppointRemind, dataString: JSON(payload).description).postNotification()
        }
        //更改数据库，保存
        managedObjectContext.saveOrRollback()
    }
    
    
    //整个会议通知类似 服务通知一样，作为一个固定的conversation存在
    func createOrUpdateMeetingNoticeConversation(with convId: String, from: ZMUser, serverTimestamp: Date) -> ZMConversation? {
        guard let uCid = UUID(uuidString: convId) else { return nil }
        
        let conversation = ZMConversation(remoteID: uCid, createIfNeeded: true, in: managedObjectContext)
        conversation?.conversationType = .oneOnOne
        conversation?.updateLastModified(serverTimestamp)
        conversation?.updateServerModified(serverTimestamp)
        //不是公众号，只是专门用来处理会议通知的会话
        conversation?.isServiceNotice = false
        
        conversation?.internalAddParticipants([from])
        from.connection?.conversation = conversation
        
        return conversation
    }
    
    func meetingStateChanged(with payload: [String: Any]) {
        ZMMeeting.createOrUpdateMeeting(with: payload, context: managedObjectContext)
    }
    
    func remind() {
        
    }
    
}
