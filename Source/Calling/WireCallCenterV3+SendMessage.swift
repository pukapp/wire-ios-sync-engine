//
//  WireCallCenterV3+SendMessage.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2021/2/5.
//  Copyright © 2021 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

private let zmLog = ZMSLog(tag: "calling")

enum CallingAction: Int {
    case start = 0
    case answer
    case reject
    case leave
    case end
    case cancel
    case busy
    
    
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

//组装voip数据，通过voip通道推送到手机，且手机接收到voip信息时必须调用callKit相关的API
struct CallingVoipModel {
    let cid: UUID
    let callAction: CallingAction
    let mediaState:  CallMediaType
    let callerId: UUID
    let callerName: String
    
    init(cid: UUID, callAction: CallingAction, mediaState: CallMediaType, callerId: UUID, callerName: String) {
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
        guard let cid = json["cid"].string,
              let callActionValue = json["call_state"].int else { return nil }
        self.cid = UUID(uuidString: cid)!
        self.callAction = CallingAction(rawValue: callActionValue)!
        self.mediaState = CallMediaType(rawValue: json["call_type"].intValue)!
        self.callerId = UUID(uuidString: json["caller_id"].stringValue)!
        self.callerName = json["caller_name"].stringValue
    }
}


extension WireCallCenterV3 {

    func sendCallingAction(_ action: CallingAction, cid: UUID) {
        zmLog.info("wrapper:sendCallingAction---action:\(action)---snapshot:\(self.callSnapshots[cid])")
        guard let snapshot = self.callSnapshots[cid] else { return }

        let callInfo = CallingEventModel.CallingInfo(callAction: action, convType: snapshot.callType, mediaState: snapshot.mediaState)
        var voipData: JSON?
        if action.needVoipNoti {
            voipData = CallingVoipModel(cid: cid, callAction: action, mediaState: snapshot.mediaState, callerId: snapshot.callStarter.id, callerName: snapshot.callStarter.name).json
        }
        let newCalling = ZMNewCalling.newCalling(message: callInfo.json.description, canSynchronizeClients: action.shouldSyncOtherClients, voipString: voipData?.description)
        self.send(conversationId: cid, userId: self.selfUserId, newCalling: newCalling)
    }

//    func sendBusyAction(cid: UUID, convType: CallRoomType, mediaState: CallMediaType) {
//        let callInfo = CallingEventModel.CallingInfo.init(callAction: .busy, convType: convType, mediaState: mediaState, memberCount: nil)
//        let newCalling = ZMNewCalling.newCalling(message: callInfo.json.description, canSynchronizeClients: CallingAction.busy.shouldSyncOtherClients, voipString: nil)
//        self.sendMessage(with: cid, newCalling: newCalling)
//    }
//

}
