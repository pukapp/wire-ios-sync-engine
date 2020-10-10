//
//  CallingSignalManager+Meeting.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/9/21.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation

//会议信令
enum MeetingSignalAction {
    
    enum Request: String {
        case muteOther           = "muteOther"          //对成员进行静音
    }
    
    enum Notification: String {
        case openMute           = "openMute"            //开启全员静音(不强制)
        case openForceMute      = "openForceMute"       //开启全员静音(强制)
        case closeMute          = "closeMute"           //关闭全员静音
        case changeRoomProperty = "changeRoomProperty"  //改变房间属性
        
        enum ChangeRoomProperty: String {
            case lockMeet           = "lockMeet"            //锁定会议
            case unlockMeet         = "unlockMeet"          //解除锁定
            case openScreenShared   = "openScreenShared"    //请求成员开启屏幕共享
            case closeScreenShared  = "closeScreenShared"   //关闭成员屏幕共享
            case newSpeaker         = "newSpeaker"          //设为主讲人身份
            case cancelSpeaker      = "cancelSpeaker"       //取消主讲人身份
            case newHolder          = "newHolder"           //新的主持人
            case watchUser          = "watch_user"          //全员看TA
        }
        
        case kickoutMeet        = "peerKickout"         //踢出会议
        case terminateMeet      = "terminateMeet"       //结束会议
        case inviteUser         = "inviteUser"          //邀请人进会议
    }
    
}

extension MediasoupClientManager {
    
    func muteOther(_ userId: String, isMute: Bool) {
        
    }
    
}
