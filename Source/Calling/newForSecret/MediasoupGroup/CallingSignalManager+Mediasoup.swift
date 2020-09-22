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

//Mediasoup连接信令(通用)
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
    
    func requestToGetRoomRtpCapabilities(completion: @escaping (String?) -> Void) {
        sendMediasoupAction(with: .getRouterRtpCapabilities, data: nil) { (res) in
            if res.ok && res.data != nil {
                completion(res.data!.description)
            } else {
                completion(nil)
            }
        }
     }
     
     func createWebRtcTransportRequest(with producing: Bool, completion: @escaping (JSON?) -> Void) {
         let data:JSON = ["forceTcp" : false,
                          "producing" : producing,
                          "consuming" : !producing,
                          "sctpCapabilities" : ""]
        sendMediasoupAction(with: .createWebRtcTransport(producing: producing), data: data) { (res) in
            if res.ok {
                completion(res.data)
            } else {
                completion(nil)
            }
        }
     }
     
     func connectWebRtcTransportRequest(with transportId: String, dtlsParameters: String) {
         let data: JSON = ["transportId": transportId,
                           "dtlsParameters": JSON(parseJSON: dtlsParameters)]
        sendMediasoupAction(with: .connectWebRtcTransport, data: data) { res in
            zmLog.info("CallingSignalManager+Mediasoup -- connectWebRtcTransportRequest \(res.ok)")
        }
     }
     
     func loginRoom(with rtpCapabilities: String, completion: @escaping (JSON?) -> Void) {
         let loginRoomRequestData: JSON = ["displayName" : "",
                                           "rtpCapabilities" : JSON(parseJSON: rtpCapabilities),
                                           "device" : "ios",
                                           "sctpCapabilities" : ""]
        sendMediasoupAction(with: .loginRoom, data: loginRoomRequestData) { (res) in
            if res.ok && res.data != nil {
                completion(res.data)
            } else {
                completion(nil)
            }
        }
     }
     
     func produceWebRtcTransportRequest(with transportId: String, kind: String, rtpParameters: String, appData: String, completion: @escaping (String?) -> Void) {
         let data: JSON = [
             "transportId": transportId,
             "kind": kind,
             "rtpParameters": JSON.init(parseJSON: rtpParameters),
             "appData": appData
         ]
        sendMediasoupAction(with: .produceTransport, data: data) { (res) in
            if res.ok && res.data != nil {
                completion(res.data!["id"].string)
            } else {
                completion(nil)
            }
        }
     }

     func setProduceState(with id: String, pause: Bool) {
         let data: JSON = [
             "producerId": id,
         ]
        sendMediasoupAction(with: pause ? .pauseProducer : .resumeProducer, data: data) { _ in
            
        }
     }
     
     func closeProduce(with id: String) {
         let data: JSON = [
             "producerId": id,
         ]
        sendMediasoupAction(with: .closeProducer, data: data) { _ in
            
        }
    }
     
     func peerLeave() {
        sendMediasoupAction(with: .peerLeave, data: nil) { _ in
            
        }
     }
    
}

///mediasoup + receive
extension CallingSignalManager {

    private func sendMediasoupAction(with action: MediasoupSignalAction.SendRequest, data: JSON?, completion: @escaping CallingSignalResponseBlock) {
        self.sendSocketRequest(with: action.description, data: data, completion: completion)
    }
    
}
