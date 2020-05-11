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

protocol MediasoupSignalManagerDelegate {
    
    func socketConnected()

    func socketError(with err: String)
    
    func onReceiveRequest(with action: MediasoupSignalAction.ReceiveRequest, info: JSON)
    
    func onNewNotification(with action: MediasoupSignalAction.Notification, info: JSON)
}

enum MediasoupSignalAction {
    
    enum SendRequest: String {
        case getRouterRtpCapabilities = "getRouterRtpCapabilities"
        case loginRoom = "join"
        
        case createWebRtcTransport = "createWebRtcTransport"
        case connectWebRtcTransport = "connectWebRtcTransport"
        
        case produceTransport = "produce"
        case resumeProducer = "resumeProducer"
        case pauseProducer = "pauseProducer"
        case closeProducer = "closeProducer"
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
    }
}



struct MediasoupSignalRequest {
    let request: Bool
    let method: String
    let id: Int
    let data: JSON
    
    init(method: MediasoupSignalAction.SendRequest, data: JSON?) {
        self.request = true
        self.method = method.rawValue
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
    let ok: Bool
    let response: Bool
    let id: Int
    let data: JSON?
    
    init(ok: Bool, response: Bool, id: Int, data: JSON?) {
        self.ok = ok
        self.response = response
        self.id = id
        self.data = data
    }
    
    init(json: JSON) {
        self.ok = json["ok"].boolValue
        self.response = json["response"].boolValue
        self.data = json["data"]
        self.id = json["id"].intValue
    }
    
    func jsonString() -> String {
        let json: JSON = ["response": response,
                          "ok": ok,
                          "id": id,
                          "data": ["qwe": "dsad"]
        ]
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
        case .connectFail:
            self.delegate.socketError(with: "connectFail")
        case .close:
            self.delegate.socketError(with: "connectClose")
        case .text(text: let str):
            self.receiveSocketData(with: JSON(parseJSON: str))
        case .data(data: let data):
            self.receiveSocketData(with: try! JSON(data: data))
        }
    }
    
    func receiveSocketData(with json: JSON) {
        //print("receiveSocket---Data:\(json.description)")
        if json["request"].boolValue {
            self.receiveSocketRequest(with: MediasoupSignalRequest(json: json))
        } else if json["response"].boolValue {
            self.receiveSocketResponse(with: MediasoupSignalResponse(json: json))
        } else if json["notification"].boolValue {
            self.receiveSocketNotification(with: MediasoupSignalNotification(json: json))
        }
    }
    
    func receiveSocketRequest(with request: MediasoupSignalRequest) {
        //print("receiveSocket---request:\(request.method)--data:\(request.data)")
        guard let action = MediasoupSignalAction.ReceiveRequest(rawValue: request.method) else {
            //print("receiveSocket-unknowm-request:\(request.method)-data:\(request.data)")
            return
        }
        let response = MediasoupSignalResponse(ok: true, response: true, id: request.id, data: nil)
        self.socket?.send(string: response.jsonString())
        self.delegate.onReceiveRequest(with: action, info: request.data)
    }
    
    func receiveSocketResponse(with response: MediasoupSignalResponse) {
        print("receiveSocket---Response:\(response.data!.description)")
        if let semaphor = self.ackSemaphor.first(where: { return $0.0 == response.id })?.1 {
            self.ackResponse.append(response)
            semaphor.signal()
        }
    }
    
    func receiveSocketNotification(with notification: MediasoupSignalNotification) {
        
        guard let action = MediasoupSignalAction.Notification(rawValue: notification.method) else {
            //print("receiveSocket-unknowm-notification:\(notification.method)-data:\(notification.data)")
            return
        }
        print("receiveSocket-notification:\(notification.method)-data:\(notification.data)")
        self.delegate.onNewNotification(with: action, info: notification.data)
    }
}

class MediasoupSignalManager: NSObject {

    ///用来同步返回socket响应
    private var ackSemaphor: [(Int, DispatchSemaphore)] = []
    private var ackResponse: [MediasoupSignalResponse] = []
    
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
    
    func getRoomRtpCapabilities() -> String {
        let response = sendAckSocketRequest(with: .getRouterRtpCapabilities, data: nil)
        return response.data!.description
    }
    
    func loginRoom(with rtpCapabilities: String) -> JSON? {
        let loginRoomRequestData: JSON = ["displayName" : "lc",
                                          "rtpCapabilities" : JSON(parseJSON: rtpCapabilities),
                                          "device" : "",
                                          "sctpCapabilities" : ""]
        let response = sendAckSocketRequest(with: .loginRoom, data: loginRoomRequestData)
        return response.data
    }
    
    func leaveRoom() {
        self.socket?.disConnect()
        self.socket = nil
    }

    func createWebRtcTransportRequest(with producing: Bool) -> JSON {
        let data:JSON = ["forceTcp" : false,
                         "producing" : producing,
                         "consuming" : !producing,
                         "sctpCapabilities" : ""]
        
        let response = sendAckSocketRequest(with: .createWebRtcTransport, data: data)
        return response.data!
    }
    
    func connectWebRtcTransportRequest(with transportId: String, dtlsParameters: String) {
        let data: JSON = ["transportId": transportId,
                          "dtlsParameters": JSON(parseJSON: dtlsParameters)]
        
        sendSocketRequest(with: .connectWebRtcTransport, data: data)
    }
    
    func produceWebRtcTransportRequest(with transportId: String, kind: String, rtpParameters: String, appData: String) -> String {
        let data: JSON = [
            "transportId": transportId,
            "kind": kind,
            "rtpParameters": JSON.init(parseJSON: rtpParameters),
            "appData": appData
        ]
        let response = sendAckSocketRequest(with: .produceTransport, data: data)
        
        return response.data!["id"].stringValue
    }

    func setProduceState(with id: String, pause: Bool) {
        print("setProduceState--produceId == " + id)
        let data: JSON = [
            "producerId": id,
        ]
        sendSocketRequest(with: pause ? .pauseProducer : .resumeProducer, data: data)
    }
    
    func closeProduce(with id: String) {
        print("closeProduce--produceId == " + id)
        let data: JSON = [
            "producerId": id,
        ]
        sendSocketRequest(with: .closeProducer, data: data)
    }
    
}

///socket 发送同步异步请求
extension MediasoupSignalManager{
    
    func sendSocketRequest(with action: MediasoupSignalAction.SendRequest, data: JSON?) {
        print("Mediasoup::ActionManager::sendSocketRequest==action:\(action)--thread:\(Thread.current)\n")
        let request = MediasoupSignalRequest.init(method: action, data: data)
        self.socket?.send(string: request.jsonString())
    }
    
    ///需要同步的返回响应
    func sendAckSocketRequest(with action: MediasoupSignalAction.SendRequest, data: JSON?) -> MediasoupSignalResponse {
        print("Mediasoup::ActionManager::sendAckSocketRequest==action:\(action)--thread:\(Thread.current)\n")
        
        let request = MediasoupSignalRequest(method: action, data: data)
        
        let semaphor = DispatchSemaphore(value: 0)
        self.ackSemaphor.append((request.id, semaphor))

        self.socket?.send(string: request.jsonString())
        
        let _ = semaphor.wait(timeout: .now() + 5.0)
        
        if let response = self.ackResponse.first(where: { return $0.id == request.id }) {
            self.ackSemaphor = self.ackSemaphor.filter({ return $0.0 != request.id })
            self.ackResponse = self.ackResponse.filter({ return $0.id != request.id })
            return response
        } else {
            fatal("无响应")
        }
    }
    
}
