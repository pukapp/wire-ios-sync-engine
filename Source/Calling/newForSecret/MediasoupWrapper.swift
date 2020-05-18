//
//  MediasoupWrapper.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/4/9.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

private let zmLog = ZMSLog(tag: "calling")

extension MediasoupWrapper: MediasoupRoomManagerDelegate {
    
    func onNewPeer(conversationId: UUID, peerId: UUID) {
        self.callStateManager.callConnecting(cid: conversationId, userID: peerId)
        
        self.callCenter?.handleEstablishedCall(conversationId: conversationId, userId: peerId)
        self.callCenter?.handleGroupMemberChange(conversationId: conversationId)
    }
    
    func onGroupMemberChange(conversationId: UUID) {
        self.callCenter?.handleGroupMemberChange(conversationId: conversationId)
    }
    
    func onNewConsumer(conversationId: UUID, peerId: UUID) {
        self.callStateManager.callEstablished(cid: conversationId, userID: peerId)
        
        self.callCenter?.handleEstablishedCall(conversationId: conversationId, userId: peerId)
    }
    
    func onVideoStateChange(peerId: UUID, videoStart: VideoState) {
        self.callCenter?.handleVideoStateChange(userId: peerId, newState: videoStart)
    }
    
    func leaveRoom(conversationId: UUID, reason: CallClosedReason) {
        self.closeCall(with: conversationId, reason: reason)
    }
    
    private func closeCall(with conversationId: UUID, reason: CallClosedReason) {
        self.callStateManager.endCall(cid: conversationId, leftMemberCount: self.members(in: conversationId).count, reason: reason)
        
        //self.callCenter?.handleCallEnd(reason: CallClosedReason.normal, conversationId: conversationId, messageTime: Date(), userId: self.userId)
        self.sendCallingAction(with: (reason == .timeout ? .noResponse : .end), cid: conversationId, memberCount: self.members(in: conversationId).count)
        MediasoupRoomManager.shareInstance.leaveRoom(with: conversationId)
    }
    
}

fileprivate typealias CallerInfo = (userId: UUID, clientId:  String)

///群语音采用mediasoup
public class MediasoupWrapper: AVSWrapperType {
    
    private let userId: UUID
    private let clientId: String
    private var callCenter: WireCallCenterV3?
    
    private let callStateManager: ConvCallingStateManager
    
    public required init(userId: UUID, clientId: String, observer: UnsafeMutableRawPointer?) {
        self.userId = userId
        self.clientId = clientId
        if let observer = observer {
            self.callCenter = Unmanaged<WireCallCenterV3>.fromOpaque(observer).takeUnretainedValue()
        }
        self.callCenter?.setCallReady(version: 3)
        self.callStateManager = ConvCallingStateManager(selfUserID: self.userId, selfClientID: self.clientId)
    }
    
    public func startCall(conversationId: UUID, callType: AVSCallType, conversationType: AVSConversationType, useCBR: Bool) -> Bool {
        self.callStateManager.delegate = self
        let canStart = callStateManager.startCall(cid: conversationId, callType: callType, conversationType: conversationType, userId: self.userId, clientId: self.clientId)
        if canStart && MediasoupRoomManager.shareInstance.connectToRoom(with: conversationId,callType: callType, userId: userId, delegate: self) {
            self.sendCallingAction(with: .start, cid: conversationId, convType: conversationType, callType: callType)
        }
        return canStart
    }
    
    public func answerCall(conversationId: UUID, callType: AVSCallType, conversationType: AVSConversationType, useCBR: Bool) -> Bool {
        let canAnswer = callStateManager.answerCall(cid: conversationId)
        if canAnswer && MediasoupRoomManager.shareInstance.connectToRoom(with: conversationId, callType: callType, userId: userId, delegate: self) {
            self.sendCallingAction(with: .answer, cid: conversationId)
        }
        return canAnswer
    }
    
