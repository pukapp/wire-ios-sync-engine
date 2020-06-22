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
        signalWorkQueue.async {
            self.configureDevice()
            self.roomState = .socketConnected
        }
    }
    
    func socketDisconnected(needDestory: Bool) {
        if needDestory {
            self.roomState = .unConnected
            self.delegate?.leaveRoom(conversationId: self.roomId!, reason: .internalError)
        } else {
            self.roomState = .socketConnecting
            self.disConnectedRoom()
            self.delegate?.onReconnectingCall(conversationId: self.roomId!)
        }
    }
    
    func onReceiveRequest(with action: MediasoupSignalAction.ReceiveRequest, info: JSON) {
        zmLog.info("Mediasoup::RoomManager--onReceiveRequest:action:\(action)")
        switch action {
        case .newConsumer:
            if (self.recvTransport == nil || !readyToComsumer) {
                // 用户还没有创建recvTransport或者音频设备还没有准备好，就先存起来，不去处理
                self.consumersInfo.append(info)
                return
            }
            handleNewConsumer(with: info)
        }
    }
    
    func onNewNotification(with action: MediasoupSignalAction.Notification, info: JSON) {
        zmLog.info("Mediasoup::RoomManager--onNewNotification:action:\(action)")
        switch action {
        case .consumerPaused, .consumerResumed, .consumerClosed:
            self.handleConsumerState(with: action, consumerInfo: info)
        case .peerClosed:
            guard let peerId = info["peerId"].string,
                let pUid = UUID(uuidString: peerId) else {
                return
            }
            self.roomPeersManager?.peerDisConnect(with: pUid)
        case .newPeer:
            self.receiveNewPeer(peerInfo: info)
        case .peerLeave:
            guard let peerId = info["peerId"].string,
                let pUid = UUID(uuidString: peerId) else {
                    return
            }
            self.removePeer(with: pUid)
        case .peerDisplayNameChanged:
            break
        }
    }

}

protocol MediasoupRoomManagerDelegate {
    func onEstablishedCall(conversationId: UUID, peerId: UUID)
    func onReconnectingCall(conversationId: UUID)
    func leaveRoom(conversationId: UUID, reason: CallClosedReason)
    func onVideoStateChange(conversationId: UUID, peerId: UUID, videoState: VideoState)
    func onGroupMemberChange(conversationId: UUID, memberCount: Int)
}

/*
 * 由于关闭房间会有两种情况
 * 1.收到外部消息或主动调用，则关闭房间，释放资源
 * 2.收到socket信令，然后判断当前房间状态，为空，则释放资源
 * 由于目前im端消息的推送延迟问题，所以目前socket的peerLeave信令需要处理，im端的消息也需要处理，所以就会造成多个线程同时创建，或者同时释放的问题
 * 所以这需要是一条串行队列，否则会造成很多闪退bug
 */
let signalWorkQueue: DispatchQueue = DispatchQueue.init(label: "MediasoupSignalWorkQueue")

class MediasoupRoomManager: NSObject {
    
    enum RoomState {
        case none
        case socketConnecting
        case socketConnected
        case peerConnecting /// receive peer but no consumer
        case peerConnected /// receive consumer
        case unConnected
    }
    
    static let shareInstance: MediasoupRoomManager = MediasoupRoomManager()
    
    private var roomState: RoomState = .none
    var delegate: MediasoupRoomManagerDelegate?
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
    ///当callKit准备好，才能去接收consumers，否则语音进程会被系统的callkit所打断
    var readyToComsumer: Bool = false {
        didSet {
            zmLog.info("Mediasoup::RoomManager--readyToComsumer---\(self.consumersInfo.count)")
            if readyToComsumer {
                handleRetainedConsumers()
            }
        }
    }
    
    var isCalling: Bool {
        return (self.roomState != .none && self.roomState != .unConnected)
    }
    
