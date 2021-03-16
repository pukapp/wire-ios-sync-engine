//
//  DataWormholeManager.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/8/11.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation

private let kRecvBufferMaxSize: Int32 = 1024 * 1024 * 15


// MARK: Client端，绑定端口，发送数据
public class DataWormholeClientManager: NSObject {
    
    public static let sharedManager: DataWormholeClientManager = DataWormholeClientManager()
        
    private var recvBuffer: UnsafeMutablePointer<NTESTPCircularBuffer>?
    private var sendDataQueue: DispatchQueue = DispatchQueue.init(label: "SendClientSocketManager")
    
    private var socket: GCDAsyncSocket!
    private var connected: Bool = false
    private var frameCount: Int = 0
        
        
    public func setUpSocket() {
        recvBuffer = UnsafeMutablePointer<NTESTPCircularBuffer>.allocate(capacity: 1)
        _NTESTPCircularBufferInit(recvBuffer, kRecvBufferMaxSize, MemoryLayout<NTESTPCircularBuffer>.size)
        
        self.socket = GCDAsyncSocket.init(delegate: self, delegateQueue: sendDataQueue)
        try! self.socket.connect(toHost: "127.0.0.1", onPort: 8999)
        self.socket.readData(withTimeout: -1, tag: 0)
    }
    
    public func socketDelloc() {
        connected = false
        if socket != nil {
            socket.disconnect()
            socket = nil
            NTESTPCircularBufferCleanup(recvBuffer);
        }
    }
    
    public func sendDataToHostApp(with data: Data) {
        if self.socket == nil {
            self.setUpSocket()
            return
        }
        
        self.sendDataQueue.async {
            autoreleasepool {
                if self.frameCount > 1000 {
                    return;
                }
                self.frameCount += 1;
                let headerData = NTESSocketPacket.packet(withBuffer: data)
                self.socket.write(headerData, withTimeout: 5, tag: 0)
                self.socket.write(data, withTimeout: 5, tag: 0)
                self.frameCount -= 1;
            }
        }
    }
        
}

extension DataWormholeClientManager: GCDAsyncSocketDelegate {
    
    public func socket(_ sock: GCDAsyncSocket, didConnectTo url: URL) {
        self.socket.readData(withTimeout: -1, tag: 0)
    }
    
    public func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        self.socket.readData(withTimeout: -1, tag: 0)
        self.connected = true
    }
    
    public func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
        self.connected = false
        if self.socket != nil {
            self.socket.disconnect()
            self.socket = nil
        }
    }
}


protocol DataWormholeDataTransportDelegate {
    func onRecvData(data: Data)
}

// MARK: Server端，监听端口，收取数据
public class DataWormholeServerManager: NSObject {

    public static let sharedManager: DataWormholeServerManager = DataWormholeServerManager()
        
    private var delegate: DataWormholeDataTransportDelegate?
    
    private var sockets: [GCDAsyncSocket] = []
    private var socket: GCDAsyncSocket?
    private var recvBuffer: UnsafeMutablePointer<NTESTPCircularBuffer>?
    private let recvServerSocketQueue: DispatchQueue = DispatchQueue.init(label: "RecvServerSocketManager")
    
    private var currenDataSize: Int64 = 0
    private var targeDataSize: Int64 = 0
    
    func setupSocket(with delegate: DataWormholeDataTransportDelegate) {
        recvServerSocketQueue.async {
            self.delegate = delegate
            self.recvBuffer = UnsafeMutablePointer<NTESTPCircularBuffer>.allocate(capacity: 1)
            _NTESTPCircularBufferInit(self.recvBuffer, kRecvBufferMaxSize, MemoryLayout<NTESTPCircularBuffer>.size)
            self.socket = GCDAsyncSocket.init(delegate: self, delegateQueue: self.recvServerSocketQueue)
            self.socket?.isIPv6Enabled = false
            try! self.socket?.accept(onPort: 8999)
            self.socket?.readData(withTimeout: -1, tag: 0)
        }
    }
    
    func stopSocket() {
        recvServerSocketQueue.async {
            if self.socket != nil {
                self.socket?.disconnect()
                self.socket = nil
                self.sockets.removeAll()
                NTESTPCircularBufferCleanup(self.recvBuffer)
            }
        }
    }

}

extension DataWormholeServerManager: GCDAsyncSocketDelegate {
    
    public func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
        NTESTPCircularBufferClear(self.recvBuffer)
        self.sockets = self.sockets.filter({ return $0 != sock })
    }
    
    public func socketDidCloseReadStream(_ sock: GCDAsyncSocket) {
        NTESTPCircularBufferClear(self.recvBuffer)
        self.sockets = self.sockets.filter({ return $0 != sock })
    }
    
    public func socket(_ sock: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
        NTESTPCircularBufferClear(self.recvBuffer)
        self.sockets.append(newSocket)
        newSocket.readData(withTimeout: -1, tag: 0)
    }
    
    public func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        var isHeader: Bool = false
        if data.count == MemoryLayout<NTESPacketHead>.size {
            let header = data.withUnsafeBytes({ $0.load(as: NTESPacketHead.self
                ) })
            if header.version == 1 && header.command_id == 1 && header.service_id == 1 {
                isHeader = true
                targeDataSize = Int64(header.data_len)
                currenDataSize = 0
            }
        } else {
            currenDataSize += Int64(UInt64(data.count))
        }
        
        if isHeader { // a.接收到新的帧头，需要先把原来的缓存处理或者清空
            self.handleRecvBuffer()
            data.withUnsafeBytes({ bytes in
               let _ = NTESTPCircularBufferProduceBytes(self.recvBuffer, bytes.baseAddress!, Int32(data.count))
            })
        } else if currenDataSize >= targeDataSize && currenDataSize != -1 {
            // b.加上新来的数据后缓存中已经满足一帧
            data.withUnsafeBytes({ bytes in
               let _ = NTESTPCircularBufferProduceBytes(self.recvBuffer, bytes.baseAddress!, Int32(data.count))
            })
            currenDataSize = -1
            self.handleRecvBuffer()
        } else { // c.不够一帧，只添加不处理
            data.withUnsafeBytes({ bytes in
               let _ = NTESTPCircularBufferProduceBytes(self.recvBuffer, bytes.baseAddress!, Int32(data.count))
            })
        }
        sock.readData(withTimeout: -1, tag: 0)
    }
    
    func handleRecvBuffer() {
        if self.sockets.count == 0 { return }
        
        var availableBytes: Int32 = 0
        let buffer = NTESTPCircularBufferTail(self.recvBuffer, &availableBytes)
        let headSize = MemoryLayout<NTESPacketHead>.size
        
        if availableBytes <= headSize {
            NTESTPCircularBufferClear(self.recvBuffer)
            return
        }
        
        let headerPtr: UnsafeMutableRawPointer = malloc(Int(headSize))
        memset(headerPtr, 0, headSize)
        memcpy(headerPtr, buffer, headSize);
        let header = headerPtr.load(as: NTESPacketHead.self)
        free(headerPtr)
        
        let dataLen = header.data_len
        if dataLen > availableBytes - Int32(headSize) && dataLen > 0 {
            NTESTPCircularBufferClear(self.recvBuffer)
            return
        }
        
        let data = Data.init(bytes: buffer!.advanced(by: headSize), count: Int(dataLen))
        NTESTPCircularBufferClear(self.recvBuffer) // 处理完一帧数据就清空缓存
        guard data.count > 0 else { return }
        self.delegate?.onRecvData(data: data)
    }
}
