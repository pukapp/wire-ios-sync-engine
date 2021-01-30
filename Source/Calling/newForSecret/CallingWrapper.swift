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
    
    public func startCall(conversationId: UUID, callerName: String, mediaState: AVSCallMediaState, conversationType: AVSConversationType, useCBR: Bool, members: [CallMemberProtocol], token: String?) -> Bool {
        self.callStateManager.observer = self
        return callStateManager.startCall(cid: conversationId, callerName: callerName, mediaState: mediaState, conversationType: conversationType, members: members, token: token)
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
    
    func changeCallStateNeedToSendMessage(in cid: UUID, callAction: CallingAction, memberCount: Int? = nil) {
        self.sendCallingAction(with: callAction, cid: cid, memberCount: memberCount)
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
    
    //发送消息时，增加voipString的参数
    var needVoipNoti: Bool {
        switch self {
        case .start, .cancel:
           return true
        default:
            return false
        }
    }
    //该消息是否同步给自己账号的其他设备
    var shouldSyncOtherClients: Bool {
        switch self {
        case .start, .cancel:
            return false
        default:
            return true
        }
    }
}

struct CallingEventModel {
    
    struct CallingInfo {
        let callAction: CallingAction
        let convType:  AVSConversationType
        let mediaState:  AVSCallMediaState
        var memberCount: Int? ///用来记录群聊时剩余的通话人数，当为0 则所有人的状态改变 有stillgoingOn -> end
        
        init(callAction: CallingAction, convType:  AVSConversationType, mediaState:  AVSCallMediaState, memberCount: Int?) {
            self.callAction = callAction
            self.convType = convType
            self.mediaState = mediaState
            self.memberCount = memberCount
        }
        
        var json: JSON {
            var json = JSON(["call_state": callAction.rawValue,
                             "conv_type": convType.rawValue,
                             "call_type": mediaState.rawValue])
            if let memberCount = memberCount {
                json["member_count"] = JSON(memberCount)
            }
            return json
        }
        
        init?(json: JSON) {
            guard let callAction = CallingAction(rawValue: json["call_state"].intValue),
                  let convType = AVSConversationType(rawValue: json["conv_type"].int32Value),
                  let mediaState = AVSCallMediaState(rawValue: json["call_type"].intValue) else {
                return nil
            }
            self.callAction = callAction
            self.convType = convType
            self.mediaState = mediaState
            
            if let memberCount = json["member_count"].int {
                self.memberCount = memberCount
            }
        }
    }
    
    let cid: UUID
    let userId: UUID
    let clientId:  String
    let callDate: Date

    let info: CallingInfo
    var voipModel: CallingVoipModel?
    
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
        
        if let voipString = callEvent.voipString, let voipModel = CallingVoipModel(json: JSON(parseJSON: voipString)) {
            self.voipModel = voipModel
        }
    }
}

//组装voip数据，通过voip通道推送到手机，且手机接收到voip信息时必须调用callKit相关的API
struct CallingVoipModel {
    let cid: UUID
    let callAction: CallingAction
    let mediaState:  AVSCallMediaState
    let callerId: UUID
    let callerName: String
    
    init(cid: UUID, callAction: CallingAction, mediaState: AVSCallMediaState, callerId: UUID, callerName: String) {
        self.cid = cid
        self.callAction = callAction
        self.mediaState = mediaState
        self.callerId = callerId
        self.callerName = callerName
    }
    
    var json: JSON {
        return JSON(["cid": cid.transportString(),
                     "call_state": callAction.rawValue,
                     "call_type": mediaState.rawValue,
                     "caller_id": callerId.transportString(),
                     "caller_name": callerName])
    }
    
    init?(json: JSON) {
        guard let cid = json["cid"].string else { return nil }
        self.cid = UUID(uuidString: cid)!
        self.callAction = CallingAction(rawValue: json["call_state"].intValue)!
        self.mediaState = AVSCallMediaState(rawValue: json["call_type"].intValue)!
        self.callerId = UUID(uuidString: json["caller_id"].stringValue)!
        self.callerName = json["caller_name"].stringValue
    }
}

///SendCallingAction
extension CallingWrapper {
    