    override init() {
        Mediasoupclient.initializePC()
        Logger.setLogLevel(LogLevel.TRACE)
        Logger.setDefaultHandler()
        producers = []
        producerListeners = []
        consumersInfo = []
        super.init()
        signalManager = MediasoupSignalManager(delegate: self)
    }
    
    func connectToRoom(with roomId: UUID, userId: UUID) {
        print("Mediasoup::signalWorkQueue--\(signalWorkQueue.debugDescription)")
        guard self.roomId == nil else {
            ///已经在房间里面了
            return
        }
        self.roomId = roomId
        self.userId = userId
        self.roomState = .socketConnecting
        
        self.device = Device()
        self.mediaOutputManager = MediaOutputManager()
        self.roomPeersManager = MediasoupCallPeersManager(observer: self)
        ///192.168.3.66----27.124.45.160
        self.signalManager.connectRoom(with: "wss://192.168.3.66:4443", roomId: roomId.transportString(), userId: self.userId!.transportString())
        
//        MediasoupService.requestRoomInfo(with: roomId.transportString(), uid: userId.transportString()) {[weak self] (roomInfo) in
//            signalWorkQueue.async {
//                guard let `self` = self,
//                    self.roomState == .socketConnecting else { return }
//
//                guard let info = roomInfo else {
//                    self.delegate?.leaveRoom(conversationId: roomId, reason: .internalError)
//                    return
//                }
//                self.device = Device()
//                self.mediaOutputManager = MediaOutputManager()
//                self.roomPeersManager = MediasoupCallPeersManager(observer: self)
//                self.signalManager.connectRoom(with: info.roomUrl, roomId: roomId.transportString(), userId: self.userId!.transportString())
//            }
//        }

    }
    
    func configureDevice() {
        if !self.device!.isLoaded() {
            guard let rtpCapabilities = self.signalManager.requestToGetRoomRtpCapabilities() else {
                return
            }
            self.device!.load(rtpCapabilities)
        }
        self.createWebRtcTransports()
    }
    
    ///创建transport
    private func createWebRtcTransports() {
        zmLog.info("Mediasoup::createWebRtcTransports--PThread:\(Thread.current)")
        guard let recvJson = signalManager.createWebRtcTransportRequest(with: false) else {
            return
        }
        self.processWebRtcTransport(with: false, webRtcTransportData: recvJson)
        guard let sendJson = signalManager.createWebRtcTransportRequest(with: true) else {
            return
        }
        self.processWebRtcTransport(with: true, webRtcTransportData: sendJson)
        
        self.loginRoom()
    }
    
    private func processWebRtcTransport(with isProducing: Bool, webRtcTransportData: JSON) {
        let id: String = webRtcTransportData["id"].stringValue
        let iceParameters: String = webRtcTransportData["iceParameters"].description
        let iceCandidates: String = webRtcTransportData["iceCandidates"].description
        let dtlsParameters: String = webRtcTransportData["dtlsParameters"].description
        zmLog.info("Mediasoup::RoomManager--processWebRtcTransport:\(webRtcTransportData)")
        
        if isProducing {
            self.sendTransportListen = MediasoupTransportListener(isProduce: true, delegate: self)
            self.sendTransport = self.device!.createSendTransport(sendTransportListen, id: id, iceParameters: iceParameters, iceCandidates: iceCandidates, dtlsParameters: dtlsParameters)
        } else {
            self.recvTransportListen = MediasoupTransportListener(isProduce: false, delegate: self)
            self.recvTransport = self.device!.createRecvTransport(recvTransportListen, id: id, iceParameters: iceParameters, iceCandidates: iceCandidates, dtlsParameters: dtlsParameters)
            //创建好recvTransport之后就可以开始处理接收到暂存的Consumers了
            handleRetainedConsumers()
        }
    }
    
