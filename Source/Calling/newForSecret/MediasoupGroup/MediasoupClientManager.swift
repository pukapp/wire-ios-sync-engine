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
        zmLog.info("MediasoupClientManager-onReceiveRequest:action:\(action) queue: \(Thread.current)")
        switch action {
        case .newConsumer:
            produceConsumerSerialQueue.async {
                self.handleNewConsumer(with: info)
            }
        }
    }
    
    func onNewNotification(with noti: String, info: JSON) {
        guard noti != "producerScore", noti != "consumerScore" else { return }
        zmLog.info("MediasoupClientManager-onNewNotification:action:\(noti)，info:\(info)")
        if let action = MeetingSignalAction.Notification(rawValue: noti) {
            self.onReceiveMeetingNotification(with: action, info: info)
        } else if let action = MediasoupSignalAction.Notification(rawValue: noti) {
            self.onReceiveMediasoupNotification(with: action, info: info)
        }
    }
    
    func onReceiveMediasoupNotification(with action: MediasoupSignalAction.Notification, info: JSON) {
        zmLog.info("MediasoupClientManager-onReceiveMediasoupNotification:action:\(action)")
        switch action {
        case .consumerPaused, .consumerResumed, .consumerClosed:
            self.handleConsumerState(with: action, consumerInfo: info)
        case .peerClosed:
            guard let peerId = info["peerId"].string,
                let pUid = UUID(uuidString: peerId) else {
                return
            }
            self.membersManagerDelegate.memberConnectStateChanged(with: pUid, state: .connecting)
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

//由于sendTransport!.produce这个方法会堵塞线程以及不能在两个线程分别创建produce和consumer，所以需要将他们单独放置在另外一个串行队列中去创建它们
private let produceConsumerSerialQueue: DispatchQueue = DispatchQueue.init(label: "produceConsumerSerialQueue")

class MediasoupClientManager: CallingClientConnectProtocol {
    
    enum MediasoupConnectStep {
        case start
        case configureDevice
        case createTransport
        case loginRoom
        case produce
        
        case connectFailure
    }
    
    private var device: MPDevice?
    
    private let signalManager: CallingSignalManager
    private let mediaManager: MediaOutputManager
    let membersManagerDelegate: CallingMembersManagerProtocol
    private let mediaStateManagerDelegate: CallingMediaStateManagerProtocol
    let connectStateObserver: CallingClientConnectStateObserve
    
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
    
    private var connectStep: MediasoupConnectStep
    
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
        self.connectStep = .start
    }
    
    func changeMediasoupConnectStep(_ step: MediasoupConnectStep) {
        switch step {
        case .start:
            break
        case .configureDevice:
            self.configureDevice()
        case .createTransport:
            self.createWebRtcTransports()
        case .loginRoom:
            self.loginRoom()
        case .produce:
            self.produceAudio()
            if self.videoState == .started {
                self.produceVideo()
            }
            self.handleRetainedConsumers()
        case .connectFailure:
            zmLog.info("MediasoupClientManager-changeMediasoupConnectStep--\(step)")
        }
    }
    
    func webSocketConnected() {
        zmLog.info("MediasoupClientManager-startConnect")
        guard self.recvTransport == nil else { return }
        self.changeMediasoupConnectStep(.configureDevice)
    }
    
    func webSocketDisConnected() {
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

        zmLog.info("Mediasoup::webSocketDisConnected")
        self.device = nil
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
        if self.device == nil {
            self.device = MPDevice()
        }
        if !self.device!.isLoaded() {
            self.signalManager.requestToGetRoomRtpCapabilities { (rtpCapabilities) in
                guard let rtpCapabilities = rtpCapabilities else {
                    self.changeMediasoupConnectStep(.connectFailure)
                    return
                }
                self.device?.load(rtpCapabilities)
                zmLog.info("MediasoupClientManager-configureDevice--rtpCapabilities:\(String(describing: self.device!.getRtpCapabilities()))")
                self.changeMediasoupConnectStep(.createTransport)
            }
        }
    }
    
    ///创建transport
    private func createWebRtcTransports() {
        zmLog.info("MediasoupClientManager-createWebRtcTransports--PThread:\(Thread.current)")
        signalManager.createWebRtcTransportRequest(with: false) { (recvJson) in
            guard let recvJson = recvJson else {
                self.changeMediasoupConnectStep(.connectFailure)
                return
            }
            self.processWebRtcTransport(with: false, webRtcTransportData: recvJson)
        }
        signalManager.createWebRtcTransportRequest(with: true) { (recvJson) in
            guard let recvJson = recvJson else {
                self.changeMediasoupConnectStep(.connectFailure)
                return
            }
            self.processWebRtcTransport(with: true, webRtcTransportData: recvJson)
            self.changeMediasoupConnectStep(.loginRoom)
        }
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
        zmLog.info("MediasoupClientManager-processWebRtcTransport--isProducing:\(isProducing)")
    }
    
    ///登录房间，并且获取房间内peer信息
    private func loginRoom() {
        self.signalManager.loginRoom(with: self.device!.getRtpCapabilities()) { (res) in
            guard let res = res else {
                return
            }
            if let peers = res["peers"].array, peers.count > 0 {
                for info in peers {
                    self.receiveNewPeer(peerInfo: info)
                }
            }
            self.changeMediasoupConnectStep(.produce)
        }
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
        if TARGET_OS_SIMULATOR == 1 {
            return
        }
        let videoTrack = self.mediaManager.produceVideoTrack(with: VideoOutputFormat(count: self.mediaStateManagerDelegate.totalVideoTracksCount))
        videoTrack.isEnabled = true
        self.createProducer(track: videoTrack, codecOptions: nil, encodings: nil)
        ///将自己的track也放在管理类中
        self.producingVideo = true
    }
    
    func startRecording() {
        guard self.sendTransport != nil else {
                zmLog.info("MediasoupClientManager-can not startRecording")
                return
        }
        let videoTrack = self.mediaManager.startRecording()
        videoTrack.isEnabled = true
        self.createProducer(track: videoTrack, codecOptions: nil, encodings: nil)
        
    }
    
    private func createProducer(track: RTCMediaStreamTrack, codecOptions: String?, encodings: Array<RTCRtpEncodingParameters>?) {
        /** 需要注意：sendTransport!.produce 这个方法最好在一个线程里面同步的去执行,并且需要和关闭peerConnection在同一线程之内
         *  webRTC 里面 peerConnection 的 各种状态设置不是线程安全的，并且当传入了错误的状态会报错，从而引起应用崩溃，所以这里一个一个的去创建produce
        */
        produceConsumerSerialQueue.async {
            let listener = MediasoupProducerListener()
            guard let sendTransport = self.sendTransport else {
                return
            }
            //#Warning 此方法会堵塞线程，等待代理方法onProduce获得produceId回调才继续,所以千万不能在socket的接收线程中调用，会形成死循环
            let producer: Producer = sendTransport.produce(listener, track: track, encodings: encodings, codecOptions: codecOptions)
            listener.producerId =  producer.getId()
            self.producers.append(producer)
            self.producerListeners.append(listener)
            
            zmLog.info("MediasoupClientManager-createProducer id =" + producer.getId() + " kind =" + producer.getKind())
        }
    }
        
    func setLocalAudio(mute: Bool) {
        if let audioProduce = self.producers.first(where: { return $0.getKind() == "audio" }) {
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
    
    private var temp: [String: UUID] = [:]
    
    func receiveNewPeer(peerInfo: JSON) {
        zmLog.info("MediasoupClientManager--receiveNewPeer \(peerInfo)")
        guard let peerId = peerInfo["id"].string else {
            return
        }
        var uid: UUID! = UUID(uuidString: peerId)
        if uid == nil {
            uid = UUID()
            temp[peerId] = uid
        }
        let member = AVSCallMember.init(userId: uid, callParticipantState: .connecting, isMute: false, videoState: .stopped)
        self.membersManagerDelegate.addNewMember(member)
    }
    
    func removePeer(with id: UUID) {
        self.membersManagerDelegate.removeMember(with: id)
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
        
        guard let recvTransport = self.recvTransport,
            let peerId = consumerInfo["appData"]["peerId"].string,
            let peerUId = UUID(uuidString: peerId) ?? temp[peerId] else {
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
        self.membersManagerDelegate.memberConnectStateChanged(with: peerUId, state: .connected)

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
            self.membersManagerDelegate.setMemberAudio(false, mid: peer.peerId)
        case .consumerPaused:
            consumer.pause()
            self.membersManagerDelegate.setMemberAudio(true, mid: peer.peerId)
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
    
    func onProduce(_ transportId: String, kind: String, rtpParameters: String, appData: String, callBack: @escaping (String?) -> Void) {
        signalManager.produceWebRtcTransportRequest(with: transportId, kind: kind, rtpParameters: rtpParameters, appData: appData) { (produceId) in
            guard let produceId = produceId else {
                self.changeMediasoupConnectStep(.connectFailure)
                return
            }
            zmLog.info("MediasoupClientManager-transport-onProduce====callBack-produceId:\(produceId)\n")
            callBack(produceId)
        }
    }
    
    func onConnect(_ transportId: String, dtlsParameters: String, isProduce: Bool) {
        signalManager.connectWebRtcTransportRequest(with: transportId, dtlsParameters: dtlsParameters)
    }
    
    func onTransportConnectionStateChange(isProduce: Bool, connectionState: String) {
        
    }
}


protocol MediasoupTransportListenerDelegate {
    //触发请求
    func onProduce(_ transportId: String, kind: String, rtpParameters: String, appData: String, callBack: @escaping (String?) -> Void)
    func onConnect(_ transportId: String, dtlsParameters: String, isProduce: Bool)
    //状态回调
    func onTransportConnectionStateChange(isProduce: Bool, connectionState: String)
}

class MediasoupTransportListener: NSObject, SendTransportListener, RecvTransportListener {
    
    private let isProduce: Bool
    private let delegate: MediasoupTransportListenerDelegate
    private var isConnected: Bool = false
    
    init(isProduce: Bool, delegate: MediasoupTransportListenerDelegate) {
        self.isProduce = isProduce
        self.delegate = delegate
        super.init()
    }

    func onProduce(_ transport: Transport!, kind: String!, rtpParameters: String!, appData: String!, callback: ((String?) -> Void)!) {
        zmLog.info("MediasoupClientManager-transportListener-onProduce====isProduce:\(isProduce) thread:\(Thread.current)")
        self.delegate.onProduce(transport.getId(), kind: kind, rtpParameters: rtpParameters, appData: appData, callBack: callback)
    }
    
    func onConnect(_ transport: Transport!, dtlsParameters: String!) {
        zmLog.info("MediasoupClientManager-transportListener-onConnect====isProduce:\(isProduce) thread:\(Thread.current)")
        self.delegate.onConnect(transport.getId(), dtlsParameters: dtlsParameters, isProduce: self.isProduce)
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

