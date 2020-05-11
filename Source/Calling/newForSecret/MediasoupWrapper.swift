//
//  MediasoupWrapper.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/4/9.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

extension MediasoupWrapper: MediasoupRoomManagerDelegate {
    
    func onNewPeer(conversationId: UUID, peerId: UUID) {
        self.setCallState(.connecting)
        
        self.callCenter?.handleEstablishedCall(conversationId: conversationId, userId: peerId)
        self.callCenter?.handleGroupMemberChange(conversationId: conversationId)
    }
    
    func onGroupMemberChange(conversationId: UUID) {
        self.callCenter?.handleGroupMemberChange(conversationId: conversationId)
    }
    
    func onNewConsumer(conversationId: UUID, peerId: UUID) {
        self.setCallState(.connected)
        
        self.callCenter?.handleEstablishedCall(conversationId: conversationId, userId: peerId)
    }
    
    func onVideoStateChange(peerId: UUID, videoStart: VideoState) {
        self.callCenter?.handleVideoStateChange(userId: peerId, newState: videoStart)
    }
    
    func leaveRoom(conversationId: UUID, reason: CallClosedReason) {
        self.closeCall(with: conversationId, reason: reason)
    }
    
    private func closeCall(with conversationId: UUID, reason: CallClosedReason) {
        self.setCallState(.unConnected)
        
        self.callCenter?.handleCallEnd(reason: CallClosedReason.normal, conversationId: conversationId, messageTime: Date(), userId: self.userId)
        self.sendCallingAction(with: (reason == .timeout ? .noResponse : .end), cid: conversationId)
        MediasoupRoomManager.shareInstance.leaveRoom(with: conversationId)
    }
    
}

extension MediasoupWrapper: ZMTimerClient {
    
    public func timerDidFire(_ timer: ZMTimer!) {
        print("timerDidFire")
        switch currentCallState {
        case .calling, .connecting:
            ///对方60s无响应
            if let cid = self.currentConvInfo?.cid {
                self.leaveRoom(conversationId: cid, reason: .timeout)
            }
        case .connected, .unConnected:
            break;
        }
    }
    
}

///群语音采用mediasoup
public class MediasoupWrapper: AVSWrapperType {
    
    enum CallState: Int {
        case unConnected
        case calling
        case connecting
        case connected
    }
    
    private let userId: UUID
    private let clientId: String
    private var callCenter: WireCallCenterV3?
    
    typealias ConversationInfo = (cid: UUID, convType: AVSConversationType, callType: AVSCallType)
    
    private var currentConvInfo: ConversationInfo?
    
    var callTimer: ZMTimer?
    private var currentCallState: CallState = .unConnected
    
    private func setCallState(_ state: CallState) {
        self.currentCallState = state
        switch state {
        case .calling, .connecting:
            callTimer?.cancel()
            callTimer = ZMTimer(target: self)!
            callTimer?.fire(afterTimeInterval: 60)
        case .connected:
            callTimer?.cancel()
            callTimer = nil
        case .unConnected:
            callTimer?.cancel()
            callTimer = nil
        }
    }
    
    
    public required init(userId: UUID, clientId: String, observer: UnsafeMutableRawPointer?) {
        self.userId = userId
        self.clientId = clientId
        if let observer = observer {
            self.callCenter = Unmanaged<WireCallCenterV3>.fromOpaque(observer).takeUnretainedValue()
        }
        self.callCenter?.setCallReady(version: 3)
    }
    
    public func startCall(conversationId: UUID, callType: AVSCallType, conversationType: AVSConversationType, useCBR: Bool) -> Bool {
        self.setCallState(.calling)
        
        self.sendCallingAction(with: .start, cid: conversationId, convType: conversationType, callType: callType)
        self.currentConvInfo = (conversationId, conversationType, callType)
        return MediasoupRoomManager.shareInstance.connectToRoom(with: conversationId,callType: callType, userId: userId, delegate: self)
    }
    
