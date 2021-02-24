//
//  NetworkSocket+Ack.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/4/11.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation

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

private let recvSocketSignalDispatchGroup: ZMSDispatchGroup = ZMSDispatchGroup(label: "MediasoupRecvSocketSignalDispatchGroup")
private let recvSocketSignalQueue: DispatchQueue = DispatchQueue.init(label: "MediasoupRecvSocketSignalQueue")

public class CallingSignalSocket: NSObject {

    private var socket: ZMWebSocket?
    private var reConnectedTimes: Int = 0
    
    private let url: URL
    private let delegate: SocketActionDelegate
    private var isManualShutdown: Bool = false //是否手动关闭当前websocket
    
    init(url: URL, delegate: SocketActionDelegate) {
        zmLog.info("CallingSignalSocket-init--url:\(url)")
        self.url = url
        self.delegate = delegate
        super.init()
    }
    
    private func createSocket() {
        self.socket = ZMWebSocket(consumer: self, queue: recvSocketSignalQueue, group: recvSocketSignalDispatchGroup, url: url, trustProvider: self, additionalHeaderFields: ["Sec-WebSocket-Protocol": "media--protoo"])
    }

    func connect() {
        zmLog.info("CallingSignalSocket-connect")
        self.isManualShutdown = false
        self.createSocket()
    }
    
    func disConnect() {
        zmLog.info("CallingSignalSocket-disConnect")
        self.isManualShutdown = true
        self.socket?.close()
        self.socket = nil
    }
    
    private func reConnect() {
        zmLog.info("CallingSignalSocket-reConnect")
        self.socket = nil
        self.createSocket()
    }
    
    func send(string: String) {
        self.socket?.sendTextFrame(with: string)
    }
    
    func send(data: Data) {
        self.socket?.sendBinaryFrame(with: data)
    }
    
    deinit {
        zmLog.info("CallingSignalSocket-deinit")
    }
}

extension CallingSignalSocket: ZMWebSocketConsumer, BackendTrustProvider {
    
    public func verifyServerTrust(trust: SecTrust, host: String?) -> Bool {
        return true
    }
    
    public func webSocketDidCompleteHandshake(_ websocket: ZMWebSocket!, httpResponse response: HTTPURLResponse!) {
        zmLog.info("CallingSignalSocket-webSocketDidCompleteHandshake")
        self.delegate.receive(action: .connected)
    }
    
    public func webSocket(_ webSocket: ZMWebSocket!, didReceiveFrameWith data: Data!) {
        self.delegate.receive(action: .data(data: data))
    }
    
    public func webSocket(_ webSocket: ZMWebSocket!, didReceiveFrameWithText text: String!) {
        self.delegate.receive(action: .text(text: text))
    }
    
    public func webSocketDidClose(_ webSocket: ZMWebSocket!, httpResponse response: HTTPURLResponse!, error: Error!) {
        zmLog.info("CallingSignalSocket-webSocketDidClose isManualShutdown:\(isManualShutdown) error==\(String(describing: error))")
        //如果手动关闭，则不需要重新连接
        if self.isManualShutdown {
            return
        }
        self.reConnectedTimes += 1
        if self.reConnectedTimes > 6 {
            self.delegate.receive(action: .disconnected(needDestory: true))
        } else {
            self.delegate.receive(action: .disconnected(needDestory: false))
            roomWorkQueue.asyncAfter(deadline: .now() + 3) {
                self.reConnect()
            }
        }
    }
    
}
