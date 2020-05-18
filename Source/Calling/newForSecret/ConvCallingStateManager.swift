//
//  ConvCallingStateManager.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/5/14.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation

///管理会话通话状态
private let zmLog = ZMSLog(tag: "calling")

enum CallingState: Hashable {
    case none
    case calling
    case recvCalling
    case connecting
    case connected
    ///群聊时，挂断后，只要该群聊中还有人在通话，就会成为.stillOngoing的状态，这样下一次可以直接点击answer
    case terminating(reason: CallClosedReason)
}

protocol UpdateCallStateDelegate {
    func updateCallState(in cid: UUID, userId: UUID, callState: CallState)
}

protocol CallingTimeoutDelegate {
    func callingTimeout(in cid: UUID, timeoutState: Int) ///timeoutState: 0-响应超时, 1-连接超时
}

class ConvCallingStateManager {
    
    fileprivate typealias Starter = (userId: UUID, clientId:  String)
    
    fileprivate class ConversationInfo: ZMTimerClient {
        fileprivate let cid: UUID
        fileprivate let convType: AVSConversationType
        fileprivate let callType: AVSCallType
        
        fileprivate let starter: Starter
        
        private var callTimer: ZMTimer?
        private let delegate: CallingTimeoutDelegate
        
        fileprivate var state: CallingState = .none {
            didSet {
                switch state {
                case .calling, .recvCalling, .connecting:
                    callTimer?.cancel()
                    callTimer = ZMTimer.init(target: self)
                    callTimer?.fire(afterTimeInterval: 60)
                case .connected, .terminating:
                    callTimer?.cancel()
                    callTimer = nil
                default:break;
                }
            }
        }
        
        init(cid: UUID, convType: AVSConversationType, callType: AVSCallType, starter: Starter, state: CallingState, delegate: CallingTimeoutDelegate) {
            self.cid = cid
            self.convType = convType
            self.callType = callType
            self.starter = starter
            self.state = state
            self.delegate = delegate
        }
        
        func timerDidFire(_ timer: ZMTimer!) {
            if self.state == .calling || self.state == .recvCalling {
                ///响应超时
                self.delegate.callingTimeout(in: self.cid, timeoutState: 0)
            } else if self.state == .connecting {
                ///连接超时
                self.delegate.callingTimeout(in: self.cid, timeoutState: 1)
            }
        }
        
        deinit {
            zmLog.info("mediasoup::CallingState-ConversationInfo--deinit")
        }
    }

    private let selfUserID: UUID
    private let selfClientID: String
    private var convsCallingState: [ConversationInfo]
    var delegate: UpdateCallStateDelegate?
 
    init(selfUserID: UUID, selfClientID: String) {
        self.selfUserID = selfUserID
        self.selfClientID = selfClientID
        self.convsCallingState = []
    }
    
    func startCall(cid: UUID, callType: AVSCallType, conversationType: AVSConversationType, userId: UUID, clientId: String) -> Bool {
        if self.convsCallingState.contains(where: { return $0.cid == cid }) {
            zmLog.info("mediasoup::error-startCall-already exist convInfo")
            return false
        }
        if self.convsCallingState.contains(where: { return ($0.state == .calling || $0.state == .recvCalling || $0.state == .connecting || $0.state == .connected) }) {
            ///说明当前正在通话中
            zmLog.info("mediasoup::error-startCall-already calling")
            return false
        }
        
        let info = ConversationInfo(cid: cid, convType: conversationType, callType: callType, starter: (userId, clientId), state: .calling, delegate: self)
        info.state = .calling
        self.convsCallingState.append(info)
        self.handleCallStateChange(in: info, userId: selfUserID, oldState: .none, newState: .calling)
        return true
    }
    