    public func endCall(conversationId: UUID) {
        callStateManager.endCall(cid: conversationId, leftMemberCount: self.members(in: conversationId).count, reason: .normal)
        self.sendCallingAction(with: .end, cid: conversationId)
        MediasoupRoomManager.shareInstance.leaveRoom(with: conversationId)
    }
    
    public func rejectCall(conversationId: UUID) {
        callStateManager.rejectCall(cid: conversationId)
        self.sendCallingAction(with: .reject, cid: conversationId)
    }
    
    public func close() {
        
    }
    
    public func received(callEvent: CallEvent) -> CallError? {
        guard let callModel = CallingModel(callEvent: callEvent) else {
            return CallError.unknownProtocol
        }

        self.receiveCallingAction(with: callModel)
        return nil
    }
    
    public func setVideoState(conversationId: UUID, videoState: VideoState) {
        MediasoupRoomManager.shareInstance.setLocalVideo(state: videoState)
    }
    
    public func handleResponse(httpStatus: Int, reason: String, context: WireCallMessageToken) {
        
    }
    
    public func members(in conversationId: UUID) -> [AVSCallMember] {
        return MediasoupRoomManager.shareInstance.roomPeersManager?.avsMembers ?? []
    }
    
    public func update(callConfig: String?, httpStatusCode: Int) {
        
    }
    
    public func mute(_ muted: Bool){
        MediasoupRoomManager.shareInstance.setLocalAudio(mute: muted)
    }

}

extension MediasoupWrapper: UpdateCallStateDelegate {
    func updateCallState(in cid: UUID, userId: UUID, callState: CallState) {
        switch callState {
        case .incoming(video: let video, shouldRing: let shouldRing, degraded: _):
            self.callCenter?.handleIncomingCall(conversationId: cid, messageTime: Date(), userId: userId, isVideoCall: video, shouldRing: shouldRing)
        case .answered:
            self.callCenter?.handleAnsweredCall(conversationId: cid)
        case .terminating(reason: let resaon):
            self.callCenter?.handleCallEnd(reason: resaon, conversationId: cid, messageTime: Date(), userId: userId)
        default: break;
        }
    }
}

extension MediasoupWrapper {
    
    func sendMessage(with cid: UUID, data: Data) {
        let token = Unmanaged.passUnretained(self).toOpaque()
        self.callCenter?.handleCallMessageRequest(token: token, conversationId: cid, senderUserId: self.userId, senderClientId: self.clientId, data: data)
    }
    
}

struct CallingModel {

    let callAction: CallingAction
    fileprivate let to: CallerInfo? ///消息接受者,当为nil时代表所有人都需要接收
    let memberCount: Int? ///用来记录群聊时剩余的通话人数，当为0 则所有人的状态改变 有stillgoingOn -> end
    let convType:  AVSConversationType?
    let callType:  AVSCallType?
    
    let cid: UUID
    let userId: UUID
    let clientId:  String
    let callData: Date
    
    init?(callEvent: CallEvent) {
        self.cid = callEvent.conversationId
        self.userId = callEvent.userId
        self.clientId = callEvent.clientId
        self.callData = callEvent.currentTimestamp
        
        let json = JSON(parseJSON: String(data: callEvent.data, encoding: .utf8)!)
        
        if let to = json["to"].dictionary {
            self.to = (UUID(uuidString: to["user_id"]!.stringValue)!, to["client_id"]!.stringValue)
        } else {
            self.to = nil
        }
        
        if let memberCount = json["member_count"].int {
            self.memberCount = memberCount
        } else {
            self.memberCount = nil
        }
        
        guard let callActionValue = json["call_state"].int,
            let callAction = CallingAction(rawValue: callActionValue) else {
            return nil
        }
        self.callAction = callAction
        
        if let convTypeValue = json["conv_type"].int,
            let convType = AVSConversationType(rawValue: Int32(convTypeValue)) {
            self.convType = convType
        } else {
            self.convType = nil
        }
        
        if let callTypeValue = json["call_type"].int,
            let callType = AVSCallType(rawValue: Int32(callTypeValue)) {
            self.callType = callType
        } else {
            self.callType = nil
        }
        
    }
}