    ///登录房间，并且获取房间内peer信息
    private func loginRoom() {
        guard let response = self.signalManager.loginRoom(with: self.device!.getRtpCapabilities()) else {
            return
        }
        if let peers = response["peers"].array,
            peers.count > 0 {
            for info in peers {
                receiveNewPeer(peerInfo: info)
            }
        }
        ///开启音频发送
        self.produceAudio()
    }
    
    ///网络断开连接
    fileprivate func disConnectedRoom() {
        
        self.signalManager.leaveGroup()
        
        ///需要在此线程中释放资源
        signalWorkQueue.async {
            zmLog.info("Mediasoup::disConnectedRoom---thread:\(Thread.current)")
            self.roomPeersManager?.removeSelfVideoTrack(userId: self.userId!)
            
            print("Mediasoup::leaveRoom--roomPeersManager-clear--thread:\(Thread.current)")
            self.consumersInfo.removeAll()
            self.producers.forEach({ $0.close() })
            self.producers.removeAll()
            self.producerListeners.removeAll()
                
            if self.sendTransport != nil {
                self.sendTransport?.close()
                self.sendTransport?.dispose()
                self.sendTransport = nil
                self.sendTransportListen = nil
            }
            
            if self.recvTransport != nil {
                self.recvTransport?.close()
                self.recvTransport?.dispose()
                self.recvTransport = nil
                self.recvTransportListen = nil
            }
        }
    }
    
    func leaveRoom(with roomId: UUID) {
        self.signalManager.leaveGroup()
        
        ///需要在此线程中释放资源
        signalWorkQueue.async {
            guard self.roomId == roomId else {
                return
            }
            zmLog.info("Mediasoup::leaveRoom---thread:\(Thread.current)")
        
            self.signalManager.peerLeave()
            
            self.roomState = .none

            self.readyToComsumer = false
            
            zmLog.info("Mediasoup::leaveRoom--roomPeersManager-clear--thread:\(Thread.current)")
            self.consumersInfo.removeAll()
            self.producers.forEach({ $0.close() })
            self.producers.removeAll()
            self.producerListeners.removeAll()
            
            if self.sendTransport != nil {
                self.sendTransport?.close()
                self.sendTransport?.dispose()
                self.sendTransport = nil
                self.sendTransportListen = nil
            }
            
            if self.recvTransport != nil {
                self.recvTransport?.close()
                self.recvTransport?.dispose()
                self.recvTransport = nil
                self.recvTransportListen = nil
            }

            zmLog.info("Mediasoup::leaveRoom--destoryDevice--\(String(describing: self.device))")
            self.device = nil
            self.roomId = nil
            
            ///这两个需在上面的变量释放之后再进行释放
            self.mediaOutputManager?.clear()
            self.mediaOutputManager = nil
            
            self.roomPeersManager?.clear()
            self.roomPeersManager = nil
            ///关闭socket
            self.signalManager.leaveRoom()
        }
    }
    
}

extension MediasoupRoomManager {
    
    func receiveNewPeer(peerInfo: JSON) {
        guard let peerId = peerInfo["id"].string,
            let uid = UUID(uuidString: peerId) else {
            return
        }
        if self.roomState != .peerConnecting {
            self.roomState = .peerConnecting
        }
        self.roomPeersManager?.addNewPeer(with: uid)
        self.delegate?.onEstablishedCall(conversationId: self.roomId!, peerId: uid)
    }
    
    func removePeer(with id: UUID) {
        ///接收end消息时会调用，所以需要放在此线程中
        signalWorkQueue.async {
            self.roomPeersManager?.removePeer(with: id)
        }
    }
    
}

extension MediasoupRoomManager: MediasoupCallPeersObserver {
    func roomPeersStateChange() {
        guard let roomId = self.roomId else {
            return
        }
        if self.roomPeersManager?.isRoomEmpty ?? false {
            zmLog.info("Mediasoup::RoomManager-roomPeersStateChange ==roomEmpty")
            self.leaveRoom(with: roomId)
            self.delegate?.leaveRoom(conversationId: roomId, reason: .normal)
        } else {
            self.delegate?.onGroupMemberChange(conversationId: roomId, memberCount: self.roomPeersManager!.peersCount)
        }
    }
    
