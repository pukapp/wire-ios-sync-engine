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

protocol ConvsCallingStateObserve {
    func changeCallStateNeedToSendMessage(in cid: UUID, callAction: CallingAction, convType: AVSConversationType?, mediaState: AVSCallMediaState?, to: CallStarter?, memberCount: Int?)
    func updateCallState(in cid: UUID, callType: AVSConversationType, userId: UUID, callState: CallState)
    func onGroupMemberChange(conversationId: UUID, callType: AVSConversationType)
    func onVideoStateChange(peerId: UUID, videoState: VideoState)
    
    func onReceiveMeetingPropertyChange(in mid: UUID, with property: MeetingProperty)
}

protocol CallingTimeoutDelegate {
    func callingTimeout(in cid: UUID, timeoutState: Int) ///timeoutState: 0-响应超时, 1-连接超时
}

class ConvsCallingStateManager {
    
    private let selfUserID: UUID
    private let selfClientID: String
    private var convsCallingState: [ConversationCallingInfo]
    let roomManager: CallingRoomManager = CallingRoomManager.shareInstance
    var currentCid: UUID?
    var observer: ConvsCallingStateObserve?
 
    init(selfUserID: UUID, selfClientID: String) {
        self.selfUserID = selfUserID
        self.selfClientID = selfClientID
        self.convsCallingState = []
        self.roomManager.delegate = self
    }
    
    func setCallingConfigure(_ callingConfigure: CallingConfigure) {
        self.roomManager.setCallingConfigure(callingConfigure)
    }
    
    func startCall(cid: UUID, mediaState: AVSCallMediaState, conversationType: AVSConversationType, members: [CallMemberProtocol], token: String?) -> Bool {
        if roomManager.isCalling {
            return false
        }
        if self.convsCallingState.contains(where: { return $0.cid == cid }) {
            zmLog.info("ConvsCallingStateManager-error-startCall-already exist convInfo")
            return false
        }
        if self.convsCallingState.contains(where: { return $0.isInCalling }) {
            ///说明当前正在通话中
            zmLog.info("ConvsCallingStateManager-error-startCall-already calling")
            return false
        }
        let info = ConversationCallingInfo(cid: cid, convType: conversationType, mediaState: mediaState, starter: (selfUserID, selfClientID), members: members, state: .none, token: token, delegate: self)
        info.state = .outgoing(degraded: false)
        info.videoState = (mediaState == .video) ? .started : .stopped
        self.convsCallingState.append(info)
        self.handleCallStateChange(in: info, userId: self.selfUserID, oldState: .none, newState: info.state)
        self.observer?.changeCallStateNeedToSendMessage(in: cid, callAction: .start, convType: conversationType, mediaState: mediaState, to: nil, memberCount: members.count)
        return true
    }
    
