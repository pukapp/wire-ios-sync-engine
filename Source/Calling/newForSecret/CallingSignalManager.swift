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
        roomWorkQueue.async {
            switch action {
            case .connected:
                zmLog.info("CallingSignalManager-SocketConnected--inThread:\(Thread.current)\n")
                self.isSocketConnected = true
                self.socketStateDelegate.socketConnected()
            case .disconnected(let needDestory):
                zmLog.info("CallingSignalManager-SocketDisConnected--inThread:\(Thread.current)\n")
                self.isSocketConnected = false
                self.socketStateDelegate.socketDisconnected(needDestory: needDestory)
            case .text(text: let str):
                self.receiveSocketData(with: JSON(parseJSON: str))
            case .data(data: let data):
                self.receiveSocketData(with: try! JSON(data: data))
            }
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
        self.signalDelegate?.onReceiveRequest(with: request.method, info: request.data)
    }
    
    func receiveSocketResponse(with response: CallingSignalResponse) {
        zmLog.info("CallingSignalManager-receiveSocketResponse==responseId:\(response.id)")
        if let block = self.responseBlockMap.first(where: { return $0.key == response.id })?.value {
            block(response)
            self.responseBlockMap.removeValue(forKey: response.id)
        } else {
            zmLog.info("CallingSignalManager-receiveSocketResponse==err:\(response.id)")
        }
    }
    
    func receiveSocketNotification(with notification: CallingSignalNotification) {
        self.signalDelegate?.onNewNotification(with: notification.method, info: notification.data)
    }
    
}

typealias CallingSignalResponseBlock = (CallingSignalResponse) -> Void

class CallingSignalManager: NSObject {

    //用来异步返回socket响应
    private var responseBlockMap: [UInt32 : CallingSignalResponseBlock] = [:]
    
    private var socket: CallingSignalSocket?
    private var isSocketConnected: Bool = false
    
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
    
    func leaveRoom() {
        self.socket?.disConnect()
        self.responseBlockMap.removeAll()
        self.socket = nil
    }
}

private let sendSocketSignalQueue: DispatchQueue = DispatchQueue.init(label: "MediasoupSendSocketSignalQueue")

///socket 发送同步异步请求
extension CallingSignalManager{
    
    //转发信令给房间里面的某人,不需要回复
    func forwardSocketMessage(to peerId: String, method: String, data: JSON?) {
        guard self.isSocketConnected else { return }
        zmLog.info("CallingSignalManager-forwardSocketMessage==method:\(method)-data:\(String(describing: data))")
        let request = CallingSignalForwardMessage.init(toId: peerId, method: method, data: data)
        self.send(string: request.jsonString())
    }
    
    func sendSocketRequest(with method: String, data: JSON?, completion: @escaping CallingSignalResponseBlock) {
        guard self.isSocketConnected else { return }
        let request = CallingSignalRequest.init(method: method, data: data)
        zmLog.info("CallingSignalManager-sendSocketRequest==method:\(method)-requestId:\(request.id)")
        self.responseBlockMap[request.id] = completion
        self.send(string: request.jsonString())
    }
    
}
