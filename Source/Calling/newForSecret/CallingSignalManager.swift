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


protocol CallingSocketStateDelegate {
    func socketConnected()
    ///needDestory - true: socket会自动重连8次，如果8次都失败，则为true，而前几次则为false
    func socketDisconnected(needDestory: Bool)
}

protocol CallingSignalManagerDelegate {
    func onReceiveRequest(with method: String, info: JSON)
    func onNewNotification(with noti: String, info: JSON)
}

extension CallingSignalManager: SocketActionDelegate {
    
    func receive(action: SocketAction) {
        switch action {
        case .connected:
            zmLog.info("CallingSignalManager-SocketConnected--inThread:\(Thread.current)\n")
            self.socketStateDelegate.socketConnected()
        case .disconnected(let needDestory):
            zmLog.info("CallingSignalManager-SocketDisConnected--inThread:\(Thread.current)\n")
            self.leaveGroup()
            signalWorkQueue.async {
                self.socketStateDelegate.socketDisconnected(needDestory: needDestory)
            }
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
            zmLog.info("CallingSignalManager-receiveSocketData--\(json)")
            self.receiveSocketResponse(with: CallingSignalResponse(json: json))
        } else if json["notification"].boolValue {
            self.receiveSocketNotification(with: CallingSignalNotification(json: json))
        }
    }
}

extension CallingSignalManager {
    
    func receiveSocketRequest(with request: CallingSignalRequest) {
        ///先发response回给服务器
        let response = CallingSignalResponse(response: true, ok: true,  id: request.id, data: nil)
        self.send(string: response.jsonString())
        signalWorkQueue.async {
            self.signalDelegate?.onReceiveRequest(with: request.method, info: request.data)
        }
    }
    
    func receiveSocketResponse(with response: CallingSignalResponse) {
        if let action = self.syncRequestMap.first(where: { return $0.value == response.id }),
            let data = response.data {
            zmLog.info("CallingSignalManager-receiveSocketResponse:\(action)--\(data)")
            self.syncResponse = data
            self.leaveGroup()
        }
    }
    
    func receiveSocketNotification(with notification: CallingSignalNotification) {
        signalWorkQueue.async {
            self.signalDelegate?.onNewNotification(with: notification.method, info: notification.data)
        }
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
    
    private func leaveGroup() {
        if self.isWaitForResponse {
            self.isWaitForResponse = false
            self.sendAckRequestDispatch.leave()
        }
    }
}

class CallingSignalManager: NSObject {

    ///用来异步返回socket响应
    private var syncRequestMap: [String : Int] = [:]
    fileprivate var sendAckRequestDispatch: DispatchGroup = DispatchGroup()
    fileprivate var isWaitForResponse: Bool = false
    fileprivate var syncResponse: JSON!
    
    private var socket: CallingSignalSocket?
    
    ///socket的状态回调
    private let socketStateDelegate: CallingSocketStateDelegate
    ///socket接收数据回调
    private var signalDelegate: CallingSignalManagerDelegate?

    init(socketStateDelegate:  CallingSocketStateDelegate) {
        self.socketStateDelegate = socketStateDelegate
    }
    
    func setSignalDelegate(_ signalDelegate: CallingSignalManagerDelegate) {
        self.signalDelegate = signalDelegate
    }
    
    func disConnectRoom() {
        self.socket?.disConnect()
    }
    
    func connectRoom(with url: String, roomId: String, userId: String) {
        let urlString = url + "/?roomId=\(roomId)&peerId=\(userId)"
        guard let roomUrl = URL.init(string: urlString) else {
            return
        }
        self.socket = CallingSignalSocket(url: roomUrl, delegate: self)
        self.socket!.connect()
    }
    
    func send(string: String) {
        self.socket?.send(string: string)
    }
    
    func readyToLeaveRoom() {
        self.leaveGroup()
    }
    
    func leaveRoom() {
        self.socket?.disConnect()
        self.syncRequestMap.removeAll()
        self.socket = nil
    }
}

///socket 发送同步异步请求
extension CallingSignalManager{
    
    func sendSocketRequest(with method: String, data: JSON?) {
        signalWorkQueue.async {
            zmLog.info("CallingSignalManager-sendSocketRequest==method:\(method)--thread:\(Thread.current)\n")
            let request = CallingSignalRequest.init(method: method, data: data)
            self.send(string: request.jsonString())
        }
    }
    
    func sendAckSocketRequest(with method: String, data: JSON?) -> JSON? {
        let request = CallingSignalRequest(method: method, data: data)
        zmLog.info("CallingSignalManager-sendAckSocketRequest==method:\(method)-id:\(request.id)-data:\(request.data)-thread:\(Thread.current)\n")
        syncRequestMap[method] = request.id
        self.enterGroup()
        self.syncResponse = nil
        
        self.socket?.send(string: request.jsonString())
        
        let result = sendAckRequestDispatch.wait(timeout: .now() + 20)
        if result == .success {
            return self.syncResponse
        } else {
            zmLog.info("CallingSignalManager-wait ack response time out")
            return nil
        }
    }
    
}
