//
//  WireCallCenterV3+ReceiveMessage.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2021/2/23.
//  Copyright © 2021 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

private let zmLog = ZMSLog(tag: "calling")

/**
 * An object that represents a calling event.
 */

public struct CallEvent {
    let data: Data
    let currentTimestamp: Date
    let serverTimestamp: Date
    let conversationId: UUID
    let userId: UUID
    let clientId: String
    let voipString: String?
}

struct CallingEventModel {
    
    struct CallingInfo {
        let callAction: CallingAction
        let convType:  CallRoomType
        let mediaState:  CallMediaType
        
        init(callAction: CallingAction, convType:  CallRoomType, mediaState:  CallMediaType) {
            self.callAction = callAction
            self.convType = convType
            self.mediaState = mediaState
        }
        
        var json: JSON {
            let json = JSON(["call_state": callAction.rawValue,
                             "conv_type": convType.rawValue,
                             "call_type": mediaState.rawValue])
            return json
        }
        
        init?(json: JSON) {
            guard let callAction = CallingAction(rawValue: json["call_state"].intValue),
                  let convType = CallRoomType(rawValue: json["conv_type"].int32Value),
                  let mediaState = CallMediaType(rawValue: json["call_type"].intValue) else {
                return nil
            }
            self.callAction = callAction
            self.convType = convType
            self.mediaState = mediaState
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

let doNotDealCallingEventTimeInterval: TimeInterval = 90

extension WireCallCenterV3 {
    
    public func received(callEvent: CallEvent) -> CallError? {
        guard let callModel = CallingEventModel(callEvent: callEvent) else {
            return CallError.unknownProtocol
        }

        self.receiveCallingAction(with: callModel)
        return nil
    }
    
    func receiveCallingAction(with model: CallingEventModel) {
        zmLog.info("wrapper:receiveCallingAction--action:\(model.info.callAction),cid:\(model.cid),uid:\(model.userId),callDate:\(model.callDate)")
        
       ///开始信令发送时间小于当前时间90s前，则认为该信令无效
        if model.callDate.compare(Date(timeIntervalSinceNow: -doNotDealCallingEventTimeInterval)) == .orderedAscending && model.info.callAction == .start {
            self.handleMissedCall(conversationId: model.cid,
                                              messageTime: model.callDate,
                                              userId: model.userId,
                                              isVideoCall: model.info.mediaState.needSendVideo)
            return
        }
        //当前正在通话时，接收到了别人的电话邀请，则返回busy，并且显示一条miss的电话消息
        if self.activeCalls.count > 0 && model.info.callAction == .start {
            self.handleMissedCall(conversationId: model.cid,
                                              messageTime: model.callDate,
                                              userId: model.userId,
                                              isVideoCall: model.info.mediaState.needSendVideo)
            return
        }
        
        //接收到自己设备的同步消息
        if model.userId == self.selfUserId, model.clientId != self.selfClientId {
            self.receiveSelfClientSyncAction(with: model)
            return
        }
            
        switch model.info.callAction {
        case .start:
            self.handleIncomingCall(conversationId: model.cid, callType: model.info.convType, messageTime: model.callDate, callStater: (model.voipModel!.callerId, model.voipModel!.callerName), isVideoCall: model.info.mediaState.needSendVideo, shouldRing: true)
        case .answer:
            switch self.callState(conversationId: model.cid) {
            case .outgoing:
                self.handleAnsweredCall(conversationId: model.cid)
            default:
                break
            }
        case .reject:
            if model.info.convType == .oneToOne {
                self.handleCallEnd(reason: .busy, conversationId: model.cid, messageTime: model.callDate)
            }
        case .leave:
            self.callWrapper.removePeer(with: model.userId)
        case .end:
            if model.info.convType == .oneToOne {
                self.handleCallEnd(reason: .normal, conversationId: model.cid, messageTime: model.callDate)
            } else if model.info.convType == .group {
                if case .incoming = self.callState(conversationId: model.cid) {
                    //更新状态
                    self.handleCallEnd(reason: .normal, conversationId: model.cid, messageTime: model.callDate)
                    return
                }
                if self.callWrapper.members(in: model.cid).map(\.remoteId) == [model.userId] {
                    //与自己通话的另外一个用户发起了end则calling结束
                    self.handleCallEnd(reason: .normal, conversationId: model.cid, messageTime: model.callDate)
                } else {
                    self.callWrapper.removePeer(with: model.userId)
                }
            }
        case .cancel:
            self.handleCallEnd(reason: .canceled, conversationId: model.cid, messageTime: model.callDate)
        case .busy:
            if model.info.convType == .oneToOne {
                self.handleCallEnd(reason: .busy, conversationId: model.cid, messageTime: model.callDate)
            }
        }
    }
    
    //其他设备的同步消息
    func receiveSelfClientSyncAction(with model: CallingEventModel) {
        switch model.info.callAction {
        case .answer:
            ///自己的另外一个设备发送的answer消息，则此设备结束
            closeCall(conversationId: model.cid, reason: .anweredElsewhere)
        case .reject:
            ///自己的另外一个设备发送的reject消息，则此设备结束
            closeCall(conversationId: model.cid, reason: .rejectedElsewhere)
        case .busy:
            ///自己的另外一个设备发送的busy消息，则此设备结束
            closeCall(conversationId: model.cid, reason: .rejectedElsewhere)
        default: break
        }
    }
}