    public func answerCall(cid: UUID) -> Bool {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("mediasoup::error-answerCall-no exist convInfo")
            return false
        }
        guard convInfo.state == .recvCalling || convInfo.state == .terminating(reason: .stillOngoing) else {
            zmLog.info("mediasoup::error-answerCall-wrong state:\(convInfo.state)")
            return false
        }
        let previousState = convInfo.state
        convInfo.state = .connecting
        self.handleCallStateChange(in: convInfo, userId: selfUserID, oldState: previousState, newState: convInfo.state)
        return true
    }
    
    public func cancelCall(cid: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("mediasoup::error-cancelCall-no exist convInfo")
            return
        }
        guard convInfo.state == .calling else {
            zmLog.info("mediasoup::error-cancelCall-wrong state:\(convInfo.state)")
            return
        }
        let previousState = convInfo.state
        convInfo.state = .none
        self.handleCallStateChange(in: convInfo, userId: selfUserID, oldState: previousState, newState: .none)
    }
    
    public func endCall(cid: UUID, leftMemberCount: Int, reason: CallClosedReason) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("mediasoup::error-answerCall-no exist convInfo")
            return
        }
        
        let previousState = convInfo.state
        if convInfo.convType == .oneToOne {
            convInfo.state = .terminating(reason: reason)
        } else if convInfo.convType == .group {
            if reason == .timeout {///群聊，当因为未响应或者webSocket连接超时，导致超时时，改变该群的状态为still
                convInfo.state = .terminating(reason: .stillOngoing)
            } else {
                if leftMemberCount > 2 {
                    convInfo.state = .terminating(reason: .stillOngoing)
                } else {
                    convInfo.state = .terminating(reason: reason)
                }
            }
        }
        self.handleCallStateChange(in: convInfo, userId: selfUserID, oldState: previousState, newState: convInfo.state)
    }
    
    public func rejectCall(cid: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("mediasoup::error-rejectCall-no exist convInfo")
            return
        }
        guard convInfo.state == .recvCalling else {
            zmLog.info("mediasoup::error-rejectCall-wrong state:\(convInfo.state)")
            return
        }
        
        if convInfo.convType == .oneToOne {
            convInfo.state = .none
        } else if convInfo.convType == .group {
            convInfo.state = .terminating(reason: .stillOngoing)
        }
        self.handleCallStateChange(in: convInfo, userId: selfUserID, oldState: .recvCalling, newState: convInfo.state)
    }
    
    public func callConnecting(cid: UUID, userID: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("mediasoup::error-callEstablished-no exist convInfo")
            return
        }
        let previousState = convInfo.state
        convInfo.state = .connecting
        self.handleCallStateChange(in: convInfo, userId: selfUserID, oldState: previousState, newState: convInfo.state)
    }
    
    public func callEstablished(cid: UUID, userID: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("mediasoup::error-callEstablished-no exist convInfo")
            return
        }
        guard convInfo.state != .connected else {
            zmLog.info("mediasoup::error-callEstablished-wrong state:\(convInfo.state)")
            return
        }
        let previousState = convInfo.state
        convInfo.state = .connected
        self.handleCallStateChange(in: convInfo, userId: selfUserID, oldState: previousState, newState: convInfo.state)
    }
    
    private func handleCallStateChange(in conv: ConversationInfo, userId: UUID, oldState: CallingState, newState: CallingState) {
        guard let delegate = self.delegate else {
            return
        }
        switch (oldState, newState) {
        case (.none, .calling):
            delegate.updateCallState(in: conv.cid, userId: userId, callState: CallState.outgoing(degraded: false))
        case (.none, .recvCalling):
            delegate.updateCallState(in: conv.cid, userId: userId, callState: CallState.incoming(video: conv.callType == .video, shouldRing: true, degraded: false))
        case (.calling, .connecting):
            delegate.updateCallState(in: conv.cid, userId: userId, callState: CallState.answered(degraded: false))
        case (_, .connected):
            delegate.updateCallState(in: conv.cid, userId: userId, callState: .established)
        case (_, .terminating(reason: let reason)):
            delegate.updateCallState(in: conv.cid, userId: userId, callState: CallState.terminating(reason: reason))
            if reason != .stillOngoing {
                self.convsCallingState = self.convsCallingState.filter({ return $0.cid != conv.cid })
            }
        default:
            break
        }
        
    }
}

