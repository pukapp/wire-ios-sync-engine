//
//  MeetingNotificeMessageCenter.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/12/23.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

public let MeetingNotificationServiceConversationId: String = "00000000-0000-0000-0001-000000000004"
public let ReceivedMeetingNotificationName: NSNotification.Name = NSNotification.Name("ReceivedMeetingNotificationName")

//组装的预约会议相关的推送结构
public struct ITaskMeetingNotifyConfiguration {
    public let appoint: MeetingReserved.Info
    public var inviteState: MeetingReserved.InviteState?
    public let fromUser: MeetingReserved.User?
    public let remindType: MeetingReserved.RemindTimeType? //提醒时间
    
    init?(data: [String: Any]) {
        guard let appointDic = data["appoint"] as? [String: Any] else {
            return nil
        }
        appoint = MeetingReserved.Info(data: appointDic)
        if let inviteStateValue = data["invite_state"] as? String,
           let state = MeetingReserved.InviteState(rawValue: inviteStateValue) {
            inviteState = state
        }
        if let fromUserData = data["from_user"] as? [String: Any] {
            fromUser = MeetingReserved.User(data: fromUserData)
        } else {
            fromUser = nil
        }
        if let remindTypeValue =  data["remind_type"] as? String,
           let type = MeetingReserved.RemindTimeType(rawValue: remindTypeValue) {
            remindType = type
        } else {
            remindType = nil
        }
    }
    
    public init?(jsonText: String) {
        let json = JSON(parseJSON: jsonText)
        guard let appointDic = json["appoint"].dictionaryObject else {
            return nil
        }
        self.appoint = MeetingReserved.Info.init(data: appointDic)
        if let inviteStateValue = json["invite_state"].string,
           let inviteState = MeetingReserved.InviteState(rawValue: inviteStateValue) {
            self.inviteState = inviteState
        }
        if let fromUserValue = json["from_user"].dictionaryObject {
            self.fromUser = MeetingReserved.User(data: fromUserValue)
        } else {
            fromUser = nil
        }
        if let remindTypeValue = json["remind_type"].string,
           let remindType = MeetingReserved.RemindTimeType(rawValue: remindTypeValue) {
            self.remindType = remindType
        } else {
            remindType = nil
        }
    }
    
    // 转成json字符串
    var jsonDescription: String {
        var json: JSON = ["appoint": JSON(appoint.dictionaryData)]
        if let inviteStateValue = inviteState?.rawValue {
            json["invite_state"] = JSON(inviteStateValue)
        }
        if let fromUserValue = fromUser?.dictionaryData {
            json["from_user"] = JSON(fromUserValue)
        }
        if let remindTypeValue = remindType?.rawValue {
            json["remind_type"] = JSON(remindTypeValue)
        }
        return json.description
    }
}


//TODO: 这是目前会议相关的im消息推送，需要更新ui，显示弹框，目前没有统一，先列举出来
public struct ReceivedMeetingNotification {
    public enum `Type` {
        case meetingStateChange //会议室状态改变，即开启或者关闭，目前通过监听数据库中meeting的state字段来实现ui的需求
        case receiveMeetingCalling //接收到了邀请加入会议室的呼叫，目前通过监听数据库中meeting的callDate字段来实现ui的需求
        case appointStateChange //预约会议的状态改变，目前通过服务端创建一个固定的conversation，每次根据推送创建systemMessage显示在该conversation下
        case receiveAppointInvited //接收到了预约会议的邀请,显示弹框提醒，由于appoint没有用数据库存储，所以目前使用NSNotification来通知到ui
        case receiveAppointRemind //预约会议即将开始，显示弹框提醒，同上用NSNotification来通知到ui
        
        var needPost: Bool {
            switch self {
            case .meetingStateChange, .receiveMeetingCalling, .appointStateChange:
                return false
            case .receiveAppointInvited, .receiveAppointRemind:
                return true
            }
        }
    }
    
    public let type: Type
    public let notifyConfiguration: ITaskMeetingNotifyConfiguration
    
    init(type: Type, notifyConfiguration: ITaskMeetingNotifyConfiguration) {
        guard notifyConfiguration.inviteState != nil else { fatal("you bug") }
        self.type = type
        self.notifyConfiguration = notifyConfiguration
    }
    
    func postNotification() {
        guard self.type.needPost else { return }
        NotificationCenter.default.post(name: ReceivedMeetingNotificationName, object: nil, userInfo: ["notification": self])
    }
}

enum MeetingNoticeType {
    //预约会议相关
    enum AppointNoti: String {
        case appointMeetStateChange = "40201" //预约会议状态改变
        case appointMeetContentChange = "40202" //预约会议内容改变通知
        case appointRemind = "40203" //预约会议提醒通知
        case appointUserInviteStateChange = "40204" //用户邀请状态改变通知
        case appointMeetRoomStateChange = "40205" //预约会议的会议室的状态改变通知
    }
    
    //会议室相关
    enum MeetingRoomNoti: String {
        case meetingRoomStateChange = "40101" //会议室状态改变通知（当用户直接进入会议室而不经过预约会议时，会有这个通知）
        case meetingRoomCallingMember = "40102" //会议室中呼叫成员通知
    }
    
    case appoint(AppointNoti, ITaskMeetingNotifyConfiguration)
    case meetingRoom(MeetingRoomNoti, MeetingReserved.Meeting)
    