    public func answerCall(cid: UUID, members: [CallMemberProtocol], token: String?) -> Bool {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("ConvsCallingStateManager-error-answerCall-no exist convInfo")
            return false
        }
        guard convInfo.state == .incoming(video: convInfo.videoState == .started, shouldRing: true, degraded: false) || convInfo.state == .terminating(reason: .stillOngoing) else {
            zmLog.info("ConvsCallingStateManager-error-answerCall-wrong state:\(convInfo.state)")
            return false
        }
        if roomManager.isCalling {
            return false
        }
        let previousState = convInfo.state
        convInfo.state = .answeredIncomingCall
        convInfo.members = members
        convInfo.token = token
        self.handleCallStateChange(in: convInfo, userId: selfUserID, oldState: previousState, newState: convInfo.state)
        self.observer?.changeCallStateNeedToSendMessage(in: cid, callAction: .answer, convType: nil, mediaState: nil, to: convInfo.starter, memberCount: nil)
        return true
    }
    
    public func cancelCall(cid: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("ConvsCallingStateManager-error-cancelCall-no exist convInfo")
            return
        }
        guard convInfo.state == .outgoing(degraded: false) else {
            zmLog.info("ConvsCallingStateManager-error-cancelCall-wrong state:\(convInfo.state)")
            return
        }
        let previousState = convInfo.state
        convInfo.state = .terminating(reason: .normal)
        self.handleCallStateChange(in: convInfo, userId: selfUserID, oldState: previousState, newState: convInfo.state)
        self.observer?.changeCallStateNeedToSendMessage(in: cid, callAction: .cancel, convType: nil, mediaState: nil, to: convInfo.starter, memberCount: nil)
    }
    
    public func endCall(cid: UUID, reason: CallClosedReason) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("ConvsCallingStateManager-error-answerCall-no exist convInfo")
            return
        }
        zmLog.info("ConvsCallingStateManager-endCall--memberCount:\(convInfo.members.count)--reason:\(reason)")
        
        let previousState = convInfo.state
        if convInfo.convType == .oneToOne {
            convInfo.state = .terminating(reason: reason)
        } else if convInfo.convType == .group || convInfo.convType == .conference {
//            if convInfo.starter.userId == self.selfUserID && convInfo.memberCount > 1 {
//                ///自己是发起者
//                convInfo.state = .terminating(reason: reason)
//            } else {
//
//            }
            if reason == .timeout {///群聊，当因为未响应或者webSocket连接超时，导致超时时，改变该群的状态为still
                convInfo.state = .terminating(reason: .stillOngoing)
            } else {
                if convInfo.members.count > 1 {
                    convInfo.state = .terminating(reason: .stillOngoing)
                } else {
                    convInfo.state = .terminating(reason: reason)
                }
            }
        }
        self.handleCallStateChange(in: convInfo, userId: selfUserID, oldState: previousState, newState: convInfo.state)
        if reason == .rejectedElsewhere {
            return
        }
        self.observer?.changeCallStateNeedToSendMessage(in: cid, callAction: .end, convType: nil, mediaState: nil, to: nil, memberCount: convInfo.members.count)
    }
    
    public func rejectCall(cid: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("ConvsCallingStateManager-error-rejectCall-no exist convInfo")
            return
        }
        guard convInfo.state == .incoming(video: false, shouldRing: false, degraded: false) else {
            zmLog.info("ConvsCallingStateManager-error-rejectCall-wrong state:\(convInfo.state)")
            return
        }
        
        let previousState = convInfo.state
        if convInfo.convType == .oneToOne {
            convInfo.state = .terminating(reason: .normal)
        } else if convInfo.convType == .group {
            convInfo.state = .terminating(reason: .stillOngoing)
        }
        self.handleCallStateChange(in: convInfo, userId: selfUserID, oldState: previousState, newState: convInfo.state)
        self.observer?.changeCallStateNeedToSendMessage(in: cid, callAction: .reject, convType: nil, mediaState: nil, to: convInfo.starter, memberCount: nil)
    }
    
    public func members(in conversationId: UUID) -> [CallMemberProtocol] {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == conversationId }) else {
            zmLog.info("ConvsCallingStateManager-members-no exist convInfo")
            return []
        }
        guard convInfo.isInCalling else {
            zmLog.info("ConvsCallingStateManager-members-convInfo state is wrong :\(convInfo.state)")
            return []
        }
        return roomManager.roomMembersManager?.callMembers ?? []
    }
    
    func setVideoState(conversationId: UUID, videoState: VideoState) {
        roomManager.setLocalVideo(state: videoState)
    }
    
    func mute(_ muted: Bool){
        roomManager.setLocalAudio(mute: muted)
    }
    
    public func muteOther(_ userId: String, isMute: Bool) {
        roomManager.muteOther(userId, isMute: isMute)
    }
    
    func topUser(_ userId: String) {
        roomManager.topUser(userId)
    }
    
    private func handleCallStateChange(in conv: ConversationCallingInfo, userId: UUID, oldState: CallState, newState: CallState) {
        zmLog.info("ConvsCallingStateManager-handleCallStateChange---oldState\(oldState)--newState\(newState)--observer:\(String(describing: observer))")
        guard let observer = self.observer, oldState != newState else {
            return
        }
        ///不是群聊，并且还有人在聊天的话，就清空状态
        switch newState {
        case .outgoing:
            AVSMediaManager.sharedInstance.startCall()
            roomManager.connectToRoom(with: conv.cid, userId: self.selfUserID, roomMode: conv.convType, videoState: conv.videoState, isStarter: true, members: conv.members, token: conv.token)
        case .answered:
            AVSMediaManager.sharedInstance.callConnecting()
        case .incoming(video: let video, shouldRing: let shouldRing, degraded: _):
            if shouldRing {
                AVSMediaManager.sharedInstance.incomingCall(isVideo: video)
            }
        case .established:
            AVSMediaManager.sharedInstance.enterdCall()
            if conv.videoState == .started {
                //当连接成功之后，需要判断下视频状态是否是开启状态，如开启，则改为扩音模式
                AVSMediaManager.sharedInstance.isSpeakerEnabled = true
            }
        case .answeredIncomingCall:
            AVSMediaManager.sharedInstance.callConnecting()
            //todo: answer端初始是不开启视频的
            roomManager.connectToRoom(with: conv.cid, userId: self.selfUserID, roomMode: conv.convType, videoState: conv.videoState, isStarter: false, members: conv.members, token: conv.token)
        case .terminating(reason: let reason):
            AVSMediaManager.sharedInstance.exitCall()
            if reason != .stillOngoing {
                self.convsCallingState = self.convsCallingState.filter({ return $0.cid != conv.cid })
            }
            roomManager.leaveRoom(with: conv.cid)
        default: break
        }
        observer.updateCallState(in: conv.cid, callType: conv.convType, userId: userId, callState: newState)
    }
}

