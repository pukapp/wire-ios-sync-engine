//
//  MediasoupRoomManager.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/4/9.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON
import Mediasoupclient

private let zmLog = ZMSLog(tag: "calling")

extension MediasoupRoomManager: MediasoupSignalManagerDelegate {
    
    func socketConnected() {
        zmLog.info("mediasoup::socketState:socketConnected")
        self.signalManager.requestToGetRoomRtpCapabilities()
    }
    
    func socketDisconnected() {
        zmLog.info("mediasoup::socketState:socketDisconnected")
        if let roomId = self.roomId {
            self.delegate?.leaveRoom(conversationId: roomId, reason: .internalError)
        }
    }
    
    func onReceiveResponse(with action: MediasoupSignalAction.SendRequest, info: JSON) {
        switch action {
        case .getRouterRtpCapabilities:
            zmLog.info("mediasoup::onReceiveResponse:getRouterRtpCapabilities")
            self.device!.load(info.description)
            self.joinRoom()
        case .createWebRtcTransport(let isProducing):
            zmLog.info("mediasoup::onReceiveResponse:createWebRtcTransport")
            self.processWebRtcTransport(with: isProducing, webRtcTransportData: info)
            
            if self.sendTransport != nil && self.recvTransport != nil {
                self.signalManager.loginRoom(with: self.device!.getRtpCapabilities())
            }
        case .loginRoom:
            zmLog.info("mediasoup::onReceiveResponse:loginRoom")
            if let peers = info["peers"].array,
                peers.count > 0 {
                for info in peers {
                    receiveNewPeer(peerInfo: info)
                }
            }
            DispatchQueue.global().async {
                self.produceAudio()
                if self.callType == .video {
                    self.produceVideo()
                }
            }
        default:break
        }
    }
    
    func onReceiveRequest(with action: MediasoupSignalAction.ReceiveRequest, info: JSON) {
        switch action {
        case .newConsumer:
            if (self.recvTransport == nil || !readyToComsumer) {
                // User has not yet created a transport for receiving so temporarily store it
                // and play it when the recv transport is created
                self.consumersInfo.append(info)
                return
            }
            handleNewConsumer(with: info)
        }
    }
    
    func onNewNotification(with action: MediasoupSignalAction.Notification, info: JSON) {
        switch action {
        case .consumerPaused, .consumerResumed, .consumerClosed:
            self.handleConsumerState(with: action, consumerInfo: info)
        case .peerClosed:
            guard let roomId = self.roomId,
                let peerId = info["peerId"].string,
                let pUid = UUID(uuidString: peerId) else {
                return
            }
            self.roomPeersManager?.removePeer(with: pUid)
            if self.roomPeersManager?.isRoomEmpty ?? true {
                self.delegate?.leaveRoom(conversationId: roomId, reason: .normal)
            } else {
                self.delegate?.onGroupMemberChange(conversationId: roomId)
            }
        case .newPeer:
            self.receiveNewPeer(peerInfo: info)
        case .peerDisplayNameChanged:
            break
        }
    }

}

protocol MediasoupRoomManagerDelegate {
    func onNewPeer(conversationId: UUID, peerId: UUID)
    func onNewConsumer(conversationId: UUID, peerId: UUID)
    func leaveRoom(conversationId: UUID, reason: CallClosedReason)
    func onVideoStateChange(peerId: UUID, videoStart: VideoState)
    func onGroupMemberChange(conversationId: UUID)
}

class MediasoupRoomManager: NSObject {
    
    static let shareInstance: MediasoupRoomManager = MediasoupRoomManager()
    
    private var delegate: MediasoupRoomManagerDelegate?
    private var signalManager: MediasoupSignalManager!
    
    private var device: Device?
    var mediaOutputManager: MediaOutputManager?
    
    private var roomId: UUID?
    private var userId: UUID?
    
    private var sendTransport: SendTransport?
    private var recvTransport: RecvTransport?
    private var sendTransportListen: MediasoupTransportListener?
    private var recvTransportListen: MediasoupTransportListener?
    
    private var producers: [Producer]
    private var producerListeners: [MediasoupProducerListener]
    
    var roomPeersManager: MediasoupCallPeersManager?
    ///存储从服务端接收到的consumerJson数据，由于房间状态问题，暂不解析成consumer
    private var consumersInfo: [JSON]
    
