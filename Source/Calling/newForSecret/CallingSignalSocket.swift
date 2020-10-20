//
//  NetworkSocket+Ack.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/4/11.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import Starscream

private let zmLog = ZMSLog(tag: "calling")

enum SocketAction {
    case connected
    case disconnected(needDestory: Bool)
    case text(text: String)
    case data(data: Data)
}

protocol SocketActionDelegate {
    func receive(action: SocketAction)
}

private let recvSocketSignalQueue: DispatchQueue = DispatchQueue.init(label: "MediasoupRecvSocketSignalQueue")

public class CallingSignalSocket {

    private var socket: WebSocket?
    private var reConnectedTimes: Int = 0
    
    private let url: URL
    private let delegate: SocketActionDelegate

    init(url: URL, delegate: SocketActionDelegate) {
        zmLog.info("CallingSignalSocket-init--url:\(url)")
        self.url = url
        self.delegate = delegate
        self.createSocket()
    }
    
    func createSocket() {
        self.socket = WebSocket(url: url, protocols: ["secret-media"])//secret-media--protoo
        self.socket!.disableSSLCertValidation = true
        self.socket!.callbackQueue = recvSocketSignalQueue
        self.socket!.delegate = self
    }

    func connect() {
        zmLog.info("CallingSignalSocket-connect")
        self.socket?.connect()
    }
    
    func reConnect() {
        zmLog.info("CallingSignalSocket-reConnect")
        self.socket?.connect()
    }
    
    func disConnect() {
        zmLog.info("CallingSignalSocket-disConnect")
        self.socket?.disconnect()
    }
    
    func send(string: String) {
        self.socket?.write(string: string)
    }
    
    func send(data: Data) {
        self.socket?.write(data: data)
    }
    
    deinit {
        zmLog.info("CallingSignalSocket-deinit")
    }
}

extension CallingSignalSocket: WebSocketDelegate, WebSocketPongDelegate {
    
    public func websocketDidReceivePong(socket: WebSocketClient, data: Data?) {
        zmLog.info("CallingSignalSocket-websocketDidReceivePong")
    }
    
    public func websocketDidConnect(socket: WebSocketClient) {
        zmLog.info("CallingSignalSocket-websocketDidConnect")
        self.delegate.receive(action: .connected)
        self.reConnectedTimes = 0
    }
    
    public func websocketDidDisconnect(socket: WebSocketClient, error: Error?) {
        zmLog.info("CallingSignalSocket-websocketDidDisconnect")
        self.reConnectedTimes += 1
        if self.reConnectedTimes > 6 {
            self.delegate.receive(action: .disconnected(needDestory: true))
        } else {
            self.delegate.receive(action: .disconnected(needDestory: false))
            roomWorkQueue.asyncAfter(deadline: .now() + 5) {
                self.reConnect()
            }
        }
    }
    
    public func websocketDidReceiveData(socket: WebSocketClient, data: Data) {
        self.delegate.receive(action: .data(data: data))
    }
    
    public func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
        self.delegate.receive(action: .text(text: text))
    }
}