///recv
extension ConvsCallingStateManager {
    
    ///return : 当前正在通话中 则返回false, 错误则返回nil，正常就返回true
    func recvStartCall(cid: UUID, mediaState: AVSCallMediaState, conversationType: AVSConversationType, userId: UUID, clientId: String, members: [CallMemberProtocol]) {
        if self.convsCallingState.contains(where: { return $0.isInCalling }) {
            ///说明当前正在通话中
            zmLog.info("ConvsCallingStateManager-error-recvStartCall-already calling")
            self.observer?.changeCallStateNeedToSendMessage(in: cid, callAction: .busy, convType: nil, mediaState: nil, to: nil, memberCount: nil)
            return
        }
        if let conv = self.convsCallingState.first(where: { return $0.cid == cid }), conv.state != .terminating(reason: .stillOngoing) {
            zmLog.info("ConvsCallingStateManager-error-recvStartCall-already exist convInfo")
            return
        }
        let info = ConversationCallingInfo(cid: cid, convType: conversationType, mediaState: mediaState, starter: (userId, clientId), members: members, state: .none, token: nil, delegate: self)
        info.state = .incoming(video: mediaState == .video, shouldRing: true, degraded: false)
        //接收来电的话，则默认不会开启视频
        info.videoState = .stopped
        self.convsCallingState.append(info)
        self.handleCallStateChange(in: info, userId: userId, oldState: .none, newState: info.state)
    }
    
    public func recvAnswerCall(cid: UUID, userID: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("ConvsCallingStateManager-error-recvAnswerCall-no exist convInfo")
            return
        }
        guard convInfo.state == .outgoing(degraded: false) else {
            zmLog.info("ConvsCallingStateManager-error-recvAnswerCall-wrong state:\(convInfo.state)")
            return
        }
        let privious = convInfo.state
        convInfo.state = .answered(degraded: false)
        self.handleCallStateChange(in: convInfo, userId: userID, oldState: privious, newState: convInfo.state)
    }
    
    public func recvCancelCall(cid: UUID, userID: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("ConvsCallingStateManager-error-recvCancelCall-no exist convInfo")
            return
        }
        guard convInfo.state == .outgoing(degraded: false) else {
            zmLog.info("ConvsCallingStateManager-error-recvCancelCall-wrong state:\(convInfo.state)")
            return
        }
        let privious = convInfo.state
        if convInfo.convType == .oneToOne {
            convInfo.state = .terminating(reason: .canceled)
        }
        self.handleCallStateChange(in: convInfo, userId: userID, oldState: privious, newState: convInfo.state)
    }
    
    public func recvEndCall(cid: UUID, userID: UUID, reason: CallClosedReason, leftMemberCount: Int? = nil) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("ConvsCallingStateManager-error-recvEndCall-no exist convInfo")
            return
        }
        roomManager.removePeer(with: userID)
        
        let privious = convInfo.state
        if convInfo.convType == .oneToOne {
            convInfo.state = .terminating(reason: reason)
        } else if convInfo.convType == .group {
            if let leftMemberCount = leftMemberCount, leftMemberCount <= 1, convInfo.state == .terminating(reason: .stillOngoing)  {
                convInfo.state = .terminating(reason: reason)
            } else {
                if convInfo.members.count == 0 {
                    convInfo.state = .terminating(reason: reason)
                    self.observer?.changeCallStateNeedToSendMessage(in: cid, callAction: .end, convType: nil, mediaState: nil, to: nil, memberCount: 0)
                }
            }
        }
        self.handleCallStateChange(in: convInfo, userId: userID, oldState: privious, newState: convInfo.state)
    }
    
    public func recvRejectCall(cid: UUID, userID: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("ConvsCallingStateManager-error-recvRejectCall-no exist convInfo")
            return
        }
        let privious = convInfo.state
        ///自己其他设备发送的拒绝
        if userID == self.selfUserID {
            convInfo.state = .terminating(reason: .rejectedElsewhere)
        } else {
            if convInfo.convType == .oneToOne {
                convInfo.state = .terminating(reason: .normal)
            }
        }
        self.handleCallStateChange(in: convInfo, userId: userID, oldState: privious, newState: convInfo.state)
    }
    
    public func recvBusyCall(cid: UUID, userID: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == cid }) else {
            zmLog.info("ConvsCallingStateManager-error-recvBusyCall-no exist convInfo")
            return
        }
        let privious = convInfo.state
        if convInfo.convType == .oneToOne {
            convInfo.state = .terminating(reason: .busy)
        }
        self.handleCallStateChange(in: convInfo, userId: userID, oldState: privious, newState: convInfo.state)
    }
    
}

