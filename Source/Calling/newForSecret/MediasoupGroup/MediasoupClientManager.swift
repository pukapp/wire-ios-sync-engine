//
//  MediasoupClientManager.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/7/24.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import Mediasoupclient
import SwiftyJSON

private let zmLog = ZMSLog(tag: "calling")

extension MediasoupClientManager: CallingSignalManagerDelegate {
    
    func onReceiveRequest(with method: String, info: JSON) {
        guard let action = MediasoupSignalAction.ReceiveRequest(rawValue: method) else { return }
        zmLog.info("MediasoupClientManager-onReceiveRequest:action:\(action)")
        switch action {
        case .newConsumer:
            self.handleNewConsumer(with: info)
        }
    }
    
    func onNewNotification(with noti: String, info: JSON) {
        guard let action = MediasoupSignalAction.Notification(rawValue: noti) else { return }
        zmLog.info("MediasoupClientManager-onNewNotification:action:\(action)")
        switch action {
        case .consumerPaused, .consumerResumed, .consumerClosed:
            self.handleConsumerState(with: action, consumerInfo: info)
        case .peerClosed:
            guard let peerId = info["peerId"].string,
                let pUid = UUID(uuidString: peerId) else {
                return
            }
            self.membersManagerDelegate.memberDisConnect(with: pUid)
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

class MediasoupClientManager: CallingClientConnectProtocol {
    
    private var device: MPDevice?
    
    private let signalManager: CallingSignalManager
    private let mediaManager: MediaOutputManager
    private let membersManagerDelegate: CallingMembersManagerProtocol
    private let mediaStateManagerDelegate: CallingMediaStateManagerProtocol
    private let connectStateObserver: CallingClientConnectStateObserve
    
    var videoState: VideoState = .stopped
    
    private var sendTransport: SendTransport?
    private var recvTransport: RecvTransport?
    private var sendTransportListen: MediasoupTransportListener?
    private var recvTransportListen: MediasoupTransportListener?
    
    private var producers: [Producer] = []
    private var producerListeners: [MediasoupProducerListener] = []
    ///存储从服务端接收到的consumerJson数据，由于房间状态问题，暂不解析成consumer
    private var consumersJSONInfo: [JSON] = []
    private var peerConsumers: [MediasoupPeerConsumer] = []
    
    ///判断是否正在produce视频
    private var producingVideo: Bool = false
    
    required init(signalManager: CallingSignalManager, mediaManager: MediaOutputManager, membersManagerDelegate: CallingMembersManagerProtocol, mediaStateManagerDelegate: CallingMediaStateManagerProtocol, observe: CallingClientConnectStateObserve, isStarter: Bool, videoState: VideoState) {
        zmLog.info("MediasoupClientManager-init")
        
        Mediasoupclient.initializePC()
        Logger.setLogLevel(LogLevel.TRACE)
        self.device = MPDevice()
        
        self.signalManager = signalManager
        self.mediaManager = mediaManager
        self.membersManagerDelegate = membersManagerDelegate
        self.mediaStateManagerDelegate = mediaStateManagerDelegate
        self.connectStateObserver = observe
        self.videoState = videoState
    }
    
    func startConnect() {
        zmLog.info("MediasoupClientManager-startConnect")
        if self.recvTransport != nil { return }
        self.configureDevice()
    }
    
    func dispose() {
        zmLog.info("MediasoupClientManager-dispose")
        
        self.consumersJSONInfo.removeAll()
        self.peerConsumers.forEach({ $0.clear() })
        self.peerConsumers.removeAll()
        
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

        zmLog.info("Mediasoup::dispose")
        self.device = nil
    }
    
    func configureDevice() {
        if !self.device!.isLoaded() {
            guard let rtpCapabilities = self.signalManager.requestToGetRoomRtpCapabilities() else {
                return
            }
            self.device!.load(rtpCapabilities)
        }
        zmLog.info("MediasoupClientManager-configureDevice--rtpCapabilities:\(String(describing: self.device!.getRtpCapabilities()))")
        self.createWebRtcTransports()
    }
    
    ///创建transport
    private func createWebRtcTransports() {
        zmLog.info("MediasoupClientManager-createWebRtcTransports--PThread:\(Thread.current)")
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
        if self.videoState == .started {
            self.produceVideo()
        }
        ///处理已经接收到的consumer
        self.handleRetainedConsumers()
    }
    
     func produceAudio() {
            guard self.sendTransport != nil,
                self.device!.canProduce("audio") else {
                return
            }

        let audioTrack: RTCAudioTrack = self.mediaManager.produceAudioTrack()
        self.createProducer(track: audioTrack, codecOptions: nil, encodings: nil)
    }
        
    func produceVideo() {
        guard self.sendTransport != nil,
            self.device!.canProduce("video"),
            !self.producingVideo else {
                zmLog.info("MediasoupClientManager-can not produceVideo")
                return
        }
        
//        ///WebRTC-M79版本不支持这些参数
//        let codecOptions: JSON = [
//            "x-google-start-bitrate": 1000
//        ]
//        var encodings: Array = Array<RTCRtpEncodingParameters>.init()
//        encodings.append(RTCUtils.genRtpEncodingParameters(true, maxBitrateBps: 500000, minBitrateBps: 0, maxFramerate: 60, numTemporalLayers: 0, scaleResolutionDownBy: 0))
//        encodings.append(RTCUtils.genRtpEncodingParameters(true, maxBitrateBps: 1000000, minBitrateBps: 0, maxFramerate: 60, numTemporalLayers: 0, scaleResolutionDownBy: 0))
//        encodings.append(RTCUtils.genRtpEncodingParameters(true, maxBitrateBps: 1500000, minBitrateBps: 0, maxFramerate: 60, numTemporalLayers: 0, scaleResolutionDownBy: 0))
//
        let videoTrack = self.mediaManager.produceVideoTrack(with: VideoOutputFormat(count: self.mediaStateManagerDelegate.totalVideoTracksCount))
        videoTrack.isEnabled = true
        self.createProducer(track: videoTrack, codecOptions: nil, encodings: nil)
        ///将自己的track也放在管理类中
        self.producingVideo = true
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
            
            zmLog.info("MediasoupClientManager-createProducer id =" + producer.getId() + " kind =" + producer.getKind())
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
        zmLog.info("MediasoupClientManager-setLocalVideo--\(state)-thread:\(Thread.current)")
        signalWorkQueue.async {
            switch state {
            case .started:
                if let videoProduce = self.producers.first(where: { return $0.getKind() == "video" }), videoProduce.isPaused() {
                    videoProduce.resume()
                    self.signalManager.setProduceState(with: videoProduce.getId(), pause: false)
                } else {
                    self.produceVideo()
                }
            case .stopped:
                if let videoProduce = self.producers.first(where: { return $0.getKind() == "video" }), !videoProduce.isClosed() {
                    videoProduce.close()
                    self.signalManager.closeProduce(with: videoProduce.getId())
                    self.producers = self.producers.filter({ return $0.getKind() != "video" })
                    self.producerListeners = self.producerListeners.filter({ return $0.producerId != videoProduce.getId() })
                    self.producingVideo = false
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
    
    func receiveNewPeer(peerInfo: JSON) {
        guard let peerId = peerInfo["id"].string,
            let uid = UUID(uuidString: peerId) else {
            return
        }
        self.membersManagerDelegate.addNewMember(with: uid, hasVideo: false)
    }
    
    func removePeer(with id: UUID) {
        ///接收end消息时会调用，所以需要放在此线程中
        signalWorkQueue.async {
            self.membersManagerDelegate.removeMember(with: id)
        }
    }
    
    func handleRetainedConsumers() {
        if self.consumersJSONInfo.count > 0 {
            for info in self.consumersJSONInfo {
                self.handleNewConsumer(with: info)
            }
            self.consumersJSONInfo.removeAll()
        }
    }

    func handleNewConsumer(with consumerInfo: JSON) {
        guard self.recvTransport != nil else {
            self.consumersJSONInfo.append(consumerInfo)
            return
        }
        
        guard let peerId = consumerInfo["appData"]["peerId"].string,
            let peerUId = UUID(uuidString: peerId),
            let recvTransport = self.recvTransport else {
            return
        }
        
        let kind: String = consumerInfo["kind"].stringValue
        let id: String = consumerInfo["id"].stringValue
        let producerId: String = consumerInfo["producerId"].stringValue
        let rtpParameters: JSON = consumerInfo["rtpParameters"]
        
        zmLog.info("MediasoupClientManager-handleNewConsumer--peer:\(peerId)--kind:\(kind)---id:\(id)")
        
        let consumerListen = MediasoupConsumerListener(consumerId: id)
        let consumer: Consumer = recvTransport.consume(consumerListen, id: id, producerId: producerId, kind: kind, rtpParameters: rtpParameters.description)
        
        if let peer = self.peerConsumers.first(where: { return $0.peerId == peerUId }) {
            peer.addConsumer(consumer, listener: consumerListen)
        } else {
            let peer = MediasoupPeerConsumer(peerId: peerUId)
            peer.addConsumer(consumer, listener: consumerListen)
            self.peerConsumers.append(peer)
        }
        
        self.membersManagerDelegate.memberConnected(with: peerUId)
        if kind == "video" {
            self.mediaStateManagerDelegate.addVideoTrack(with: peerUId, videoTrack: consumer.getTrack() as! RTCVideoTrack)
            self.membersManagerDelegate.setMemberVideo(.started, mid: peerUId)
        }
    }
    
    func handleConsumerState(with action: MediasoupSignalAction.Notification, consumerInfo: JSON) {
        guard let consumerId = consumerInfo["consumerId"].string,
            let peer = self.getPeer(with: consumerId),
            let consumer = peer.consumer(with: consumerId) else {
            return
        }
        
        switch action {
        case .consumerResumed:
            consumer.resume()
        case .consumerPaused:
            consumer.pause()
        case .consumerClosed:
            peer.removeConsumer(consumerId)
            if consumer.getKind() == "video" {
                self.mediaStateManagerDelegate.removeVideoTrack(with: peer.peerId)
                self.membersManagerDelegate.setMemberVideo(.stopped, mid: peer.peerId)
            }
        default: fatal("error")
        }
    }
}

extension MediasoupClientManager {
    
    func getPeer(with consumerId: String) -> MediasoupPeerConsumer? {
        return self.peerConsumers.first(where: { return ($0.consumer(with: consumerId) != nil) })
    }
    
}

class MediasoupConsumerListener: NSObject, ConsumerListener {
    
    let consumerId: String
    
    init(consumerId: String) {
        self.consumerId = consumerId
    }
    
    func onTransportClose(_ consumer: Consumer!) {
        zmLog.info("MediasoupClientManager-ConsumerListener-onTransportClose")
    }
    
    deinit {
        zmLog.info("MediasoupClientManager-ConsumerListener-deinit")
    }
}

class MediasoupProducerListener: NSObject, ProducerListener {
    
    var producerId: String?
    
    func onTransportClose(_ producer: Producer!) {
        zmLog.info("MediasoupClientManager-ProducerListener-onTransportClose")
    }
    
    deinit {
        zmLog.info("MediasoupClientManager-ProducerListener-deinit")
    }
}

extension MediasoupClientManager: MediasoupTransportListenerDelegate {
    
    func onProduce(_ transportId: String, kind: String, rtpParameters: String, appData: String) -> String {
        zmLog.info("MediasoupClientManager-onProduce====kind:\(kind)\n")
        guard let produceId = signalManager.produceWebRtcTransportRequest(with: transportId, kind: kind, rtpParameters: rtpParameters, appData: appData) else {
            //fatal("Mediasoup::onProduce:getProduceId-Error")
            return ""
        }
        zmLog.info("MediasoupClientManager-onProduce====id:\(produceId)\n")
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
        zmLog.info("MediasoupClientManager-onConnectionStateChange--PThread:\(Thread.current)")
        if self.isProduce {
            zmLog.info("MediasoupClientManager-ProduceTransport-connectionState:\(String(describing: connectionState)) thread:\(Thread.current)")
        } else {
            zmLog.info("MediasoupClientManager-RecvTransport-connectionState:\(String(describing: connectionState)) thread:\(Thread.current)")
        }
        if connectionState == "failed" {
            ///重启ICE
            zmLog.info("MediasoupClientManager-Transport-onConnectionStateChange--restartIce isProduce:\(isProduce)  thread:\(Thread.current)")
            //transport.restartIce(<#T##iceParameters: String!##String!#>)
        }
    }
    
    deinit {
        zmLog.info("MediasoupClientManager-MediasoupTransportListener--\(self.isProduce)-deinit")
    }
}