    func roomPeersVideoStateChange(peerId: UUID, videoState: VideoState) {
        zmLog.info("Mediasoup::RoomManager--roomPeersVideoStateChange--videoState:\(videoState)")
        if self.roomPeersManager!.selfProduceVideo  {
            ///实时监测显示的视频人数，并且更改自己所发出去的视频参数
            ///这里由于受到视频关闭的时候，是先通知到界面，而不是先更改数据源的，所以这里需要判断
            let totalCount = self.roomPeersManager!.totalVideoConsumersCount
            self.mediaOutputManager?.changeVideoOutputFormat(with: VideoOutputFormat(count: (videoState == .stopped ? totalCount - 1 : totalCount)))
        }
        self.delegate?.onVideoStateChange(conversationId: self.roomId!, peerId: peerId, videoState: videoState)
    }
}

class MediasoupConsumerListener: NSObject, ConsumerListener {
    
    let consumerId: String
    
    init(consumerId: String) {
        self.consumerId = consumerId
    }
    
    func onTransportClose(_ consumer: Consumer!) {
        zmLog.info("Mediasoup::RoomManager--ConsumerListener-onTransportClose")
    }
    
    deinit {
        zmLog.info("Mediasoup::RoomManager---ConsumerListener-deinit")
    }
}

class MediasoupProducerListener: NSObject, ProducerListener {
    
    var producerId: String?
    
    func onTransportClose(_ producer: Producer!) {
        zmLog.info("Mediasoup::RoomManager--ProducerListener-onTransportClose")
    }
    
    deinit {
        zmLog.info("Mediasoup::RoomManager--ProducerListener-deinit")
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

    func onProduce(_ transport: Transport!, kind: String!, rtpParameters: String!, appData: String!, callback: ((String?) -> Void)!) {
        callback(self.delegate.onProduce(transport.getId(), kind: kind, rtpParameters: rtpParameters, appData: appData))
    }
    
    func onConnect(_ transport: Transport!, dtlsParameters: String!) {
        self.delegate.onConnect(transport.getId(), dtlsParameters: dtlsParameters)
    }
    
    func onConnectionStateChange(_ transport: Transport!, connectionState: String!) {
        zmLog.info("Mediasoup::onConnectionStateChange--PThread:\(Thread.current)")
        if self.isProduce {
            zmLog.info("Mediasoup::ProduceTransport-connectionState:\(String(describing: connectionState)) thread:\(Thread.current)")
        } else {
            zmLog.info("Mediasoup::RecvTransport-connectionState:\(String(describing: connectionState)) thread:\(Thread.current)")
        }
        if connectionState == "failed" {
            ///重启ICE
            zmLog.info("Mediasoup::Transport-onConnectionStateChange--restartIce isProduce:\(isProduce)  thread:\(Thread.current)")
            //transport.restartIce(<#T##iceParameters: String!##String!#>)
        }
    }
    
    deinit {
        zmLog.info("Mediasoup::RoomManager---MediasoupTransportListener--\(self.isProduce)-deinit")
    }
}

/// producer + deal
extension MediasoupRoomManager {
    
    func produceAudio() {
        guard self.sendTransport != nil,
            self.device!.canProduce("audio"),
            self.roomState != .none  else {
            return
        }

        let audioTrack: RTCAudioTrack = self.mediaOutputManager!.getAudioTrack()
        self.createProducer(track: audioTrack, codecOptions: nil, encodings: nil)
    }
    
