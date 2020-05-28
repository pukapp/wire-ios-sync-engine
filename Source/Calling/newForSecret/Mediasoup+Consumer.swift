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

protocol MediasoupCallPeersObserver {
    func roomPeersStateChange()
    func roomPeersVideoStateChange(peerId: UUID, videoState: VideoState)
}

class MediasoupCallPeersManager {

    private var selfUserId: UUID?
    private var selfVideoTrack: RTCVideoTrack?
    private var peers: [MediasoupCallMember] = []
    
    private let observer: MediasoupCallPeersObserver
    
    init(observer: MediasoupCallPeersObserver) {
        self.observer = observer
    }
    
    func addNewPeer(with peerId: UUID) {
        if let peer = self.peers.first(where: { return $0.peerId == peerId }) {
            peer.setPeerConnectState(with: .connecting)
        } else {
            let peer = MediasoupCallMember(peerId: peerId, isVideo: false, stateObserver: self)
            self.peers.append(peer)
        }
    }
    
    func peerDisConnect(with peerId: UUID) {
        guard let peer = self.peers.first(where: { return $0.peerId == peerId }) else {
            zmLog.info("mediasoup::peerDisConnect--no peer to disConnect")
            return
        }
        peer.setPeerConnectState(with: .connecting)
    }
    
    func removePeer(with peerId: UUID) {
        guard let peer = self.peers.first(where: { return $0.peerId == peerId }) else {
            zmLog.info("mediasoup::removePeer--no peer to remove")
            return
        }
        peer.clear()
        self.peers = self.peers.filter({ return $0.peerId != peerId })
        peer.setPeerConnectState(with: .unconnected)
    }
    
    func addNewConsumer(with peerId: UUID, consumer: Consumer, listener: MediasoupConsumerListener) {
        if let peer = self.peers.first(where: {return $0.peerId == peerId }) {
            peer.addNewConsumer(with: consumer, listener: listener)
        } else {
            ///没有收到newPeer事件，却先接受到了consumer
            let peer = MediasoupCallMember(peerId: peerId, isVideo: false, stateObserver: self)
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
    
    var peersCount: Int {
        return self.peers.count
    }
    
    ///总共接收到的视频个数
    var totalVideoConsumersCount: Int {
        return self.peers.filter({ return $0.hasVideo }).count
    }
    
    ///自己是否开启了视频
    var selfProduceVideo: Bool {
        return self.selfVideoTrack != nil
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

extension MediasoupCallPeersManager : MediasoupCallMemberStateObserver {
    func callMemberConnectStateChange() {
        self.observer.roomPeersStateChange()
    }
    
    func callMemberVideoStateChange(peerId: UUID, videoState: VideoState) {
        self.observer.roomPeersVideoStateChange(peerId: peerId, videoState: videoState)
    }
    
    func callMemberConnectingTimeout(with peerID: UUID) {
        self.removePeer(with: peerID)
        self.observer.roomPeersStateChange()
    }
}

protocol MediasoupCallMemberStateObserver {
    func callMemberConnectStateChange()
    func callMemberVideoStateChange(peerId: UUID, videoState: VideoState)
    func callMemberConnectingTimeout(with peerID: UUID)
}

class MediasoupCallMember: ZMTimerClient {
    
    private let connectTimeInterval: TimeInterval = 60
    
    enum ConnectState {
        case connecting
        case connected
        case unConnected
    }
    
    let peerId: UUID
    private var connectState: CallParticipantState = .connecting
    var isVideo: Bool
    let stateObserver: MediasoupCallMemberStateObserver
    
    var callTimer: ZMTimer?

    var consumers: [Consumer] = []
    var consumerListeners: [MediasoupConsumerListener] = []
    
    fileprivate init(peerId: UUID, isVideo: Bool, stateObserver: MediasoupCallMemberStateObserver) {
        self.peerId = peerId
        self.isVideo = isVideo
        self.stateObserver = stateObserver
        callTimer = ZMTimer(target: self)
        callTimer?.fire(afterTimeInterval: connectTimeInterval)
    }
    
    fileprivate func setPeerConnectState(with state: CallParticipantState) {
        self.connectState = state
        callTimer?.cancel()
        callTimer = nil
        if state == .connecting {
            callTimer = ZMTimer(target: self)
            callTimer?.fire(afterTimeInterval: connectTimeInterval)
        }
        zmLog.info("Mediasoup::MediasoupCallMember--setPeerConnectState--\(state)\n")
        self.stateObserver.callMemberConnectStateChange()
    }
    
    func timerDidFire(_ timer: ZMTimer!) {
        if self.connectState == .connecting || self.connectState == .unconnected {
            zmLog.info("Mediasoup::MediasoupCallMember--timerDidFire--\(self.peerId)\n")
            self.stateObserver.callMemberConnectingTimeout(with: self.peerId)
        }
    }
    
    fileprivate func addNewConsumer(with consumer: Consumer, listener: MediasoupConsumerListener) {
        if let index = self.consumers.firstIndex(where: {return $0.getKind() == consumer.getKind() }) {
            self.consumers[index] = consumer
            self.consumerListeners[index] = listener
        } else {
            self.consumers.append(consumer)
            self.consumerListeners.append(listener)
        }
        if consumer.getKind() == "video" {
            self.setPeerConnectState(with: .connected(videoState: .started))
            self.stateObserver.callMemberVideoStateChange(peerId: self.peerId, videoState: .started)
        } else {
            self.setPeerConnectState(with: .connected(videoState: .stopped))
        }
    }
    
    fileprivate func removeConsumer(with id: String) {
        if let index = self.consumers.firstIndex(where: {return $0.getId() == id }) {
            ///这里必须先将视频画面给关闭，再closeConsumer，否则会出现闪退
            if self.consumers[index].getKind() == "video" {
                self.stateObserver.callMemberVideoStateChange(peerId: self.peerId, videoState: .stopped)
            }
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
    
    var hasVideo: Bool {
        return self.consumers.contains(where: { return $0.getKind() == "video" })
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
        return AVSCallMember(userId: self.peerId, callParticipantState: self.connectState, networkQuality: .normal)
    }
    
    deinit {
        zmLog.info("Mediasoup::deinit:---MediasoupCallMember")
    }
}