///房间状态用代理返回
extension ConvsCallingStateManager: CallingRoomManagerDelegate {
    
    func onReceiveMeetingPropertyChange(in mid: UUID, with property: MeetingProperty) {
        self.observer?.onReceiveMeetingPropertyChange(in: mid, with: property)
    }
    
    func onEstablishedCall(conversationId: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == conversationId }) else {
            zmLog.info("ConvsCallingStateManager-error-onEstablishedCall-no exist convInfo")
            return
        }
        guard convInfo.state != .established else {
            zmLog.info("ConvsCallingStateManager-error-callEstablished-wrong state:\(convInfo.state)")
            return
        }
        let previousState = convInfo.state
        convInfo.state = .established
        self.handleCallStateChange(in: convInfo, userId: selfUserID, oldState: previousState, newState: convInfo.state)
    }
    
    func onReconnectingCall(conversationId: UUID) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == conversationId }) else {
            zmLog.info("ConvsCallingStateManager-error-onReconnectingCall-no exist convInfo")
            return
        }
        guard convInfo.state != .reconnecting else {
            zmLog.info("ConvsCallingStateManager-error-onReconnectingCall-wrong state:\(convInfo.state)")
            return
        }
        let previousState = convInfo.state
        convInfo.state = .reconnecting
        self.handleCallStateChange(in: convInfo, userId: selfUserID, oldState: previousState, newState: convInfo.state)
    }
    
    func  leaveRoom(conversationId: UUID, reason: CallClosedReason) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == conversationId }) else {
            zmLog.info("ConvsCallingStateManager-error-leaveRoom-no exist convInfo")
            return
        }
        guard convInfo.state != .terminating(reason: .stillOngoing) else {
            zmLog.info("ConvsCallingStateManager-error-leaveRoom-wrong state:\(convInfo.state)")
            return
        }
        let previousState = convInfo.state
        if convInfo.convType == .oneToOne {
            convInfo.state = .terminating(reason: reason)
        } else if convInfo.convType == .group {
            if reason == .timeout {///群聊，当因为未响应或者webSocket连接超时，导致超时时，改变该群的状态为still
                convInfo.state = .terminating(reason: .stillOngoing)
            } else {
                if convInfo.members.count > 1 {
                    convInfo.state = .terminating(reason: .stillOngoing)
                } else {
                    convInfo.state = .terminating(reason: reason)
                }
            }
        } else if convInfo.convType == .conference {
            if reason != .terminate {
                convInfo.state = .terminating(reason: .stillOngoing)
            } else {
                convInfo.state = .terminating(reason: reason)
            }
        }
        self.handleCallStateChange(in: convInfo, userId: selfUserID, oldState: previousState, newState: convInfo.state)
    }
    
    func onVideoStateChange(conversationId: UUID, memberId: UUID, videoState: VideoState) {
        observer?.onVideoStateChange(peerId: memberId, videoState: videoState)
    }
    
    func onGroupMemberChange(conversationId: UUID, memberCount: Int) {
        guard let convInfo = self.convsCallingState.first(where: { return $0.cid == conversationId }) else {
            zmLog.info("ConvsCallingStateManager-error-onGroupMemberChange-no exist convInfo")
            return
        }
        //convInfo.members.count = memberCount
        observer?.onGroupMemberChange(conversationId: conversationId, callType: convInfo.convType)
    }
    
}

///单个群的状态回调
extension ConvsCallingStateManager : CallingTimeoutDelegate {
    
    func callingTimeout(in cid: UUID, timeoutState: Int) {
        self.endCall(cid: cid, reason: .timeout)
    }
    
}