    init?(stringValue: String, data: [String: Any]) {
        if let appointNoti = AppointNoti(rawValue: stringValue) {
            guard let congifuration = ITaskMeetingNotifyConfiguration(data: data) else { return nil }
            self = .appoint(appointNoti, congifuration)
        } else if let meetingRoomNoti = MeetingRoomNoti(rawValue: stringValue)  {
            self =  .meetingRoom(meetingRoomNoti, MeetingReserved.Meeting(data: data))
        } else {
            return nil
        }
    }
}


extension ZMUserTranscoder {
    
    func processMeetingNotification(with noticeType: MeetingNoticeType, eventTime: Date, convId: String, from: String) {
        switch noticeType {
        case .meetingRoom(let meetingRoomType, let meetingInfo):
            switch meetingRoomType {
            case .meetingRoomStateChange:
                self.createOrUpdateMeeting(notiInfo: meetingInfo)
            case .meetingRoomCallingMember:
                guard eventTime.compare(Date(timeIntervalSinceNow: -90)) != .orderedAscending else {
                    //超过90s之后才接收到信令，就不弹框
                    return
                }
                if let meeting = self.createOrUpdateMeeting(notiInfo: meetingInfo) {
                    meeting.callingDate = eventTime
                }
            }
        case .appoint(let appointType, var configuration):
            guard let senderId = UUID(uuidString: from),
                let sender = ZMUser(remoteID: senderId, createIfNeeded: true, in: managedObjectContext),
                let conversation = createOrUpdateMeetingNoticeConversation(with: convId, from: sender, serverTimestamp: eventTime),
                let uAppointId = UUID(uuidString: configuration.appoint.appointId) else {
                return
            }
            let selfIsOwner: Bool = configuration.appoint.owner.userID == ZMUser.selfUser(in: managedObjectContext).remoteIdentifier.transportString()
            
            // 会议即将开始，显示提示弹窗
            if case .appointRemind = appointType {
                guard configuration.remindType != nil,
                      configuration.appoint.startTime.compare(Date()) != .orderedAscending else {
                    // 当前该会议已经开始了，则不再弹框
                    return
                }
                // 收到了提示，则说明用户状态肯定是已接受
                configuration.inviteState = .accepted
                ReceivedMeetingNotification(type: .receiveAppointRemind, notifyConfiguration: configuration).postNotification()
                return
            }

            // 创建系统消息并配置基本信息
            var sysMessage: ZMSystemMessage
            var previousConfiguration: ITaskMeetingNotifyConfiguration?
            if let existMessage = ZMSystemMessage.fetch(withNonce: uAppointId, for: conversation, in: managedObjectContext),
               let text = existMessage.text {
                sysMessage = existMessage
                previousConfiguration = ITaskMeetingNotifyConfiguration(jsonText: text)
            } else {
                sysMessage = ZMSystemMessage(nonce: uAppointId, managedObjectContext: managedObjectContext)
                sysMessage.systemMessageType = ZMSystemMessageType.meetingReservationMessage
                sysMessage.serverTimestamp = eventTime
            }
            sysMessage.sender = sender
            sysMessage.visibleInConversation = conversation
            
            // 用户的邀请状态，由于服务端只在appointUserInviteStateChange的时候才推送，所以这里相当于对于inviteState进行一次保存
            var currentInviteState: MeetingReserved.InviteState? = configuration.inviteState ?? previousConfiguration?.inviteState
            if selfIsOwner {
                // 默认创建者为自己的邀请状态都是accepted
                currentInviteState = .accepted
            } else if currentInviteState == nil {
                currentInviteState = .pending
            }
            configuration.inviteState = currentInviteState
            sysMessage.text = configuration.jsonDescription
            
            if case .appointUserInviteStateChange = appointType, configuration.inviteState == .removed {
                //自己被从预约会议中移除，则将该条记录删除
                managedObjectContext.delete(sysMessage)
            }
            
            // 别人预约了一个会议，并邀请了自己
            if case .appointMeetStateChange = appointType, !selfIsOwner, configuration.appoint.state == .normal {
                ReceivedMeetingNotification(type: .receiveAppointInvited, notifyConfiguration: configuration).postNotification()
            }
            
            //更改数据库，保存
            managedObjectContext.saveOrRollback()
        }
    }
    
    //整个会议通知类似 服务通知一样，作为一个固定的conversation存在
    func createOrUpdateMeetingNoticeConversation(with convId: String, from: ZMUser, serverTimestamp: Date) -> ZMConversation? {
        guard let uCid = UUID(uuidString: convId) else { return nil }
        
        let conversation = ZMConversation(remoteID: uCid, createIfNeeded: true, in: managedObjectContext)
        conversation?.conversationType = .oneOnOne
        conversation?.updateLastModified(serverTimestamp)
        conversation?.updateServerModified(serverTimestamp)
        conversation?.isServiceNotice = true
        
        conversation?.internalAddParticipants([from])
        from.connection?.conversation = conversation
        
        return conversation
    }
    
    @discardableResult
    func createOrUpdateMeeting(notiInfo: MeetingReserved.Meeting) -> ZMMeeting? {
        return ZMMeeting.createOrUpdateMeeting(with: notiInfo.dictionaryData, context: managedObjectContext)
    }
    
}
