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

    ///needDestory - true: socket会自动重连8次，如果8次都失败，则为true，而前几次则为false
    func socketDisconnected(needDestory: Bool)
    
    func onReceiveRequest(with action: MediasoupSignalAction.ReceiveRequest, info: JSON)
    
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
        
        case peerLeave
        
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
            case .peerLeave:
                return "leave"
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
        case peerLeave = "leave"
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
            zmLog.info("Mediasoup::SignalManager--SocketConnected--inThread:\(Thread.current)\n")
            signalWorkQueue.async {
                self.delegate.socketConnected()
            }
        case .disconnected(let needDestory):
            zmLog.info("Mediasoup::SignalManager--SocketDisConnected--inThread:\(Thread.current)\n")
            self.leaveGroup()
            signalWorkQueue.async {
                self.delegate.socketDisconnected(needDestory: needDestory)
            }
        case .text(text: let str):
            self.receiveSocketData(with: JSON(parseJSON: str))
        case .data(data: let data):
            self.receiveSocketData(with: try! JSON(data: data))
        }
    }
    
    func receiveSocketData(with json: JSON) {
        if json["request"].boolValue {
            self.receiveSocketRequest(with: MediasoupSignalRequest(json: json))
        } else if json["response"].boolValue {
            zmLog.info("Mediasoup::SignalManager--receiveSocketData--\(json)")
            self.receiveSocketResponse(with: MediasoupSignalResponse(json: json))
        } else if json["notification"].boolValue {
            self.receiveSocketNotification(with: MediasoupSignalNotification(json: json))
        }
    }
    
    func receiveSocketRequest(with request: MediasoupSignalRequest) {
        guard let action = MediasoupSignalAction.ReceiveRequest(rawValue: request.method) else {
            return
        }
        let response = MediasoupSignalResponse(response: true, ok: true,  id: request.id, data: nil)
        self.socket?.send(string: response.jsonString())
        signalWorkQueue.async {
            self.delegate.onReceiveRequest(with: action, info: request.data)
        }
    }
    
    func receiveSocketResponse(with response: MediasoupSignalResponse) {
        if let action = self.syncRequestMap.first(where: { return $0.value == response.id }),
            let data = response.data {
            zmLog.info("Mediasoup::signalManager--receiveSocketResponse:\(action)--\(data)")
            self.syncResponse = data
            self.leaveGroup()
        }
    }
    
    func receiveSocketNotification(with notification: MediasoupSignalNotification) {
        guard let action = MediasoupSignalAction.Notification(rawValue: notification.method) else {
            return
        }
        signalWorkQueue.async {
            self.delegate.onNewNotification(with: action, info: notification.data)
        }
    }
}

//DispatchGroup + Action
extension MediasoupSignalManager {
    
    func enterGroup() {
        if !self.isWaitForResponse {
            isWaitForResponse = true
            sendAckRequestDispatch.enter()
        }
    }
    
    func leaveGroup() {
        if self.isWaitForResponse {
            self.isWaitForResponse = false
            self.sendAckRequestDispatch.leave()
        }
    }
}

class MediasoupSignalManager: NSObject {

    ///用来异步返回socket响应
    private var syncRequestMap: [MediasoupSignalAction.SendRequest : Int] = [:]
    fileprivate var sendAckRequestDispatch: DispatchGroup = DispatchGroup()
    fileprivate var isWaitForResponse: Bool = false
    fileprivate var syncResponse: JSON!
    
    private var socket: MediasoupSignalSocket?
    private let url: String
    private let delegate: MediasoupSignalManagerDelegate

    init(url: String, delegate: MediasoupSignalManagerDelegate) {
        self.url = url
        self.delegate = delegate
    }
    
    func disConnectRoom() {
        self.socket?.disConnect()
    }
    
    func connectRoom(with roomId: String, userId: String) {
        let urlString = self.url + "/?roomId=\(roomId)&peerId=\(userId)"
        guard let roomUrl = URL.init(string: urlString) else {
            return
        }
        self.socket = MediasoupSignalSocket(url: roomUrl, delegate: self)
        self.socket!.connect()
    }
    
    func requestToGetRoomRtpCapabilities() -> String? {
        guard let info = sendAckSocketRequest(with: .getRouterRtpCapabilities, data: nil)  else {
            return nil
        }
        return info.description
    }
    
    func createWebRtcTransportRequest(with producing: Bool) -> JSON? {
        let data:JSON = ["forceTcp" : false,
                         "producing" : producing,
                         "consuming" : !producing,
                         "sctpCapabilities" : ""]
        
        guard let json = sendAckSocketRequest(with: .createWebRtcTransport(producing: producing), data: data) else {
            return nil
        }
        return json
    }
    
    func connectWebRtcTransportRequest(with transportId: String, dtlsParameters: String) {
        let data: JSON = ["transportId": transportId,
                          "dtlsParameters": JSON(parseJSON: dtlsParameters)]
        
        sendSocketRequest(with: .connectWebRtcTransport, data: data)
    }
    
    func loginRoom(with rtpCapabilities: String) -> JSON? {
        let loginRoomRequestData: JSON = ["displayName" : "lc",
                                          "rtpCapabilities" : JSON(parseJSON: rtpCapabilities),
                                          "device" : "",
                                          "sctpCapabilities" : ""]
        guard let json = sendAckSocketRequest(with: .loginRoom, data: loginRoomRequestData) else {
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
        guard let json = sendAckSocketRequest(with: .produceTransport, data: data) else {
            return nil
        }
        return json["id"].stringValue
    }

    func setProduceState(with id: String, pause: Bool) {
        let data: JSON = [
            "producerId": id,
        ]
        sendSocketRequest(with: pause ? .pauseProducer : .resumeProducer, data: data)
    }
    
    func closeProduce(with id: String) {
        let data: JSON = [
            "producerId": id,
        ]
        sendSocketRequest(with: .closeProducer, data: data)
    }
    
    func peerLeave() {
        sendSocketRequest(with: .peerLeave, data: nil)
    }
    
    func leaveRoom() {
        self.leaveGroup()
        self.socket?.disConnect()
        self.syncRequestMap.removeAll()
        self.socket = nil
    }
}

///socket 发送同步异步请求
extension MediasoupSignalManager{
    
    func sendSocketRequest(with action: MediasoupSignalAction.SendRequest, data: JSON?) {
        signalWorkQueue.async {
            guard !action.needProcessResponse else {
                fatal("Mediasoup::SignalManager-sendSocketRequest-error action type")
            }
            zmLog.info("Mediasoup::SignalManager--sendSocketRequest==action:\(action)--thread:\(Thread.current)\n")
            let request = MediasoupSignalRequest.init(method: action, data: data)
            
            self.socket?.send(string: request.jsonString())
        }
    }
    
    func sendAckSocketRequest(with action: MediasoupSignalAction.SendRequest, data: JSON?) -> JSON? {
        guard action.needProcessResponse else {
            fatal("Mediasoup::SignalManager-sendAckSocketRequest-error action type")
        }
        let request = MediasoupSignalRequest.init(method: action, data: data)
        zmLog.info("Mediasoup::SignalManager--sendAckSocketRequest==action:\(action)-id:\(request.id)-data:\(request.data)-thread:\(Thread.current)\n")
        syncRequestMap[action] = request.id
        self.enterGroup()
        self.syncResponse = nil
        
        self.socket?.send(string: request.jsonString())
        
        let result = sendAckRequestDispatch.wait(timeout: .now() + 10)
        if result == .success {
            return self.syncResponse
        } else {
            zmLog.info("Mediasoup::SignalManager--wait ack response time out")
            return nil
        }
    }
    
}