enum CallingAction: Int {
    case start = 0
    case answer = 1
    case reject = 2
    case end = 3
    case cancel = 4
    case noResponse = 5
    case busy = 6
}

///send--CallingAction
extension MediasoupWrapper {
    
    fileprivate func sendCallingAction(with action: CallingAction, cid: UUID, convType: AVSConversationType? = nil, callType: AVSCallType? = nil, to: CallerInfo? = nil, memberCount: Int? = nil) {
        var json: JSON = ["call_state" : action.rawValue]
        if let convType = convType {
            json["conv_type"] = JSON(convType.rawValue)
        }
        if let callType = callType {
            json["call_type"] = JSON(callType.rawValue)
        }
        if let to = to {
            json["to"] = ["user_id": to.userId, "client_id": clientId]
        }
        if let memberCount = memberCount {
            json["member_count"] = JSON(memberCount)
        }
        zmLog.info("mediasoup::sendCallingAction---action:\(action)--cid:\(cid)--uid:\(self.userId)--clientId:\(self.clientId)\n")
        self.sendMessage(with: cid, data: json.description.data(using: .utf8)!)
    }
    
}

///receive--CallingAction
extension MediasoupWrapper {
    
    func receiveCallingAction(with model: CallingModel) {
        if model.callData.compare(Date(timeIntervalSinceNow: -60)) == .orderedAscending {
            ///信令发送时间小于当前时间60s前，则认为该信令无效
            if model.callAction == .start {
                self.callCenter?.handleMissedCall(conversationId: model.cid, messageTime: model.callData, userId: model.userId, isVideoCall: model.callType == .video)
            }
            zmLog.info("mediasoup::receiveUpdateCallingAction---action:\(model.callAction)--cid:\(model.cid)--uid:\(model.userId)--clientId:\(model.clientId)\n")
            return
        }
        
        if let toUser = model.to?.userId, toUser != self.userId {
            zmLog.info("mediasoup::receiveIgnoreCallingAction---action:\(model.callAction)--cid:\(model.cid)--uid:\(model.userId)--clientId:\(model.clientId)\n")
            return
        }
        
        zmLog.info("mediasoup::receiveCallingAction---action:\(model.callAction)--cid:\(model.cid)--uid:\(model.userId)--clientId:\(model.clientId)\n")
        switch model.callAction {
        case .start:
            self.callStateManager.delegate = self
            guard let callType = model.callType, let convType = model.convType else {
                return
            }
            guard let result = callStateManager.recvStartCall(cid: model.cid, callType: callType, conversationType: convType, userId: model.userId, clientId: model.clientId) else {
                return
            }
            if !result {
                ///当前正在通话中
                self.sendCallingAction(with: .busy, cid: model.cid)
            }
        case .answer:
            if model.userId == self.userId, model.clientId != self.clientId {
                ///自己的另外一个设备发送的answer消息，则此设备结束
                self.callStateManager.endCall(cid: model.cid, leftMemberCount: 0, reason: .anweredElsewhere)
            }
            callStateManager.recvAnswerCall(cid: model.cid, userID: model.userId)
        case .reject:
            callStateManager.recvRejectCall(cid: model.cid, userID: model.userId)
        case .end:
            callStateManager.recvEndCall(cid: model.cid, userID: model.userId, leftMemberCount: self.members(in: model.cid).count, reason: .normal)
        case .cancel:
            callStateManager.recvCancelCall(cid: model.cid, userID: model.userId)
        case .noResponse:
            callStateManager.recvEndCall(cid: model.cid, userID: model.userId, leftMemberCount: 0, reason: .timeout)
        case .busy:
            callStateManager.recvBusyCall(cid: model.cid, userID: model.userId)
        }
        
        
    }
    
}
