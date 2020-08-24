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
        
//        var needProcessResponse: Bool {
//            switch self {
//            case .getRouterRtpCapabilities, .loginRoom, .createWebRtcTransport, .produceTransport:
//                return true
//            default:
//                return false
//            }
//        }
        
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
        case peerLeave = "leave"
    }
}

///mediasoup + send
extension CallingSignalManager {
    
    func requestToGetRoomRtpCapabilities() -> String? {
         guard let info = sendAckMediasoupAction(with: .getRouterRtpCapabilities, data: nil)  else {
             return nil
         }
         return info.description
     }
     
     func createWebRtcTransportRequest(with producing: Bool) -> JSON? {
         let data:JSON = ["forceTcp" : false,
                          "producing" : producing,
                          "consuming" : !producing,
                          "sctpCapabilities" : ""]
         
         guard let json = sendAckMediasoupAction(with: .createWebRtcTransport(producing: producing), data: data) else {
             return nil
         }
         return json
     }
     
     func connectWebRtcTransportRequest(with transportId: String, dtlsParameters: String) {
         let data: JSON = ["transportId": transportId,
                           "dtlsParameters": JSON(parseJSON: dtlsParameters)]
         sendMediasoupAction(with: .connectWebRtcTransport, data: data)
     }
     
     func loginRoom(with rtpCapabilities: String) -> JSON? {
         let loginRoomRequestData: JSON = ["displayName" : "",
                                           "rtpCapabilities" : JSON(parseJSON: rtpCapabilities),
                                           "device" : "ios",
                                           "sctpCapabilities" : ""]
         guard let json = sendAckMediasoupAction(with: .loginRoom, data: loginRoomRequestData) else {
             return nil
         }
         return json
     }
     
     func produceWebRtcTransportRequest(with transportId: String, kind: String, rtpParameters: String, appData: String) -> String? {
         let data: JSON = [
             "transportId": transportId,
             "kind": kind,
             "rtpParameters": JSON.init(parseJSON: rtpParameters),
             "appData": appData
         ]
         guard let json = sendAckMediasoupAction(with: .produceTransport, data: data) else {
             return nil
         }
         return json["id"].stringValue
     }

     func setProduceState(with id: String, pause: Bool) {
         let data: JSON = [
             "producerId": id,
         ]
         sendMediasoupAction(with: pause ? .pauseProducer : .resumeProducer, data: data)
     }
     
     func closeProduce(with id: String) {
         let data: JSON = [
             "producerId": id,
         ]
         sendMediasoupAction(with: .closeProducer, data: data)
     }
     
     func peerLeave() {
         sendMediasoupAction(with: .peerLeave, data: nil)
     }
    
}

///mediasoup + receive
extension CallingSignalManager {

    private func sendMediasoupAction(with action: MediasoupSignalAction.SendRequest, data: JSON?) {
        self.sendSocketRequest(with: action.description, data: data)
    }
    
    private func sendAckMediasoupAction(with action: MediasoupSignalAction.SendRequest, data: JSON?) -> JSON? {
        return self.sendAckSocketRequest(with: action.description, data: data)
    }
    
}