    var callType: AVSCallType = .normal
    
    ///当callKit准备好，才能去接收consumers，否则语音进程会被系统的callkit所打断
    var readyToComsumer: Bool = false {
        didSet {
            if readyToComsumer {
                handleRetainedConsumers()
            }
        }
    }
    
    override init() {
        Mediasoupclient.initializePC()
        Logger.setLogLevel(LogLevel.LOG_DEBUG)
        Logger.setDefaultHandler()
        producers = []
        producerListeners = []
        consumersInfo = []
        super.init() //wss://13.76.41.238:4443 //wss://192.168.3.66:4443
        signalManager = MediasoupSignalManager(url: "wss://13.76.41.238:4443", delegate: self)
    }
    
    func connectToRoom(with roomId: UUID,callType: AVSCallType, userId: UUID, delegate: MediasoupRoomManagerDelegate) -> Bool {
        guard self.roomId == nil else {
            ///已经在房间里面了
            return false
        }
        
        zmLog.info("mediasoup::initDevice\n")
        self.device = Device()
        self.mediaOutputManager = MediaOutputManager()
        
        self.delegate = delegate
        self.roomId = roomId
        self.callType = callType
        self.userId = userId
        self.roomPeersManager = MediasoupCallPeersManager()
        signalManager.connectRoom(with: roomId.transportString(), userId: self.userId!.transportString())
        return true
    }
    
    func leaveRoom(with roomId: UUID) {
        zmLog.info("Mediasoup::leaveRoom\n")
        if roomId == self.roomId {
            signalManager.leaveRoom()
        
            self.readyToComsumer = false

            self.sendTransport?.close()
            self.sendTransport = nil
            self.sendTransportListen = nil
            self.recvTransport?.close()
            self.recvTransport = nil
            self.recvTransportListen = nil

            self.roomPeersManager?.clear()
            self.consumersInfo.removeAll()
            self.producers.forEach({ $0.close() })
            self.producers.removeAll()
            self.producerListeners.removeAll()

            ///这两个需在上面的变量释放之后再进行释放
            self.mediaOutputManager?.clear()
            self.mediaOutputManager = nil
            self.device = nil
            zmLog.info("Mediasoup::destoryDevice\n")
            self.roomId = nil
        }
    }
    
    func joinRoom() {
        guard let device = self.device, device.isLoaded() else {
            return
        }

        ///创建transport
        signalManager.createWebRtcTransportRequest(with: false)
        signalManager.createWebRtcTransportRequest(with: true)
    }

    func receiveNewPeer(peerInfo: JSON) {
        guard let roomId = self.roomId,
            let peerId = peerInfo["id"].string,
            let uid = UUID(uuidString: peerId) else {
                return
        }
        self.roomPeersManager?.addNewPeer(with: uid)
        self.delegate?.onNewPeer(conversationId: roomId, peerId: uid)
    }
    
    func processWebRtcTransport(with isProducing: Bool, webRtcTransportData: JSON) {
        let id: String = webRtcTransportData["id"].stringValue
        let iceParameters: String = webRtcTransportData["iceParameters"].description
        let iceCandidates: String = webRtcTransportData["iceCandidates"].description
        let dtlsParameters: String = webRtcTransportData["dtlsParameters"].description
        
        if isProducing {
            self.sendTransportListen = MediasoupTransportListener(isProduce: true, delegate: self)
            self.sendTransport = self.device!.createSendTransport(sendTransportListen, id: id, iceParameters: iceParameters, iceCandidates: iceCandidates, dtlsParameters: dtlsParameters)
        } else {
            self.recvTransportListen = MediasoupTransportListener(isProduce: false, delegate: self)
            self.recvTransport = self.device!.createRecvTransport(recvTransportListen, id: id, iceParameters: iceParameters, iceCandidates: iceCandidates, dtlsParameters: dtlsParameters)
            // Play consumers that have been stored
            handleRetainedConsumers()
        }
    }
    
}

class MediasoupConsumerListener: NSObject, ConsumerListener {
    
    let consumerId: String
    
    init(consumerId: String) {
        self.consumerId = consumerId
    }
    
    func onTransportClose(_ consumer: Consumer!) {
        zmLog.info("Mediasoup::ConsumerListener---onTransportClose\n")
    }
    
    deinit {
        zmLog.info("Mediasoup::deinit:---MediasoupConsumerListener\n")
    }
}