    fileprivate func sendCallingAction(with action: CallingAction, cid: UUID, memberCount: Int? = nil) {
        guard let callModeInfo = self.callStateManager.callModeInfo(with: cid) else {
            return
        }
        zmLog.info("wrapper:sendCallingAction---action:\(action)")
        let callInfo = CallingEventModel.CallingInfo.init(callAction: action, convType: callModeInfo.convType, mediaState: callModeInfo.mediaState, memberCount: callModeInfo.members.count)
        
        var voipData: JSON?
        if action.needVoipNoti {
            voipData = CallingVoipModel(cid: cid, callAction: action, mediaState: callModeInfo.mediaState, callerId: callModeInfo.starter.userId, callerName: callModeInfo.callerName).json
        }
        let newCalling = ZMNewCalling.newCalling(message: callInfo.json.description, canSynchronizeClients: action.shouldSyncOtherClients, voipString: voipData?.description)
        self.sendMessage(with: cid, newCalling: newCalling)
    }
    
    func sendBusyAction(cid: UUID, convType: AVSConversationType, mediaState: AVSCallMediaState) {
        let callInfo = CallingEventModel.CallingInfo.init(callAction: .busy, convType: convType, mediaState: mediaState, memberCount: nil)
        let newCalling = ZMNewCalling.newCalling(message: callInfo.json.description, canSynchronizeClients: CallingAction.busy.shouldSyncOtherClients, voipString: nil)
        self.sendMessage(with: cid, newCalling: newCalling)
    }
    
    func sendMessage(with cid: UUID, newCalling: ZMNewCalling) {
        let token = Unmanaged.passUnretained(self).toOpaque()
        self.callCenter?.handleCallMessageRequest(token: token, conversationId: cid, senderUserId: self.userId, senderClientId: self.clientId, newCalling: newCalling)
    }
    
}


let doNotDealCallingEventTimeInterval: TimeInterval = 90

///ReceiveCallingAction
extension CallingWrapper {
    
    func receiveCallingAction(with model: CallingEventModel) {
        zmLog.info("wrapper:receiveCallingAction--action:\(model.info.callAction),cid:\(model.cid),uid:\(model.userId),callDate:\(model.callDate)")
        
       ///开始信令发送时间小于当前时间90s前，则认为该信令无效
        if model.callDate.compare(Date(timeIntervalSinceNow: -doNotDealCallingEventTimeInterval)) == .orderedAscending && model.info.callAction == .start {
            self.callCenter?.handleMissedCall(conversationId: model.cid,
                                              messageTime: model.callDate,
                                              userId: model.userId,
                                              isVideoCall: model.info.mediaState.needSendVideo)
            return
        }
        //当前正在通话时，接收到了别人的电话邀请，则返回busy，并且显示一条miss的电话消息
        if self.callStateManager.isCalling && model.info.callAction == .start {
            self.sendBusyAction(cid: model.cid, convType: model.info.convType, mediaState: model.info.mediaState)
            self.callCenter?.handleMissedCall(conversationId: model.cid,
                                              messageTime: model.callDate,
                                              userId: model.userId,
                                              
                                              isVideoCall: model.info.mediaState.needSendVideo)
            return
        }
        
        //接收到自己设备的同步消息
        if model.userId == self.userId, model.clientId != self.clientId {
            self.receiveSelfClientSyncAction(with: model)
            return
        }
            
        switch model.info.callAction {
        case .start:
            self.callStateManager.observer = self
            let peer = AVSCallMember.init(userId: model.userId, callParticipantState: .connecting, isMute: false, videoState: .stopped)
            callStateManager.recvStartCall(cid: model.cid, callerName: model.voipModel!.callerName, mediaState: model.info.mediaState, conversationType: model.info.convType, userId: model.userId, clientId: model.clientId, members: [peer])
        case .answer:
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
    
    //其他设备的同步消息
    func receiveSelfClientSyncAction(with model: CallingEventModel) {
        switch model.info.callAction {
        case .answer:
            ///自己的另外一个设备发送的answer消息，则此设备结束
            
            self.callStateManager.endCall(cid: model.cid, reason: .anweredElsewhere)
        case .reject:
            ///自己的另外一个设备发送的reject消息，则此设备结束
            self.callStateManager.endCall(cid: model.cid, reason: .rejectedElsewhere)
        case .busy:
            ///自己的另外一个设备发送的busy消息，则此设备结束
            self.callStateManager.endCall(cid: model.cid, reason: .rejectedElsewhere)
        default: break
        }
    }

}