extension ConvCallingStateManager : CallingTimeoutDelegate {
    
    func callingTimeout(in cid: UUID, timeoutState: Int) {
        self.endCall(cid: cid, leftMemberCount: 0, reason: .timeout)
    }
    
}

///recv
extension ConvCallingStateManager {
    
    ///return : 当前正在通话中 则返回false, 错误则返回nil，正常就返回true
    func recvStartCall(cid: UUID, callType: AVSCallType, conversationType: AVSConversationType, userId: UUID, clientId: String) -> Bool? {
        if self.convsCallingState.contains(where: { return $0.cid == cid }) {
            zmLog.info("mediasoup::error-recvStartCall-already exist convInfo")
            return nil
        }
        if self.convsCallingState.contains(where: { return ($0.state == .calling || $0.state == .recvCalling || $0.state == .connecting || $0.state == .connected) }) {
            ///说明当前正在通话中
            zmLog.info("mediasoup::error-recvStartCall-already calling")
            return false
        }
        
        let info = ConversationInfo(cid: cid, convType: conversationType, callType: callType, starter: (userId, clientId), state: .recvCalling, delegate: self)
        info.state = .recvCalling
        self.convsCallingState.append(info)
        self.handleCallStateChange(in: info, userId: userId, oldState: .none, newState: info.state)
        
        return true
    }
    
    public func recvAnswerCall(cid: UUID, userID: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("mediasoup::error-recvAnswerCall-no exist convInfo")
            return
        }
        guard convInfo.state == .calling else {
            zmLog.info("mediasoup::error-recvAnswerCall-wrong state:\(convInfo.state)")
            return
        }
        convInfo.state = .connecting
        self.handleCallStateChange(in: convInfo, userId: userID, oldState: .calling, newState: convInfo.state)
    }
    
    public func recvCancelCall(cid: UUID, userID: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("mediasoup::error-recvCancelCall-no exist convInfo")
            return
        }
        guard convInfo.state == .calling else {
            zmLog.info("mediasoup::error-recvCancelCall-wrong state:\(convInfo.state)")
            return
        }
        convInfo.state = .terminating(reason: .canceled)
        self.handleCallStateChange(in: convInfo, userId: userID, oldState: .calling, newState: convInfo.state)
    }
    
    public func recvEndCall(cid: UUID, userID: UUID, leftMemberCount: Int, reason: CallClosedReason) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("mediasoup::error-recvEndCall-no exist convInfo")
            return
        }
        
        if convInfo.convType == .oneToOne {
            convInfo.state = .terminating(reason: reason)
        } else if convInfo.convType == .group {
            if leftMemberCount > 0 {
                //if convInfo.state == .connecting
                //convInfo.state = .terminating(reason: .stillOngoing)
            } else {
                convInfo.state = .terminating(reason: reason)
            }
        }
        self.handleCallStateChange(in: convInfo, userId: userID, oldState: .calling, newState: convInfo.state)
    }
    
    public func recvRejectCall(cid: UUID, userID: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("mediasoup::error-recvRejectCall-no exist convInfo")
            return
        }
        let privious = convInfo.state
        if convInfo.convType == .oneToOne {
            convInfo.state = .terminating(reason: .rejectedElsewhere)
        }
        self.handleCallStateChange(in: convInfo, userId: userID, oldState: privious, newState: convInfo.state)
    }
    
    public func recvBusyCall(cid: UUID, userID: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("mediasoup::error-recvBusyCall-no exist convInfo")
            return
        }
        if convInfo.convType == .oneToOne {
            convInfo.state = .terminating(reason: .busy)
        }
        self.handleCallStateChange(in: convInfo, userId: userID, oldState: .calling, newState: convInfo.state)
    }
    
}