class MediasoupProducerListener: NSObject, ProducerListener {
    
    var producerId: String?
    
    func onTransportClose(_ producer: Producer!) {
        zmLog.info("Mediasoup::ProducerListener---onTransportClose\n")
    }
    
    deinit {
        zmLog.info("Mediasoup::deinit:---MediasoupProducerListener\n")
    }
}

extension MediasoupRoomManager: MediasoupTransportListenerDelegate {
    func onProduce(_ transportId: String, kind: String, rtpParameters: String, appData: String) -> String {
        zmLog.info("Mediasoup::onProduce====kind:\(kind)\n")
        guard let produceId = signalManager.produceWebRtcTransportRequest(with: transportId, kind: kind, rtpParameters: rtpParameters, appData: appData) else {
            //fatal("Mediasoup::onProduce:getProduceId-Error")
            return ""
        }
        zmLog.info("Mediasoup::onProduce====id:\(produceId)\n")
        return produceId
    }
    
    func onConnect(_ transportId: String, dtlsParameters: String) {
        signalManager.connectWebRtcTransportRequest(with: transportId, dtlsParameters: dtlsParameters)
    }
}


protocol MediasoupTransportListenerDelegate {
    func onProduce(_ transportId: String, kind: String, rtpParameters: String, appData: String) -> String
    
    func onConnect(_ transportId: String, dtlsParameters: String)
}

class MediasoupTransportListener: NSObject, SendTransportListener, RecvTransportListener {
    
    private let isProduce: Bool
    private let delegate: MediasoupTransportListenerDelegate
    
    init(isProduce: Bool, delegate: MediasoupTransportListenerDelegate) {
        self.isProduce = isProduce
        self.delegate = delegate
        super.init()
    }

    func onProduce(_ transport: Transport!, kind: String!, rtpParameters: String!, appData: String!) -> String! {
        zmLog.info("Mediasoup::ProduceTransport-onConnect--onProduce\n")
        return self.delegate.onProduce(transport.getId(), kind: kind, rtpParameters: rtpParameters, appData: appData)
    }
    
    func onConnect(_ transport: Transport!, dtlsParameters: String!) {
        zmLog.info("Mediasoup::ProduceTransport-onConnect--listener\n")
        self.delegate.onConnect(transport.getId(), dtlsParameters: dtlsParameters)
    }
    
    func onConnectionStateChange(_ transport: Transport!, connectionState: String!) {
        if self.isProduce {
            zmLog.info("Mediasoup::ProduceTransport-connectionState----\(String(describing: connectionState))\n")
        } else {
            zmLog.info("Mediasoup::RecvTransport-connectionState----\(String(describing: connectionState))\n")
        }
        
    }
}

/// producer + deal
extension MediasoupRoomManager {
    
    func produceAudio() {
        if self.sendTransport == nil {
            return
        }
        
        if !self.device!.canProduce("audio") {
            return
        }
        
        let audioTrack: RTCAudioTrack = self.mediaOutputManager!.getAudioTrack()
        self.createProducer(track: audioTrack, codecOptions: nil, encodings: nil)
    }
    
    func produceVideo() {

        guard self.sendTransport != nil,
            self.device!.canProduce("video"),
            self.roomPeersManager?.getVideoTrack(with: self.userId!) == nil else {
                return
        }
        
        let codecOptions: JSON = [
            "x-google-start-bitrate": 1000
        ]
        
        var encodings: Array = Array<RTCRtpEncodingParameters>.init()
        encodings.append(RTCUtils.genRtpEncodingParameters(true, maxBitrateBps: 500000, minBitrateBps: 0, maxFramerate: 60, numTemporalLayers: 0, scaleResolutionDownBy: 0))
        encodings.append(RTCUtils.genRtpEncodingParameters(true, maxBitrateBps: 1000000, minBitrateBps: 0, maxFramerate: 60, numTemporalLayers: 0, scaleResolutionDownBy: 0))
        encodings.append(RTCUtils.genRtpEncodingParameters(true, maxBitrateBps: 1500000, minBitrateBps: 0, maxFramerate: 60, numTemporalLayers: 0, scaleResolutionDownBy: 0))
        
        let videoTrack = self.mediaOutputManager!.getVideoTrack()
        
        self.createProducer(track: videoTrack, codecOptions: codecOptions.description, encodings: encodings)
        
        self.roomPeersManager?.addSelfVideoTrack(userId: self.userId!, videoTrack: videoTrack)
    }
    
