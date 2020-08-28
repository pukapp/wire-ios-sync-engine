//
//  CallingSignalManager+P2P.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/7/25.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

private let zmLog = ZMSLog(tag: "calling")

enum WebRTCP2PSignalAction {
    
    enum sendRequest: String {
        case getP2PInfo = "getP2PInfo"
        case forward = "forward"
        case switchRoomMode = "switchRoomMode"
    }
    
    enum ReceiveRequest: String {
        case forward = "forward"
    }
    
    enum Notification: String {
        case peerOpened = "peerOpened"
    }
    
}

///p2p + sendMessage
extension CallingSignalManager {

    func forwardP2PMessage(to peerId: String, message: WebRTCP2PMessage) {
        zmLog.info("WebRTCClientManager forwardP2PMessage -- \(message)")
        self.forwardSocketMessage(to: peerId, method: "forward", data: message.json)
    }
    
    func requestToJudgeIsPeerAlreadyInRoom(completion: @escaping (Bool) -> Void) {
        sendSocketRequest(with: "getP2PInfo", data: nil) { (res) in
            guard !res.ok, res.data == nil, let peerCount = res.data!["peerCount"].int else {
                completion(false)
                return
            }
            completion(peerCount > 1)
        }
    }
    
    func requestToSwitchRoomMode(to mode: RoomMode, completion: @escaping (Bool) -> Void) {
        sendSocketRequest(with: WebRTCP2PSignalAction.sendRequest.switchRoomMode.rawValue, data: ["roomMode": mode.rawValue], completion: { res in
            completion(res.ok)
        })
    }
}
