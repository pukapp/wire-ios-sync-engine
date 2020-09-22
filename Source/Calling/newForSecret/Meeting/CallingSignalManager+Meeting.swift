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
    
    enum Notification: String {
        case openMute           = "openMute"            //开启全员静音(不强制)
        case openForceMute      = "openForceMute"       //开启全员静音(强制)
        case closeMute          = "closeMute"           //关闭全员静音
        case lockMeet           = "lockMeet"            //锁定会议
        case unlockMeet         = "unlockMeet"          //解除锁定
        case openScreenShared   = "openScreenShared"    //请求成员开启屏幕共享
        case closeScreenShared  = "closeScreenShared"   //关闭成员屏幕共享
        case newSpeaker         = "newSpeaker"          //设为主讲人身份
        case cancelSpeaker      = "cancelSpeaker"       //取消主讲人身份
        
        case kickoutMeet        = "kickoutMeet"         //踢出会议
        case terminateMeet      = "terminateMeet"       //结束会议
    }
    
}