    private func createProducer(track: RTCMediaStreamTrack, codecOptions: String?, encodings: Array<RTCRtpEncodingParameters>?) {
        let listener = MediasoupProducerListener()
        let producer: Producer = self.sendTransport!.produce(listener, track: track, encodings: encodings, codecOptions: codecOptions)
        listener.producerId =  producer.getId()
        self.producers.append(producer)
        self.producerListeners.append(listener)
        
        zmLog.info("Mediasoup::createProducer() created id =" + producer.getId() + " kind =" + producer.getKind() + "\n")
    }
    
    func setLocalAudio(mute: Bool) {
        if let audioProduce = self.producers.first(where: {return $0.getKind() == "audio" }) {
            if mute {
                audioProduce.pause()
            } else {
                audioProduce.resume()
            }
            self.signalManager.setProduceState(with: audioProduce.getId(), pause: mute)
        }
    }
    
    func setLocalVideo(state: VideoState) {
        switch state {
        case .started:
            if let videoProduce = self.producers.first(where: {return $0.getKind() == "video" }), videoProduce.isPaused() {
                videoProduce.resume()
                self.signalManager.setProduceState(with: videoProduce.getId(), pause: false)
            } else {
                self.produceVideo()
            }
        case .stopped:
            if let videoProduce = self.producers.first(where: {return $0.getKind() == "video" }), !videoProduce.isClosed() {
                videoProduce.close()
                self.signalManager.closeProduce(with: videoProduce.getId())
                self.roomPeersManager?.removeSelfVideoTrack(userId: self.userId!)
                self.producers = self.producers.filter({ return $0.getKind() != "video" })
            }
        case .paused:
            if let videoProduce = self.producers.first(where: {return $0.getKind() == "video" }), !videoProduce.isPaused() {
                videoProduce.pause()
                self.signalManager.setProduceState(with: videoProduce.getId(), pause: true)
            }
        default:
            break;
        }
    }
}


/// consumer + deal
extension MediasoupRoomManager {
    
    func handleRetainedConsumers() {
        if self.consumersInfo.count > 0 {
            for info in self.consumersInfo {
                self.handleNewConsumer(with: info)
            }
            self.consumersInfo.removeAll()
        }
    }

    func handleNewConsumer(with consumerInfo: JSON) {
        guard let peerId = consumerInfo["appData"]["peerId"].string,
            let peerUId = UUID(uuidString: peerId) else {
            return
        }
        
        let kind: String = consumerInfo["kind"].stringValue
        let id: String = consumerInfo["id"].stringValue
        let producerId: String = consumerInfo["producerId"].stringValue
        let rtpParameters: JSON = consumerInfo["rtpParameters"]
        
        zmLog.info("Mediasoup::Consumer-NewConsumer--peer:\(peerId)--kind:\(kind)---id:\(id)\n")
        
        let consumerListen = MediasoupConsumerListener(consumerId: id)
        let consumer: Consumer = self.recvTransport!.consume(consumerListen, id: id, producerId: producerId, kind: kind, rtpParameters: rtpParameters.description)
        
        self.roomPeersManager?.addNewConsumer(with: peerUId, consumer: consumer, listener: consumerListen)
        
        if consumer.getKind() == "video" {
            self.delegate?.onVideoStateChange(peerId: peerUId, videoStart: .started)
        }
        self.delegate?.onNewConsumer(conversationId: self.roomId!, peerId: peerUId)
    }
    
    func handleConsumerState(with action: MediasoupSignalAction.Notification, consumerInfo: JSON) {
        guard let consumerId = consumerInfo["consumerId"].string,
            let peer = self.roomPeersManager?.getPeer(with: consumerId),
            let consumer = peer.consumer(with: consumerId) else {
            return
        }
        
        switch action {
        case .consumerResumed:
            consumer.resume()
        case .consumerPaused:
            consumer.pause()
        case .consumerClosed:
            ///这里必须先将视频画面给关系，再closeConsumer，否则会出现闪退
            if consumer.getKind() == "video" {
                self.delegate?.onVideoStateChange(peerId: peer.peerId, videoStart: .stopped)
            }
            self.roomPeersManager?.removeConsumer(with: consumerId)
        default: fatal("error")
        }
        
    }
    
}
