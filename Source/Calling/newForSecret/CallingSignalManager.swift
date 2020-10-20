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


protocol CallingSignalManagerDelegate {
    func socketConnected()
    ///needDestory - true: socket会自动重连8次，如果8次都失败，则为true，而前几次则为false
    func socketDisconnected(needDestory: Bool)
    
    func onReceiveRequest(with method: String, info: JSON)
    func onNewNotification(with noti: String, info: JSON)
}

extension CallingSignalManager: SocketActionDelegate {
    
    func receive(action: SocketAction) {
        switch action {
        case .connected:
            zmLog.info("CallingSignalManager-SocketConnected--inThread:\(Thread.current)\n")
            self.isSocketConnected = true
            self.signalManagerDelegate.socketConnected()
        case .disconnected(let needDestory):
            zmLog.info("CallingSignalManager-SocketDisConnected--inThread:\(Thread.current)\n")
            self.isSocketConnected = false
            self.signalManagerDelegate.socketDisconnected(needDestory: needDestory)
        case .text(text: let str):
            self.receiveSocketData(with: JSON(parseJSON: str))
        case .data(data: let data):
            self.receiveSocketData(with: try! JSON(data: data))
        }
    }
    
    func receiveSocketData(with json: JSON) {
        if json["request"].boolValue {
            self.receiveSocketRequest(with: CallingSignalRequest(json: json))
        } else if json["response"].boolValue {
            self.receiveSocketResponse(with: CallingSignalResponse(json: json))
        } else if json["notification"].boolValue {
            self.receiveSocketNotification(with: CallingSignalNotification(json: json))
        }
    }
}

extension CallingSignalManager {
    
    func receiveSocketRequest(with request: CallingSignalRequest) {
        ///先发response回给服务器
        let response = CallingSignalResponse(response: true, ok: true,  id: request.id, data: nil, method: request.method, roomId: request.roomId, peerId: request.peerId)
        self.send(string: response.jsonString())
        self.signalManagerDelegate.onReceiveRequest(with: request.method, info: request.data)
    }
    
    func receiveSocketResponse(with response: CallingSignalResponse) {
        zmLog.info("CallingSignalManager-receiveSocketResponse==responseId:\(response.id)--thread:\(Thread.current)")
        if currentRequestId == response.id {
            self.syncResponse = response
            self.leaveGroup()
        }
    }
    
    func receiveSocketNotification(with notification: CallingSignalNotification) {
        self.signalManagerDelegate.onNewNotification(with: notification.method, info: notification.data)
    }
    
}

//DispatchGroup + Action
extension CallingSignalManager {
    
    private func enterGroup() {
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

class CallingSignalManager: NSObject {
    
    //用来阻塞线程，从而将异步的发送请求可以同步返回响应
    private var sendAckRequestDispatch: DispatchGroup = DispatchGroup()
    fileprivate var isWaitForResponse: Bool = false
    
    fileprivate var currentRequestId: UInt32?
    fileprivate var syncResponse: CallingSignalResponse?
    
    private var socket: CallingSignalSocket?
    private var isSocketConnected: Bool = false
    
    ///socket接收数据回调
    private var signalManagerDelegate: CallingSignalManagerDelegate

    init(signalManagerDelegate:  CallingSignalManagerDelegate) {
        self.signalManagerDelegate = signalManagerDelegate
    }
    
    func disConnectRoom() {
        self.socket?.disConnect()
    }
    
    func connectRoom(with url: String, roomId: String, userId: String, token: String?) {
        var urlString = url + "/?roomId=\(roomId)&peerId=\(userId)"
        if let token = token {
            urlString = urlString + "&\(token)"
        }
        guard let roomUrl = URL.init(string: urlString) else {
            return
        }
        self.socket = CallingSignalSocket(url: roomUrl, delegate: self)
        self.socket!.connect()
    }
    
    func send(string: String) {
        self.socket?.send(string: string)
    }
    
    func leaveRoom() {
        self.socket?.disConnect()
        self.socket = nil
    }
}

///socket 发送同步异步请求
extension CallingSignalManager{
    
    //转发信令给房间里面的某人,不需要回复
    func forwardSocketMessage(to peerId: String, method: String, data: JSON?) {
        guard self.isSocketConnected else { return }
        zmLog.info("CallingSignalManager-forwardSocketMessage==method:\(method)-data:\(String(describing: data))")
        let request = CallingSignalForwardMessage.init(toId: peerId, method: method, data: data)
        self.send(string: request.jsonString())
    }
    
    func sendSocketRequest(with method: String, data: JSON?) -> CallingSignalResponse? {
        guard self.isSocketConnected else { return nil }
        let request = CallingSignalRequest.init(method: method, data: data)
        zmLog.info("CallingSignalManager-sendSocketRequest==method:\(method)-requestId:\(request.id)")

        self.enterGroup()
        self.currentRequestId = request.id
        self.syncResponse = nil
        
        self.send(string: request.jsonString())
        
        let result = sendAckRequestDispatch.wait(timeout: .now() + 10)
        if result == .success {
            return self.syncResponse
        } else {
            zmLog.info("CallingSignalManager-wait ack response time out")
            return nil
        }
    }
    
}
