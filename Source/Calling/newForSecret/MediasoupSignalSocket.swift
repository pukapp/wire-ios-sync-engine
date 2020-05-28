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

private let socketRecvQueue: DispatchQueue = DispatchQueue(label: "MediasoupSignalSocket.RecvQueue")

public class MediasoupSignalSocket {

    private var socket: WebSocket?
    private var reConnectedTimes: Int = 0
    
    private let url: URL
    private let delegate: SocketActionDelegate

    init(url: URL, delegate: SocketActionDelegate) {
        zmLog.info("Mediasoup::Socket-init--url:\(url)")
        self.url = url
        self.delegate = delegate
        self.createSocket()
    }
    
    func createSocket() {
        self.socket = WebSocket.init(url: url, protocols: ["secret-media"])//secret-media--protoo
        self.socket!.disableSSLCertValidation = true
        self.socket!.callbackQueue = socketRecvQueue
        self.socket!.delegate = self
    }

    func connect() {
        zmLog.info("Mediasoup::Socket-connect")
        self.socket?.connect()
    }
    
    func reConnect() {
        zmLog.info("Mediasoup::Socket-reConnect")
        self.socket?.connect()
    }
    
    func disConnect() {
        zmLog.info("Mediasoup::Socket-disConnect")
        self.socket?.disconnect()
    }
    
    func send(string: String) {
        self.socket?.write(string: string)
    }
    
    deinit {
        zmLog.info("Mediasoup::Socket-deinit")
    }
}

extension MediasoupSignalSocket: WebSocketDelegate, WebSocketPongDelegate {
    
    public func websocketDidReceivePong(socket: WebSocketClient, data: Data?) {
        zmLog.info("Mediasoup::Socket-websocketDidReceivePong")
    }
    
    public func websocketDidConnect(socket: WebSocketClient) {
        zmLog.info("Mediasoup::Socket-websocketDidConnect")
        self.delegate.receive(action: .connected)
        self.reConnectedTimes = 0
    }
    
    public func websocketDidDisconnect(socket: WebSocketClient, error: Error?) {
        zmLog.info("Mediasoup::Socket-websocketDidDisconnect")
        self.reConnectedTimes += 1
        if self.reConnectedTimes > 8 {
            self.delegate.receive(action: .disconnected(needDestory: true))
        } else {
            self.delegate.receive(action: .disconnected(needDestory: false))
            self.reConnect()
        }
    }
    
    public func websocketDidReceiveData(socket: WebSocketClient, data: Data) {
        self.delegate.receive(action: .data(data: data))
    }
    
    public func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
        self.delegate.receive(action: .text(text: text))
    }
}
