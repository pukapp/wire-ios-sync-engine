//
//  CallingSignalManager+Mediasoup.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/7/22.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

private let zmLog = ZMSLog(tag: "calling")

//Mediasoup信令(通用)
enum MediasoupSignalAction {
    
    enum SendRequest: Hashable {
        case getRouterRtpCapabilities
        case loginRoom
        
        case createWebRtcTransport(producing: Bool)
        case connectWebRtcTransport
        
        case produceTransport
        case resumeProducer
        case pauseProducer
        case closeProducer
        
        case peerLeave
        
        var description: String {
            switch self {
            case .getRouterRtpCapabilities:
                return "getRouterRtpCapabilities"
            case .loginRoom:
                return "join"
            case .createWebRtcTransport:
                return "createWebRtcTransport"
            case .connectWebRtcTransport:
                return "connectWebRtcTransport"
            case .produceTransport:
                return "produce"
            case .resumeProducer:
                return "resumeProducer"
            case .pauseProducer:
                return "pauseProducer"
            case .closeProducer:
                return "closeProducer"
            case .peerLeave:
                return "leave"
            }
        }

    }
    
    enum ReceiveRequest: String {
        case newConsumer = "newConsumer"
    }
    
    enum Notification: String {
        case consumerPaused = "consumerPaused"
        case consumerResumed = "consumerResumed"
        case consumerClosed = "consumerClosed"
        
        case newPeer = "newPeer"
        case peerClosed = "peerClosed"
        case peerDisplayNameChanged = "peerDisplayNameChanged"
        case peerLeave = "peerLeave"
    }
}

///mediasoup + send
extension CallingSignalManager {
    
    func requestToGetRoomRtpCapabilities() -> String? {
        guard let res = sendMediasoupAction(with: .getRouterRtpCapabilities, data: nil), res.ok, res.data != nil else {
            return nil
        }
        return res.data!.description
     }
     
     func createWebRtcTransportRequest(with producing: Bool) -> JSON? {
         let data:JSON = ["forceTcp" : false,
                          "producing" : producing,
                          "consuming" : !producing,
                          "sctpCapabilities" : ""]
        guard let res = sendMediasoupAction(with: .createWebRtcTransport(producing: producing), data: data), res.ok else {
            return nil
        }
        return res.data
     }
     
     func connectWebRtcTransportRequest(with transportId: String, dtlsParameters: String) {
         let data: JSON = ["transportId": transportId,
                           "dtlsParameters": JSON(parseJSON: dtlsParameters)]
        let res = sendMediasoupAction(with: .connectWebRtcTransport, data: data)
        zmLog.info("CallingSignalManager+Mediasoup -- connectWebRtcTransportRequest \(String(describing: res?.ok))")
     }
     
    func loginRoom(with rtpCapabilities: String, mediaState: CallMediaType) -> JSON? {
         let loginRoomRequestData: JSON = ["rtpCapabilities": JSON(parseJSON: rtpCapabilities),
                                           "audioStatus": mediaState.isMute ? 0 : 1,
                                           "videoStatus": mediaState.needSendVideo ? 1 : 0,
                                           "device": "ios"]
        guard let res = sendMediasoupAction(with: .loginRoom, data: loginRoomRequestData), res.ok, res.data != nil else {
            return nil
        }
        return res.data
     }
     
     func produceWebRtcTransportRequest(with transportId: String, kind: String, rtpParameters: String, appData: String) -> String? {
         let data: JSON = [
             "transportId": transportId,
             "kind": kind,
             "rtpParameters": JSON.init(parseJSON: rtpParameters),
             "appData": appData
         ]
        guard let res = sendMediasoupAction(with: .produceTransport, data: data), res.ok, res.data != nil else {
            return nil
        }
        return res.data!["id"].string
     }

    func setProduceState(with id: String, type: MediasoupProduceKind, pause: Bool) {
         let data: JSON = [
            "producerId": id,
            "producerType": type.rawValue
         ]
        let res = sendMediasoupAction(with: pause ? .pauseProducer : .resumeProducer, data: data)
        zmLog.info("CallingSignalManager+Mediasoup -- setProduceState \(String(describing: res?.ok))")
     }
     
     func closeProduce(with id: String, type: String) {
         let data: JSON = [
            "producerId": id,
            "producerType": type
         ]
        let res = sendMediasoupAction(with: .closeProducer, data: data)
        zmLog.info("CallingSignalManager+Mediasoup -- closeProduce \(String(describing: res?.ok))")
    }
     
     func peerLeave() {
        let res = sendMediasoupAction(with: .peerLeave, data: nil)
        zmLog.info("CallingSignalManager+Mediasoup -- peerLeave \(String(describing: res?.ok))")
     }
    
}

///mediasoup + receive
extension CallingSignalManager {

    private func sendMediasoupAction(with action: MediasoupSignalAction.SendRequest, data: JSON?) -> CallingSignalResponse? {
        return self.sendSocketRequest(with: action.description, data: data)
    }
    
}
