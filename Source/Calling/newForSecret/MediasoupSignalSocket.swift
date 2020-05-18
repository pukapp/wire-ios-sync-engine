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
    case disconnected
    case text(text: String)
    case data(data: Data)
}

protocol SocketActionDelegate {
    func receive(action: SocketAction)
}

public class MediasoupSignalSocket {

    private let socketQueue: DispatchQueue = DispatchQueue(label: "MediasoupSignalSocketRecv")
    private var socket: WebSocket?
    private var reConnectedTimes: Int = 0
    
    private let url: URL
    private let delegate: SocketActionDelegate

    init(url: URL, delegate: SocketActionDelegate) {
        self.url = url
        self.delegate = delegate
        self.socket = WebSocket.init(url: url, protocols: ["secret-media"])//secret-media
        self.socket!.disableSSLCertValidation = true
        self.socket!.callbackQueue = self.socketQueue
        self.socket!.delegate = self
    }

    func connect() {
        zmLog.info("mediasoup::socket-connect")
        self.socket?.connect()
    }
    
    func disConnect() {
        zmLog.info("mediasoup::socket-disConnect")
        self.socket?.disconnect()
    }
    
    func send(string: String) {
        self.socket?.write(string: string)
    }
    
    deinit {
        zmLog.info("Mediasoup::deinit:---MediasoupSignalSocket")
    }
}

extension MediasoupSignalSocket: WebSocketDelegate {
    
    public func websocketDidConnect(socket: WebSocketClient) {
        self.delegate.receive(action: .connected)
        self.reConnectedTimes = 0
    }
    
    public func websocketDidDisconnect(socket: WebSocketClient, error: Error?) {
        zmLog.info("Mediasoup::socket:---websocketDidDisconnect")
        self.reConnectedTimes += 1
        if self.reConnectedTimes > 8 {
            self.delegate.receive(action: .disconnected)
        } else {
            socket.connect()
        }
    }
    
    public func websocketDidReceiveData(socket: WebSocketClient, data: Data) {
        self.delegate.receive(action: .data(data: data))
    }
    
    public func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
        self.delegate.receive(action: .text(text: text))
    }
}
