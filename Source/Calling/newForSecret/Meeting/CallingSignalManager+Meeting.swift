//
//  CallingSignalManager+Meeting.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/9/21.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

private let zmLog = ZMSLog(tag: "calling")

//会议信令
enum MeetingSignalAction {
    
    enum Request: String {
        case muteOther           = "muteOther"          //对成员进行静音
    }
    
    enum Notification: String {
        case peerOpened         = "peerOpened"          //用户websocket连接成功
        case openMute           = "openMute"            //开启全员静音(不强制)
        case openForceMute      = "openForceMute"       //开启全员静音(强制)
        case closeMute          = "closeMute"           //关闭全员静音
        case peerOpenMute       = "peerOpenMute"        //成员被静音
        case peerCloseMute      = "peerCloseMute"       //请求取消成员的静音
        case kickoutMeet        = "peerKickout"         //踢出会议
        case terminateMeet      = "terminateMeet"       //结束会议
        case inviteUser         = "inviteUser"          //邀请人进会议
        
        case changeRoomProperty = "changeRoomProperty"  //改变房间属性
        enum ChangeRoomProperty: String {
            case setInternal        = "internal"            //是否设置会议为内部会议，仅允许组织内部人员加入
            case lockMeet           = "lock_meeting"            //锁定会议
            case onlyHosterCanShareScreen = "screen_share"  //仅主持人可以分享屏幕
            case newSpeaker         = "speaker"          //设为主讲人身份
            case cancelSpeaker      = "cancelSpeaker"       //取消主讲人身份
            case newHolder          = "holder"           //新的主持人
            case watchUser          = "watch_user"          //全员看TA
            case screenShareUser    = "screen_share_user"   //当前正在屏幕分享的用户
        }
        
        case changeUserProperty = "changeUserProperty" //改变成员属性
        case activeSpeaker = "activeSpeaker"            //获取当前正在说话的人
    }
    
    enum SendRequest {
        case muteOther(Bool)         //对成员进行静音
        
        var description: String {
            switch self {
            case .muteOther(let isMute):
                return isMute ? "peerOpenMute" : "peerCloseMute"
            }
        }
    }
    
}

///meeting + sendRequest
extension CallingSignalManager {
    
    func muteOther(_ userId: String, isMute: Bool) {
        let data: JSON = ["peerId" : userId]
        sendMeetingAction(to: userId, action: .muteOther(isMute), data: data)
    }
    
}


///meeting + SignalManager
extension CallingSignalManager {

    //发送请求给服务器
    private func sendMeetingAction(with action: MeetingSignalAction.SendRequest, data: JSON?) -> CallingSignalResponse? {
        return self.sendSocketRequest(with: action.description, data: data)
    }
    
    //发送请求来操作个人
    private func sendMeetingAction(to peerId: String, action: MeetingSignalAction.SendRequest, data: JSON?) {
        return self.forwardSocketMessage(to: peerId, method: action.description, data: data)
    }
    
}
