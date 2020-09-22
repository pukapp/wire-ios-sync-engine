//
//  ConversationCallingInfo.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/5/26.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation

private let zmLog = ZMSLog(tag: "calling")

private let CallingEstablishedTimeoutInterval: TimeInterval = 80
///发起者
typealias CallStarter = (userId: UUID, clientId:  String)

///单个聊天的电话状态记录（因为在群聊中，你挂断了，但是只要还有人在通话，就还是需要保存一个状态，用来开始下一次的重新连接）
class ConversationCallingInfo: ZMTimerClient {
    let cid: UUID
    let convType: AVSConversationType
    let mediaState: AVSCallMediaState
    let starter: CallStarter
    
    var memberCount: Int = 0
    var videoState: VideoState = .stopped
    
    private var callTimer: ZMTimer?
    private let delegate: CallingTimeoutDelegate
    
    ///状态的变化中除了已连接和挂断，都需要开启一个定时器来判断是否连接超时
    var state: CallState = .none {
        didSet {
            switch state {
            case .outgoing, .incoming, .answered, .reconnecting:
                callTimer?.cancel()
                callTimer = ZMTimer.init(target: self)
                callTimer?.fire(afterTimeInterval: CallingEstablishedTimeoutInterval)
            case .established, .terminating:
                callTimer?.cancel()
                callTimer = nil
            default:break;
            }
        }
    }
    
    var isInCalling: Bool {
        switch state {
        case .outgoing, .incoming, .answered, .reconnecting, .established:
            return true
        default: return false
        }
    }
    
    init(cid: UUID, convType: AVSConversationType, mediaState: AVSCallMediaState, starter: CallStarter, state: CallState, delegate: CallingTimeoutDelegate) {
        self.cid = cid
        self.convType = convType
        self.mediaState = mediaState
        self.starter = starter
        self.state = state
        self.delegate = delegate
    }
    
    func timerDidFire(_ timer: ZMTimer!) {
        if self.state != .established {
            ///响应超时
            self.delegate.callingTimeout(in: self.cid, timeoutState: 0)
        }
    }
    
    deinit {
        zmLog.info("ConversationCallingInfo-deinit")
    }
}
