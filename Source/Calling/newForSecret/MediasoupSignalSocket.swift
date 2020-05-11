//
//  NetworkSocket+Ack.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/4/11.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import Starscream


enum SocketAction {
    case connected
    case close
    case connectFail
    case text(text: String)
    case data(data: Data)
}

protocol SocketActionDelegate {
    func receive(action: SocketAction)
}

public class MediasoupSignalSocket {

    private var socket: WebSocket?
    
    private let url: URL
    private let delegate: SocketActionDelegate

    init(url: URL, delegate: SocketActionDelegate) {
        self.url = url
        self.delegate = delegate
        self.socket = WebSocket.init(url: url, protocols: ["protoo"])
        self.socket!.disableSSLCertValidation = true
        self.socket!.callbackQueue = DispatchQueue.global()
        self.socket!.delegate = self
    }

    func connect() {
        self.socket?.connect()
    }
    
    func disConnect() {
        self.socket?.disconnect()
    }
    
    func send(string: String) {
        //print("Mediasoup::socket:send--thread:\(Thread.current)")
        self.socket?.write(string: string)
    }
    
    deinit {
        print("Mediasoup::deinit:---MediasoupSignalSocket")
    }
}

extension MediasoupSignalSocket: WebSocketDelegate {
    
    public func websocketDidConnect(socket: WebSocketClient) {
        self.delegate.receive(action: .connected)
    }
    
    public func websocketDidDisconnect(socket: WebSocketClient, error: Error?) {
        self.delegate.receive(action: .connectFail)
    }
    
    public func websocketDidReceiveData(socket: WebSocketClient, data: Data) {
        self.delegate.receive(action: .data(data: data))
    }
    
    public func websocketDidReceiveMessage(socket: WebSocketClient, text: String) {
        self.delegate.receive(action: .text(text: text))
    }
}
