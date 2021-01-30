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
    let callerName: String
    
    var members: [CallMemberProtocol]
    private var callTimer: ZMTimer?
    private let delegate: CallingTimeoutDelegate
    
    var token: String? //会议模式连接websocket所需
    
    ///状态的变化中除了已连接和挂断，都需要开启一个定时器来判断是否连接超时
    var state: CallState = .none {
        didSet {
            guard self.convType != .conference else { return }//会议模式不需要进行计时
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
        case .outgoing, .incoming, .answered, .answeredIncomingCall, .reconnecting, .established:
            return true
        default: return false
        }
    }
    
    init(cid: UUID, callerName: String, convType: AVSConversationType, mediaState: AVSCallMediaState, starter: CallStarter, members: [CallMemberProtocol], state: CallState, token: String?, delegate: CallingTimeoutDelegate) {
        self.cid = cid
        self.callerName = callerName
        self.convType = convType
        self.mediaState = mediaState
        self.starter = starter
        self.state = state
        self.members = members
        self.token = token
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
