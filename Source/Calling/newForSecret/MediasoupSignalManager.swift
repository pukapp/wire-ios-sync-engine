//
//  MediasoupSignalManager.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/4/10.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON
import AVFoundation
///mediasoup的信令管理

private let zmLog = ZMSLog(tag: "calling")

protocol MediasoupSignalManagerDelegate {
    
    func socketConnected()

    func socketDisconnected()
    
    func onReceiveRequest(with action: MediasoupSignalAction.ReceiveRequest, info: JSON)
    
    func onReceiveResponse(with action: MediasoupSignalAction.SendRequest, info: JSON)
    
    func onNewNotification(with action: MediasoupSignalAction.Notification, info: JSON)
}

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
        
        var needProcessResponse: Bool {
            switch self {
            case .getRouterRtpCapabilities, .loginRoom, .createWebRtcTransport, .produceTransport:
                return true
            default:
                return false
            }
        }
        
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
            }
        }

    }
    ///发送请求之后 接收到的响应
    enum ReceiveResponse: String {
        case newConsumer = "newConsumer"
    }
    
    ///需要返回响应给服务器
    enum ReceiveRequest: String {
        case newConsumer = "newConsumer"
    }
    
    ///接收后无需任何操作
    enum Notification: String {
        case consumerPaused = "consumerPaused"
        case consumerResumed = "consumerResumed"
        case consumerClosed = "consumerClosed"
        
        case newPeer = "newPeer"
        case peerClosed = "peerClosed"
        case peerDisplayNameChanged = "peerDisplayNameChanged"
    }
}



struct MediasoupSignalRequest {
    let request: Bool
    let method: String
    let id: Int
    let data: JSON
    
    init(method: MediasoupSignalAction.SendRequest, data: JSON?) {
        self.request = true
        self.method = method.description
        self.data = data ?? ""
        self.id = Int(arc4random())
    }
    
    init(json: JSON) {
        self.request = json["request"].boolValue
        self.method = json["method"].stringValue
        self.data = json["data"]
        self.id = json["id"].intValue
    }
    
    func jsonString() -> String {
        let json: JSON = ["request": request,
                          "method": method,
                          "id": id,
                          "data": data
        ]
        return json.description
    }
    
}

struct MediasoupSignalResponse {
    let response: Bool
    let ok: Bool
    let id: Int
    let data: JSON?
    
    init(response: Bool, ok: Bool, id: Int, data: JSON?) {
        self.response = response
        self.ok = ok
        self.id = id
        self.data = data
    }
    
    init(json: JSON) {
        self.response = json["response"].boolValue
        self.ok = json["ok"].boolValue
        self.data = json["data"]
        self.id = json["id"].intValue
    }
    
    func jsonString() -> String {
        let json: JSON = ["response": response,
                          "ok": ok,
                          "id": id,
                          "data": ""]
        return json.description
    }
}

struct MediasoupSignalNotification {
    
    let notification: Bool
    let method: String
    let data: JSON
    
    init(json: JSON) {
        self.notification = json["notification"].boolValue
        self.method = json["method"].stringValue
        self.data = json["data"]
    }
    
    func jsonString() -> String {
        let json: JSON = ["notification": notification,
                          "method": method,
                          "data": data
        ]
        return json.description
    }
    
}


extension MediasoupSignalManager: SocketActionDelegate {
    
    func receive(action: SocketAction) {
        switch action {
        case .connected:
            self.delegate.socketConnected()
        case .disconnected:
            self.delegate.socketDisconnected()
        case .text(text: let str):
            self.receiveSocketData(with: JSON(parseJSON: str))
        case .data(data: let data):
            self.receiveSocketData(with: try! JSON(data: data))
        }
    }
    
    func receiveSocketData(with json: JSON) {
        //zmLog.info("receiveSocket---Data:\(json.description)")
        if json["request"].boolValue {
            self.receiveSocketRequest(with: MediasoupSignalRequest(json: json))
        } else if json["response"].boolValue {
            self.receiveSocketResponse(with: MediasoupSignalResponse(json: json))
        } else if json["notification"].boolValue {
            self.receiveSocketNotification(with: MediasoupSignalNotification(json: json))
        }
    }
    
    func receiveSocketRequest(with request: MediasoupSignalRequest) {
        //zmLog.info("receiveSocket---request:\(request.method)--data:\(request.data)")
        guard let action = MediasoupSignalAction.ReceiveRequest(rawValue: request.method) else {
            //zmLog.info("receiveSocket-unknowm-request:\(request.method)-data:\(request.data)")
            return
        }
        let response = MediasoupSignalResponse(response: true, ok: true,  id: request.id, data: nil)
        self.socket?.send(string: response.jsonString())
        self.delegate.onReceiveRequest(with: action, info: request.data)
    }
    
    func receiveSocketResponse(with response: MediasoupSignalResponse) {
        zmLog.info("Mediasoup::receiveSocketResponse--thread:\(Thread.current)\n")
        //zmLog.info("Mediasoup::receiveSocket---Response:\(response.data!.description)--thread:\(Thread.current)\n")
        if self.isWaitingResponse {
            self.syncResponse = response
            dispatchGroup.leave()
            self.isWaitingResponse = false
        } else {
            if let request = self.syncRequestMap.first(where: { return $0.value == response.id }),
                let data = response.data {
                self.delegate.onReceiveResponse(with: request.key, info: data)
            }
        }
    }
    