    func produceVideo() {
        guard self.sendTransport != nil,
            self.device!.canProduce("video"),
            self.roomPeersManager?.getVideoTrack(with: self.userId!) == nil else {
                zmLog.info("Mediasoup::RoomManager--can not produceVideo")
                return
        }
       
        ///WebRTC-M79版本不支持这些参数
//        let codecOptions: JSON = [
//            "x-google-start-bitrate": 1000
//        ]
//        var encodings: Array = Array<RTCRtpEncodingParameters>.init()
//        encodings.append(RTCUtils.genRtpEncodingParameters(true, maxBitrateBps: 500000, minBitrateBps: 0, maxFramerate: 60, numTemporalLayers: 0, scaleResolutionDownBy: 0))
//        encodings.append(RTCUtils.genRtpEncodingParameters(true, maxBitrateBps: 1000000, minBitrateBps: 0, maxFramerate: 60, numTemporalLayers: 0, scaleResolutionDownBy: 0))
//        encodings.append(RTCUtils.genRtpEncodingParameters(true, maxBitrateBps: 1500000, minBitrateBps: 0, maxFramerate: 60, numTemporalLayers: 0, scaleResolutionDownBy: 0))
        
        let videoTrack = self.mediaOutputManager!.getVideoTrack(with: VideoOutputFormat(count: self.roomPeersManager?.totalVideoConsumersCount ?? 0))
        
        self.createProducer(track: videoTrack, codecOptions: nil, encodings: nil)
        ///将自己的track也放在管理类中
        self.roomPeersManager?.addSelfVideoTrack(userId: self.userId!, videoTrack: videoTrack)
    }
    
    private func createProducer(track: RTCMediaStreamTrack, codecOptions: String?, encodings: Array<RTCRtpEncodingParameters>?) {
        /** 需要注意：sendTransport!.produce 这个方法最好在一个线程里面同步的去执行
         *  webRTC 里面 peerConnection 的 各种状态设置不是线程安全的，并且当传入了错误的状态会报错，从而引起应用崩溃，所以这里一个一个的去创建produce
        */
        signalWorkQueue.async {
            guard let sendTransport = self.sendTransport else {
                return
            }
            let listener = MediasoupProducerListener()
            let producer: Producer = sendTransport.produce(listener, track: track, encodings: encodings, codecOptions: codecOptions)
            listener.producerId =  producer.getId()
            self.producers.append(producer)
            self.producerListeners.append(listener)
            
            zmLog.info("Mediasoup::RoomManager--createProducer id =" + producer.getId() + " kind =" + producer.getKind())
        }
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
        zmLog.info("Mediasoup::RoomManager--setLocalVideo--\(state)")
        signalWorkQueue.async {
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
                    self.producers = self.producers.filter({ return $0.getKind() != "video" })
                    self.producerListeners = self.producerListeners.filter({ return $0.producerId != videoProduce.getId() })
                    self.roomPeersManager?.removeSelfVideoTrack(userId: self.userId!)
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
            let peerUId = UUID(uuidString: peerId),
            let recvTransport = self.recvTransport else {
            return
        }
        if self.roomState != .peerConnected {
            self.roomState = .peerConnected
        }
        
        let kind: String = consumerInfo["kind"].stringValue
        let id: String = consumerInfo["id"].stringValue
        let producerId: String = consumerInfo["producerId"].stringValue
        let rtpParameters: JSON = consumerInfo["rtpParameters"]
        
        zmLog.info("Mediasoup::RoomManager-NewConsumer--peer:\(peerId)--kind:\(kind)---id:\(id)")
        
        let consumerListen = MediasoupConsumerListener(consumerId: id)
        let consumer: Consumer = recvTransport.consume(consumerListen, id: id, producerId: producerId, kind: kind, rtpParameters: rtpParameters.description)
        
        self.roomPeersManager?.addNewConsumer(with: peerUId, consumer: consumer, listener: consumerListen)
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
            self.roomPeersManager?.removeConsumer(with: consumerId)
        default: fatal("error")
        }
    }
    
}
