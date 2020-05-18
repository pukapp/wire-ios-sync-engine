//
//  Mediasoup+Consumer.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/4/23.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import Mediasoupclient

private let zmLog = ZMSLog(tag: "calling")

extension MediasoupCallPeersManager {
    ///转换成avsMember 供上层调用
    public var avsMembers : [AVSCallMember] {
        return self.peers.map({
            return $0.toAvsMember()
        })
    }
    
    var isRoomEmpty: Bool {
        return self.peers.isEmpty
    }
}

class MediasoupCallPeersManager {

    private var selfUserId: UUID?
    private var selfVideoTrack: RTCVideoTrack?
    private var peers: [MediasoupCallMember] = []
    
    
    func addNewPeer(with peerId: UUID) {
        if let peer = self.peers.first(where: { return $0.peerId == peerId }) {
            peer.connectState = .unConnected
        } else {
            let peer = MediasoupCallMember(peerId: peerId, connectState: .unConnected, isVideo: false)
            self.peers.append(peer)
        }
    }
    
    func removePeer(with peerId: UUID) {
        guard let peer = self.peers.first(where: { return $0.peerId == peerId }) else {
            return
        }
        peer.clear()
        self.peers = self.peers.filter({ return $0.peerId != peerId })
    }
    
    func addNewConsumer(with peerId: UUID, consumer: Consumer, listener: MediasoupConsumerListener) {
        if let peer = self.peers.first(where: {return $0.peerId == peerId }) {
            peer.addNewConsumer(with: consumer, listener: listener)
        } else {
            ///没有收到newPeer事件，却先接受到了consumer
            let peer = MediasoupCallMember(peerId: peerId, connectState: .unConnected, isVideo: false)
            self.peers.append(peer)
            peer.addNewConsumer(with: consumer, listener: listener)
        }
    }
    
    func removeConsumer(with consumerId: String) {
        guard let peer = self.peers.first(where: { return $0.containConsumer(with: consumerId) }) else {
            return
        }
        peer.removeConsumer(with: consumerId)
    }
    
    func getPeer(with consumerId: String) -> MediasoupCallMember? {
        if let peer = self.peers.first(where: { return $0.containConsumer(with: consumerId) }) {
            return peer
        } else {
            return nil
        }
    }
    
    func clear() {
        self.peers.forEach({ $0.clear() })
        self.peers.removeAll()
    }
    
    deinit {
        zmLog.info("Mediasoup::deinit:---MediasoupCallPeersManager")
    }
}

///videoTrack manager
extension MediasoupCallPeersManager {
    
    func removeSelfVideoTrack(userId: UUID) {
        if self.selfUserId == userId {
            self.selfVideoTrack = nil
        }
    }
    
    func addSelfVideoTrack(userId: UUID, videoTrack: RTCVideoTrack) {
        self.selfUserId = userId
        self.selfVideoTrack = videoTrack
    }
    
    func getVideoTrack(with peerId: UUID) -> RTCVideoTrack? {
        ///self
        if peerId == self.selfUserId {
            return self.selfVideoTrack
        }
        ///peers
        if let peer = self.peers.first(where: {return $0.peerId == peerId }) {
            return peer.consumers.first(where: { return $0.getKind() == "video" })?.getTrack() as? RTCVideoTrack
        }
        return nil
    }
    
}

class MediasoupCallMember {
    
    enum ConnectState {
        case unConnected
        case connecting
        case connected
        case connectedFailure
    }
    
    let peerId: UUID
    var connectState: ConnectState
    var isVideo: Bool

    var consumers: [Consumer] = []
    var consumerListeners: [MediasoupConsumerListener] = []
    
    fileprivate init(peerId: UUID, connectState: ConnectState, isVideo: Bool) {
        self.peerId = peerId
        self.connectState = connectState
        self.isVideo = isVideo
    }
    
    fileprivate func addNewConsumer(with consumer: Consumer, listener: MediasoupConsumerListener) {
        if let index = self.consumers.firstIndex(where: {return $0.getKind() == consumer.getKind() }) {
            self.consumers[index] = consumer
            self.consumerListeners[index] = listener
        } else {
            self.consumers.append(consumer)
            self.consumerListeners.append(listener)
        }
        self.connectState = .connected
        if consumer.getKind() == "video" {
            self.isVideo = true
        }
    }
    
    fileprivate func removeConsumer(with id: String) {
        if let index = self.consumers.firstIndex(where: {return $0.getId() == id }) {
            self.consumers[index].close()
            zmLog.info("Mediasoup::removeConsumer--\(self.consumers.count)")
            self.consumers.remove(at: index)
            self.consumerListeners.remove(at: index)
        }
    }
    
    func consumer(with id: String) -> Consumer? {
        if let consumer = self.consumers.first(where: {return $0.getId() == id }) {
            return consumer
        } else {
            return nil
        }
    }
    
    func containConsumer(with id: String) -> Bool {
        if let _ = self.consumers.firstIndex(where: {return $0.getId() == id }) {
            return true
        } else {
            return false
        }
    }
    
    
    fileprivate func clear() {
        self.consumers.forEach({
            $0.close()
        })
        zmLog.info("Mediasoup::MediasoupCallMember--clear")
        self.consumers.removeAll()
        self.consumerListeners.removeAll()
    }
    
    func toAvsMember() -> AVSCallMember {
        return AVSCallMember(userId: self.peerId, audioEstablished: self.connectState == .connected, videoState: self.isVideo ? VideoState.started : VideoState.stopped, networkQuality: .normal)
    }
    
    deinit {
        zmLog.info("Mediasoup::deinit:---MediasoupCallMember")
    }
}

