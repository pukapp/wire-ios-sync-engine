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

//目前单聊采用webrtc,打洞失败才走mediasoup,群语音和会议则采用mediasoup
public class CallingWrapper: AVSWrapperType {
    
    private let userId: UUID
    private let clientId: String
    private var callCenter: WireCallCenterV3?
    
    private let callStateManager: ConvsCallingStateManager
    
    public required init(userId: UUID, clientId: String, observer: UnsafeMutableRawPointer?) {
        self.userId = userId
        self.clientId = clientId
        if let observer = observer {
            self.callCenter = Unmanaged<WireCallCenterV3>.fromOpaque(observer).takeUnretainedValue()
        }

        self.callStateManager = ConvsCallingStateManager(selfUserID: userId, selfClientID: clientId)
        
        CallingService.getConfigInfo(completionHandler: { callingConfigure in
            guard let callingConfigure = callingConfigure else { return }
            self.callCenter?.setCallReady(version: 3)
            self.callStateManager.setCallingConfigure(callingConfigure)
        })
    }
    
    public func startCall(conversationId: UUID, mediaState: AVSCallMediaState, conversationType: AVSConversationType, useCBR: Bool, members: [CallMemberProtocol], token: String?) -> Bool {
        self.callStateManager.observer = self
        return callStateManager.startCall(cid: conversationId, mediaState: mediaState, conversationType: conversationType, members: members, token: token)
    }
    
    public func answerCall(conversationId: UUID, mediaState: AVSCallMediaState, conversationType: AVSConversationType, useCBR: Bool, members: [CallMemberProtocol], token: String?) -> Bool {
        self.callStateManager.observer = self
        return callStateManager.answerCall(cid: conversationId, members: members, token: token)
    }
    
    public func endCall(conversationId: UUID, reason: CallClosedReason) {
        zmLog.info("wrapper:endCall--\(reason)")
        callStateManager.endCall(cid: conversationId, reason: reason)
    }
    
    public func rejectCall(conversationId: UUID) {
        callStateManager.rejectCall(cid: conversationId)
    }
    
    public func close() {
        
    }
    
    public func received(callEvent: CallEvent) -> CallError? {
        guard let callModel = CallingEventModel(callEvent: callEvent) else {
            return CallError.unknownProtocol
        }

        self.receiveCallingAction(with: callModel)
        return nil
    }
    
    public func setVideoState(conversationId: UUID, videoState: VideoState) {
        callStateManager.setVideoState(conversationId: conversationId, videoState: videoState)
    }
    
    public func handleResponse(httpStatus: Int, reason: String, context: WireCallMessageToken) {
        
    }
    
    public func members(in conversationId: UUID) -> [CallMemberProtocol] {
        return callStateManager.members(in :conversationId)
    }
    
    public func update(callConfig: String?, httpStatusCode: Int) {
        
    }
    
    public func muteSelf(isMute: Bool) {
        callStateManager.muteSelf(isMute: isMute)
    }
    
    public func muteOther(_ userId: String, isMute: Bool) {
        callStateManager.muteOther(userId, isMute: isMute)
    }
    
    public func topUser(_ userId: String) {
        callStateManager.topUser(userId)
    }

    public func setScreenShare(isStart: Bool) {
        callStateManager.setScreenShare(isStart: isStart)
    }
}

extension CallingWrapper: ConvsCallingStateObserve {
    
    func onReceiveMeetingPropertyChange(in mid: UUID, with property: MeetingProperty) {
        self.callCenter?.handleMeetingPropertyChange(in: mid, with: property)
    }
    
    func changeCallStateNeedToSendMessage(in cid: UUID, callAction: CallingAction, convType: AVSConversationType? = nil, mediaState: AVSCallMediaState? = nil, to: CallStarter?, memberCount: Int? = nil) {
        self.sendCallingAction(with: callAction, cid: cid, convType: convType, mediaState: mediaState, to: to, memberCount: memberCount)
    }
    
    func updateCallState(in cid: UUID, callType: AVSConversationType, userId: UUID, callState: CallState) {
        switch callState {
        case .incoming(video: let video, shouldRing: let shouldRing, degraded: _):
            self.callCenter?.handleIncomingCall(conversationId: cid, callType: callType, messageTime: Date(), userId: userId, isVideoCall: video, shouldRing: shouldRing)
        case .answered:
            self.callCenter?.handleAnsweredCall(conversationId: cid, callType: callType)
        case .terminating(reason: let resaon):
            self.callCenter?.handleCallEnd(reason: resaon, conversationId: cid, callType: callType, messageTime: Date(), userId: userId)
        case .established:
            self.callCenter?.handleEstablishedCall(conversationId: cid, callType: callType, userId: userId)
        case .reconnecting:
            self.callCenter?.handleReconnectingCall(conversationId: cid, callType: callType)
        default: break;
        }
    }
    
    func onGroupMemberChange(conversationId: UUID, callType: AVSConversationType) {
        self.callCenter?.handleGroupMemberChange(conversationId: conversationId)
    }
    
