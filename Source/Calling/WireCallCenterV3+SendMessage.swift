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
    case start = 0 //发起通话
    case answer = 1 //接受
    case reject = 2 //拒绝
    case leave = 3 //离开-专门用于群通话，当自己离开时房间还有人在通话就发此信令
    case end = 4 //结束通话
    case cancel = 5 //取消自己发起的通话
    case busy = 6 //当前处于忙碌状态
    
    
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

    //接收到他人通话请求，但是由于自己已经正在通话中，所以直接返回拒绝信令，且由于此通话请求没有保存在callSnapshots中，所以独立出来
    func sendBusyAction(cid: UUID, convType: CallRoomType, mediaState: CallMediaType) {
        let callInfo = CallingEventModel.CallingInfo.init(callAction: .busy, convType: convType, mediaState: mediaState)
        let newCalling = ZMNewCalling.newCalling(message: callInfo.json.description, canSynchronizeClients: CallingAction.busy.shouldSyncOtherClients, voipString: nil)
        self.send(conversationId: cid, userId: self.selfUserId, newCalling: newCalling)
    }

}