    func receiveSocketNotification(with notification: MediasoupSignalNotification) {
        
        guard let action = MediasoupSignalAction.Notification(rawValue: notification.method) else {
            //zmLog.info("receiveSocket-unknowm-notification:\(notification.method)-data:\(notification.data)")
            return
        }
        zmLog.info("receiveSocket-notification:\(notification.method)-data:\(notification.data)")
        self.delegate.onNewNotification(with: action, info: notification.data)
    }
}

class MediasoupSignalManager: NSObject {

    ///用来同步返回socket响应
    private let dispatchGroup = DispatchGroup()
    private var isWaitingResponse: Bool = false
    private var syncResponse: MediasoupSignalResponse?
    
    ///用来异步返回socket响应
    private var syncRequestMap: [MediasoupSignalAction.SendRequest : Int] = [:]
    
    private var socket: MediasoupSignalSocket?
    private let url: String
    private let delegate: MediasoupSignalManagerDelegate

    init(url: String, delegate: MediasoupSignalManagerDelegate) {
        self.url = url
        self.delegate = delegate
    }
    
    func connectRoom(with roomId: String, userId: String) {
        let urlString = self.url + "/?roomId=\(roomId)&peerId=\(userId)"
        guard let roomUrl = URL.init(string: urlString) else {
            return
        }
        self.socket = MediasoupSignalSocket(url: roomUrl, delegate: self)
        self.socket!.connect()
    }
    
    func requestToGetRoomRtpCapabilities() {
        sendSocketRequest(with: .getRouterRtpCapabilities, data: nil)
    }
    
    func loginRoom(with rtpCapabilities: String) {
        let loginRoomRequestData: JSON = ["displayName" : "lc",
                                          "rtpCapabilities" : JSON(parseJSON: rtpCapabilities),
                                          "device" : "",
                                          "sctpCapabilities" : ""]
        sendSocketRequest(with: .loginRoom, data: loginRoomRequestData)
    }
    
    func leaveRoom() {
        self.socket?.disConnect()
        self.socket = nil
        if self.isWaitingResponse {
            self.dispatchGroup.leave()
        }
    }

    func createWebRtcTransportRequest(with producing: Bool) {
        let data:JSON = ["forceTcp" : false,
                         "producing" : producing,
                         "consuming" : !producing,
                         "sctpCapabilities" : ""]
        
        sendSocketRequest(with: .createWebRtcTransport(producing: producing), data: data)
    }
    
    func connectWebRtcTransportRequest(with transportId: String, dtlsParameters: String) {
        let data: JSON = ["transportId": transportId,
                          "dtlsParameters": JSON(parseJSON: dtlsParameters)]
        
        sendSocketRequest(with: .connectWebRtcTransport, data: data)
    }
    
    func produceWebRtcTransportRequest(with transportId: String, kind: String, rtpParameters: String, appData: String) -> String? {
        let data: JSON = [
            "transportId": transportId,
            "kind": kind,
            "rtpParameters": JSON.init(parseJSON: rtpParameters),
            "appData": appData
        ]
        guard let response = sendAckSocketRequest(with: .produceTransport, data: data) else {
            return nil
        }
        return response.data!["id"].stringValue
    }

    func setProduceState(with id: String, pause: Bool) {
        zmLog.info("setProduceState--produceId == " + id)
        let data: JSON = [
            "producerId": id,
        ]
        sendSocketRequest(with: pause ? .pauseProducer : .resumeProducer, data: data)
    }
    
    func closeProduce(with id: String) {
        zmLog.info("closeProduce--produceId == " + id)
        let data: JSON = [
            "producerId": id,
        ]
        sendSocketRequest(with: .closeProducer, data: data)
    }
    
}

///socket 发送同步异步请求
extension MediasoupSignalManager{
    
    func sendSocketRequest(with action: MediasoupSignalAction.SendRequest, data: JSON?) {
        zmLog.info("Mediasoup::ActionManager::sendSocketRequest==action:\(action)--thread:\(Thread.current)\n")
        let request = MediasoupSignalRequest.init(method: action, data: data)
        if action.needProcessResponse {
            syncRequestMap[action] = request.id
        }
        self.socket?.send(string: request.jsonString())
    }
    
    ///需要同步的返回响应
    func sendAckSocketRequest(with action: MediasoupSignalAction.SendRequest, data: JSON?) -> MediasoupSignalResponse? {
        zmLog.info("Mediasoup::ActionManager::sendAckSocketRequest==action:\(action)--thread:\(Thread.current)\n")
        
        let request = MediasoupSignalRequest(method: action, data: data)
        if !self.isWaitingResponse {
            dispatchGroup.enter()
            self.isWaitingResponse = true
        }
        self.socket?.send(string: request.jsonString())
        if dispatchGroup.wait(timeout: .now() + 5.0) == .success {
            if let response = self.syncResponse {
                return response
            } else {
                zmLog.info("Mediasoup::sendAckSocketRequest:recvNilResponse\n")
                return nil
            }
        } else {
            dispatchGroup.leave()
            self.isWaitingResponse = false
            zmLog.info("Mediasoup::sendAckSocketRequest:timeout\n")
            return nil
        }
    }
    
}