    func onVideoStateChange(peerId: UUID, videoState: VideoState) {
        self.callCenter?.handleVideoStateChange(userId: peerId, newState: videoState)
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

struct CallingEventModel {
    
    struct CallingInfo {
        let callAction: CallingAction
        var to: CallStarter? ///消息接受者,当为nil时代表所有人都需要接收
        var memberCount: Int? ///用来记录群聊时剩余的通话人数，当为0 则所有人的状态改变 有stillgoingOn -> end
        var convType:  AVSConversationType?
        var mediaState:  AVSCallMediaState?
        var data: Data?
        
        init?(json: JSON) {
            guard let callActionValue = json["call_state"].int,
                let callAction = CallingAction(rawValue: callActionValue) else {
                return nil
            }
            self.callAction = callAction
            
            if let to = json["to"].dictionary, let userId = to["user_id"]?.string, let clientId =  to["client_id"]?.string {
                self.to = (UUID(uuidString: userId)!, clientId)
            }
            if let memberCount = json["member_count"].int {
                self.memberCount = memberCount
            }
            if let convTypeValue = json["conv_type"].int,
                let convType = AVSConversationType(rawValue: Int32(convTypeValue)) {
                self.convType = convType
            }
            if let callTypeValue = json["call_type"].int,
                let mediaState = AVSCallMediaState(rawValue: callTypeValue) {
                self.mediaState = mediaState
            }
            if let data = try? json["data"].rawData() {
                self.data = data
            }
        }
    }
    
    let cid: UUID
    let userId: UUID
    let clientId:  String
    let callDate: Date

    let info: CallingInfo
    
    init?(callEvent: CallEvent) {
        let json = JSON(parseJSON: String(data: callEvent.data, encoding: .utf8)!)
        guard let info = CallingInfo(json: json) else {
            return nil
        }
        self.info = info
        
        self.cid = callEvent.conversationId
        self.userId = callEvent.userId
        self.clientId = callEvent.clientId
        self.callDate = callEvent.serverTimestamp
    }
}

///SendCallingAction
extension CallingWrapper {
    
    fileprivate func sendCallingAction(with action: CallingAction, cid: UUID, convType: AVSConversationType? = nil, mediaState: AVSCallMediaState? = nil, to: CallStarter? = nil, memberCount: Int? = nil, data: Data? = nil) {
        var json: JSON = ["call_state" : JSON(action.rawValue)]
        if let convType = convType {
            json["conv_type"] = JSON(convType.rawValue)
        }
        if let mediaState = mediaState {
            json["call_type"] = JSON(mediaState.rawValue)
        }
        if let to = to {
            json["to"] = JSON(["user_id": to.userId.uuidString, "client_id": to.clientId])
        }
        if let memberCount = memberCount {
            json["member_count"] = JSON(memberCount)
        }
        if let data = data {
            json["data"] = JSON(data)
        }
        zmLog.info("wrapper:sendCallingAction---json:\(json)")
        self.sendMessage(with: cid, data: json.description.data(using: .utf8)!)
    }
    
    func sendMessage(with cid: UUID, data: Data) {
        let token = Unmanaged.passUnretained(self).toOpaque()
        self.callCenter?.handleCallMessageRequest(token: token, conversationId: cid, senderUserId: self.userId, senderClientId: self.clientId, data: data)
    }
    
}


let doNotDealCallingEventTimeInterval: TimeInterval = 90

///ReceiveCallingAction
extension CallingWrapper {

    func receiveCallingAction(with model: CallingEventModel) {
        zmLog.info("wrapper:receiveCallingAction--action:\(model.info.callAction),cid:\(model.cid),uid:\(model.userId),callDate:\(model.callDate)")
        
       ///开始信令发送时间小于当前时间90s前，则认为该信令无效
        if model.callDate.compare(Date(timeIntervalSinceNow: -doNotDealCallingEventTimeInterval)) == .orderedAscending && model.info.callAction == .start {
            self.callCenter?.handleMissedCall(conversationId: model.cid, messageTime: model.callDate, userId: model.userId, isVideoCall: model.info.mediaState?.needSendVideo ?? false)
            return
        }
        //当前正在通话时，接收到了别人的电话邀请，则返回busy，并且显示一条miss的电话消息
        if self.callStateManager.isCalling && model.info.callAction == .start {
            self.sendCallingAction(with: .busy, cid: model.cid)
            self.callCenter?.handleMissedCall(conversationId: model.cid, messageTime: model.callDate, userId: model.userId, isVideoCall: model.info.mediaState?.needSendVideo ?? false)
            return
        }
        
        //如果消息是发给某个人的，则不是发给自己的就不接受
        if let toUser = model.info.to?.userId, toUser != self.userId {
            return
        }
        
        switch model.info.callAction {
        case .start:
            self.callStateManager.observer = self
            let peer = AVSCallMember.init(userId: model.userId, callParticipantState: .connecting, isMute: false, videoState: .stopped)
            callStateManager.recvStartCall(cid: model.cid, mediaState: model.info.mediaState!, conversationType: model.info.convType!, userId: model.userId, clientId: model.clientId, members: [peer])
        case .answer:
            if model.userId == self.userId, model.clientId != self.clientId {
                ///自己的另外一个设备发送的answer消息，则此设备结束
                self.callStateManager.endCall(cid: model.cid, reason: .anweredElsewhere)
            }
            callStateManager.recvAnswerCall(cid: model.cid, userID: model.userId)
        case .reject:
            callStateManager.recvRejectCall(cid: model.cid, userID: model.userId)
        case .end:
            callStateManager.recvEndCall(cid: model.cid, userID: model.userId, reason: .normal, leftMemberCount: model.info.memberCount)
        case .cancel:
            callStateManager.recvCancelCall(cid: model.cid, userID: model.userId)
        case .noResponse:
            callStateManager.recvEndCall(cid: model.cid, userID: model.userId, reason: .timeout)
        case .busy:
            callStateManager.recvBusyCall(cid: model.cid, userID: model.userId)
        }
    }

}