    public func answerCall(conversationId: UUID, callType: AVSCallType, conversationType: AVSConversationType, useCBR: Bool) -> Bool {
        self.setCallState(. connecting)
        
        self.sendCallingAction(with: .answer, cid: conversationId)
        self.currentConvInfo = (conversationId, conversationType, callType)
        return MediasoupRoomManager.shareInstance.connectToRoom(with: conversationId, callType: callType, userId: userId, delegate: self)
    }
    
    public func endCall(conversationId: UUID) {
        self.setCallState(.unConnected)
        
        self.callCenter?.handleCallEnd(reason: CallClosedReason.normal, conversationId: conversationId, messageTime: Date(), userId: self.userId)
        self.sendCallingAction(with: .end, cid: conversationId)
        MediasoupRoomManager.shareInstance.leaveRoom(with: conversationId)
    }
    
    public func rejectCall(conversationId: UUID) {
        self.setCallState(.unConnected)
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

extension MediasoupWrapper {
    
    func sendMessage(with cid: UUID, data: Data) {
        let token = Unmanaged.passUnretained(self).toOpaque()
        self.callCenter?.handleCallMessageRequest(token: token, conversationId: cid, senderUserId: self.userId, senderClientId: self.clientId, data: data)
    }
    
}

struct CallingModel {
    let callAction: CallingAction
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
}

///send--CallingAction
extension MediasoupWrapper {
    
    func sendCallingAction(with action: CallingAction, cid: UUID, convType: AVSConversationType? = nil, callType: AVSCallType? = nil) {
        var json: JSON = ["call_state" : action.rawValue]
        if let convType = convType {
            json["conv_type"] = JSON(convType.rawValue)
        }
        if let callType = callType {
            json["call_type"] = JSON(callType.rawValue)
        }

        self.sendMessage(with: cid, data: json.description.data(using: .utf8)!)
    }
    
}

///receive--CallingAction
extension MediasoupWrapper {
    
    func receiveCallingAction(with model: CallingModel) {
        switch model.callAction {
        case .start:
            self.setCallState(.calling)
            self.callCenter?.handleIncomingCall(conversationId: model.cid, messageTime: model.callData, userId: model.userId, isVideoCall: model.callType == .video, shouldRing: true)
        case .answer:
            self.setCallState(.connecting)
            if model.userId == self.userId, model.clientId != self.clientId {
                self.callCenter?.handleCallEnd(reason: .anweredElsewhere, conversationId: model.cid, messageTime: model.callData, userId: model.userId)
            }
        case .reject:
            self.setCallState(.unConnected)
            
            if self.currentConvInfo?.convType == .oneToOne {
                if model.userId == self.userId, model.clientId != self.clientId {
                    self.callCenter?.handleCallEnd(reason: .rejectedElsewhere, conversationId: model.cid, messageTime: model.callData, userId: model.userId)
                } else {
                    self.callCenter?.handleCallEnd(reason: .normal, conversationId: model.cid, messageTime: model.callData, userId: model.userId)
                }
            } else {
                self.callCenter?.handleCallEnd(reason: .stillOngoing, conversationId: model.cid, messageTime: model.callData, userId: model.userId)
            }
        case .end:
            self.setCallState(.unConnected)
            if self.currentConvInfo?.convType == .oneToOne {
                self.callCenter?.handleCallEnd(reason: .normal, conversationId: model.cid, messageTime: model.callData, userId: model.userId)
            } else if self.currentConvInfo?.convType == .group && self.members(in: self.currentConvInfo!.cid).count == 0 {
                self.callCenter?.handleCallEnd(reason: .normal, conversationId: model.cid, messageTime: model.callData, userId: model.userId)
            }
        case .cancel:
            self.setCallState(.unConnected)
            self.callCenter?.handleCallEnd(reason: .canceled, conversationId: model.cid, messageTime: model.callData, userId: model.userId)
        case .noResponse:
            self.setCallState(.unConnected)
            self.callCenter?.handleCallEnd(reason: .timeout, conversationId: model.cid, messageTime: model.callData, userId: model.userId)
        }
        
        
    }
    
}
