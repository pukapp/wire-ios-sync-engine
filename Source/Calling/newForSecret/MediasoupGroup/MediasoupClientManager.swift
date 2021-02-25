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

extension MediasoupClientManager {
    
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
            switch self.mode {
            case .conference:
                self.membersManagerDelegate.memberConnectStateChanged(with: pUid, state: .unconnected)
            default: self.removePeer(with: pUid)
            }
        case .peerDisplayNameChanged:
            break
        }
    }
    
}

enum MediasoupProduceKind {
    case audio
    case video
}
struct MediasoupProducer {
    
    let kind: MediasoupProduceKind
    private let producer: Producer
    private let listener: MediasoupProducerListener
    init(kind: MediasoupProduceKind, producer: Producer, listener: MediasoupProducerListener) {
        self.kind = kind
        self.producer = producer
        self.listener = listener
    }
    
    var id: String {
        return self.producer.getId()
    }
    
    func isPaused() -> Bool {
        return self.producer.isPaused()
    }
    
    func isClosed() -> Bool {
        return self.producer.isClosed()
    }
    
    func pause() {
        self.producer.pause()
    }
    
    func resume() {
        self.producer.resume()
    }
    
    func close() {
        self.producer.close()
    }
}

class MediasoupClientManager: CallingClientConnectProtocol {
    
    enum MediasoupConnectStep {
        case start
        case configureDevice
        case createTransport
        case loginRoom
        case produce
        
        case connectFailure
    }
    
    var mode: CallRoomType = .group
    
    private var device: MediasoupDevice?
    
    private let signalManager: CallingSignalManager
    private let mediaManager: MediaOutputManager
    let membersManagerDelegate: CallingMembersManagerProtocol
    private let mediaStateManagerDelegate: CallingMediaStateManagerProtocol
    let connectStateObserver: CallingClientConnectStateObserve
    
    private var mediaState: CallMediaType
    
    private var sendTransport: SendTransport?
    private var recvTransport: RecvTransport?
    private var sendTransportListen: MediasoupTransportListener?
    private var recvTransportListen: MediasoupTransportListener?
    
    private var producers: [MediasoupProducer] = []
    ///存储从服务端接收到的consumerJson数据，由于房间状态问题，暂不解析成consumer
    private var consumersJSONInfo: [JSON] = []
    private var peerConsumers: [MediasoupPeerConsumer] = []
    
    ///判断是否正在produce视频
    private var producingVideo: Bool {
        return self.producers.contains(where: { return $0.kind == .video })
    }
    private var connectStep: MediasoupConnectStep
    
    required init(signalManager: CallingSignalManager,
                  mediaManager: MediaOutputManager,
                  membersManagerDelegate: CallingMembersManagerProtocol,
                  mediaStateManagerDelegate: CallingMediaStateManagerProtocol,
                  observe: CallingClientConnectStateObserve,
                  isStarter: Bool,
                  mediaState: CallMediaType) {
        zmLog.info("MediasoupClientManager-init")
        
        //Logger.setLogLevel(LogLevel.TRACE)
        //Logger.setDefaultHandler()
        self.device = MediasoupDevice()
        
        self.signalManager = signalManager
        self.mediaManager = mediaManager
        self.membersManagerDelegate = membersManagerDelegate
        self.mediaStateManagerDelegate = mediaStateManagerDelegate
        self.connectStateObserver = observe
        self.mediaState = mediaState
        self.connectStep = .start
    }
    
    deinit {
        zmLog.info("MediasoupClientManager -- deinit")
    }
    
    //如果按照正常顺序，应当是从上而下在一条线程中同步执行的
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
            if !self.mediaState.isMute {
                self.produceAudio()
            }
            if self.mediaState.needSendVideo {
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
        
        if self.sendTransport != nil {
            self.sendTransport?.close()
            self.sendTransport = nil
            self.sendTransportListen = nil
        }
        
        if self.recvTransport != nil {
            self.recvTransport?.close()
            self.recvTransport = nil
            self.recvTransportListen = nil
        }

        zmLog.info("Mediasoup::webSocketDisConnected")
        self.device = nil
    }
    
    func webSocketReceiveRequest(with method: String, info: JSON, completion: (Bool) -> Void) {
        guard let action = MediasoupSignalAction.ReceiveRequest(rawValue: method) else { return }
        zmLog.info("MediasoupClientManager-onReceiveRequest:action:\(action) queue: \(Thread.current)")
        switch action {
        case .newConsumer:
            //newConsumer这个request信令，必须要等transport创建了consumer之后才能回响应
            //否则会产生bug:https://mediasoup.discourse.group/t/create-server-side-consumers-with-paused-true/244
            self.handleNewConsumer(with: info)
            completion(true)
        }
    }
    
    func webSocketReceiveNewNotification(with noti: String, info: JSON) {
        guard noti != "producerScore", noti != "consumerScore" else { return }
        if let action = MeetingSignalAction.Notification(rawValue: noti), mode == .conference {
            self.onReceiveMeetingNotification(with: action, info: info)
        } else if let action = MediasoupSignalAction.Notification(rawValue: noti) {
            zmLog.info("MediasoupClientManager-onNewNotification:action:\(noti)，info:\(info)")
            self.onReceiveMediasoupNotification(with: action, info: info)
        }
    }
    
    func dispose() {
        zmLog.info("MediasoupClientManager-dispose")
        
        self.consumersJSONInfo.removeAll()
        self.peerConsumers.forEach({ $0.clear() })
        self.peerConsumers.removeAll()
        
        self.producers.forEach({ $0.close() })
        self.producers.removeAll()
        
        if self.sendTransport != nil {
            self.sendTransport?.close()
            self.sendTransport = nil
            self.sendTransportListen = nil
        }
        
        if self.recvTransport != nil {
            self.recvTransport?.close()
            self.recvTransport = nil
            self.recvTransportListen = nil
        }
        //Consumers必须在transport之后释放，因为transport释放了之后会去通知consumerListener，去释放consumers
        self.peerConsumers.removeAll()
        zmLog.info("Mediasoup::dispose")
        self.device = nil
    }
    
    func configureDevice() {
        if self.device == nil {
            self.device = MediasoupDevice()
        }
        if !self.device!.isLoaded() {
            guard let rtpCapabilities = self.signalManager.requestToGetRoomRtpCapabilities() else {
                self.changeMediasoupConnectStep(.connectFailure)
                return
            }
            self.device?.load(rtpCapabilities)
            zmLog.info("MediasoupClientManager-configureDevice--rtpCapabilities--PThread:\(Thread.current)")
            self.changeMediasoupConnectStep(.createTransport)
        }
    }
    
    ///创建transport
    private func createWebRtcTransports() {
        zmLog.info("MediasoupClientManager-createWebRtcTransports--PThread:\(Thread.current)")
        guard let consumerTransportJson = signalManager.createWebRtcTransportRequest(with: false) else {
            self.changeMediasoupConnectStep(.connectFailure)
            return
        }
        self.processWebRtcTransport(with: false, webRtcTransportData: consumerTransportJson)
        
        guard let produceTransportJson = signalManager.createWebRtcTransportRequest(with: true) else {
            self.changeMediasoupConnectStep(.connectFailure)
            return
        }
        self.processWebRtcTransport(with: true, webRtcTransportData: produceTransportJson)
        self.changeMediasoupConnectStep(.loginRoom)
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
        guard let result = self.signalManager.loginRoom(with: self.device!.getRtpCapabilities(), mediaState: self.mediaState) else {
            zmLog.info("MediasoupClientManager-loginRoom--error Result")
            self.changeMediasoupConnectStep(.connectFailure)
            return
        }
        if let peers = result["peers"].array, peers.count > 0 {
            for info in peers {
                self.receiveNewPeer(peerInfo: info)
            }
        }
        self.changeMediasoupConnectStep(.produce)
    }
    
    func produceAudio() {
        guard self.sendTransport != nil,
            self.device!.canProduce("audio") else {
            return
        }

        let audioTrack: RTCAudioTrack = self.mediaManager.produceAudioTrack()
        self.createProducer(kind: .audio, track: audioTrack, codecOptions: nil, encodings: nil)
    }
        
    func produceVideo() {
        guard self.sendTransport != nil,
            self.device!.canProduce("video"),
            !self.producingVideo else {
                zmLog.info("MediasoupClientManager-can not produceVideo")
                return
        }
        if TARGET_OS_SIMULATOR == 1 { return }
        let videoTrack = self.mediaManager.produceVideoTrack(with: VideoOutputFormat(count: self.mediaStateManagerDelegate.totalVideoTracksCount))
        videoTrack.isEnabled = true
        self.createProducer(kind: .video, track: videoTrack, codecOptions: nil, encodings: nil)
    }
    
    private func createProducer(kind: MediasoupProduceKind, track: RTCMediaStreamTrack, codecOptions: String?, encodings: Array<RTCRtpEncodingParameters>?) {
        /** 需要注意：sendTransport!.produce 这个方法最好在一个线程里面同步的去执行,并且需要和关闭peerConnection在同一线程之内
         *  webRTC 里面 peerConnection 的 各种状态设置不是线程安全的，并且当传入了错误的状态会报错，从而引起应用崩溃，所以这里一个一个的去创建produce
        */
        let listener = MediasoupProducerListener()
        guard let sendTransport = self.sendTransport else {
            return
        }
        //#Warning 此方法会堵塞线程，等待代理方法onProduce获得produceId回调才继续,所以千万不能在socket的接收线程中调用，会形成死循环
        let producer: Producer = sendTransport.produce(listener, track: track, encodings: encodings, codecOptions: codecOptions)
        listener.producerId =  producer.getId()
        self.producers.append(MediasoupProducer(kind: kind, producer: producer, listener: listener))
        
        zmLog.info("MediasoupClientManager-createProducer id =" + producer.getId() + " kind =\(kind)")
    }
      
    func muteOther(_ userId: String, isMute: Bool) {
        self.signalManager.muteOther(userId, isMute: isMute)
    }

    func setLocalAudio(mute: Bool) {
        self.mediaState.audioMuted(mute)
        if let audioProduce = self.producers.first(where: { return $0.kind == .audio }) {
            if mute {
                audioProduce.pause()
            } else {
                audioProduce.resume()
            }
            self.signalManager.setProduceState(with: audioProduce.id, pause: mute)
        } else {
            if !mute {
                self.produceAudio()
            }
        }
    }
    
    func setLocalVideo(state: VideoState) {
        zmLog.info("MediasoupClientManager-setLocalVideo--\(state)-thread:\(Thread.current)")
        self.mediaState.videoStateChanged(state)
        switch state {
        case .started:
            if let videoProduce = self.producers.first(where: { return $0.kind == .video }), videoProduce.isPaused() {
                videoProduce.resume()
                self.signalManager.setProduceState(with: videoProduce.id, pause: false)
            } else {
                self.produceVideo()
            }
        case .stopped:
            if let videoProduce = self.producers.first(where: { return $0.kind == .video }) {
                videoProduce.close()
                self.signalManager.closeProduce(with: videoProduce.id)
                self.producers = self.producers.filter({ return $0.kind != .video })
            }
        case .paused:
            if let videoProduce = self.producers.first(where: {return $0.kind == .video }), !videoProduce.isPaused() {
                videoProduce.pause()
                self.signalManager.setProduceState(with: videoProduce.id, pause: true)
            }
        default:
            break;
        }
    }
    
    func setScreenShare(isStart: Bool) {
        zmLog.info("MediasoupClientManager-setScreenShare--\(isStart)")
        if isStart {
            self.mediaManager.startRecording()
            if !self.producingVideo {
                //还没有创建视频track的话，得先创建视频track
                self.produceVideo()
            }
        } else {
            if !self.mediaState.needSendVideo {
                self.setLocalVideo(state: .stopped)
            }
            self.mediaManager.stopRecording()
            
        }
    }
    
    private var temp: [String: UUID] = [:]
    
    func receiveNewPeer(peerInfo: JSON) {
        zmLog.info("MediasoupClientManager--receiveNewPeer \(peerInfo)")
        guard let peerId = peerInfo["id"].string,
            let audioState = peerInfo["audioStatus"].int,
            let videoStatus = peerInfo["videoStatus"].int else {
            return
        }
        var uid: UUID! = UUID(uuidString: peerId)
        if uid == nil {
            uid = UUID()
            temp[peerId] = uid
        }
        var member: CallMemberProtocol
        switch self.mode {
        case .conference:
            //会议中，由于成员已经在列表之中，所以只需要设置一下音频的状态即可
            self.membersManagerDelegate.setMemberAudio(audioState != 1, mid: uid)
            self.membersManagerDelegate.memberConnectStateChanged(with: uid, state: .connecting)
        case .group, .oneToOne:
            member = ConversationCallMember(userId: uid, callParticipantState: .connecting, isMute: audioState != 1, videoState: (videoStatus != 1) ? .stopped : .started)
            self.membersManagerDelegate.addNewMember(member)
        }
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
    
    private var firstAudioConsumerDate: Date?

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
        
        let consumerListen = MediasoupConsumerListener(consumerId: id)
        consumerListen.delegate = consumerListen
        let consumer: Consumer = recvTransport.consume(consumerListen.delegate, id: id, producerId: producerId, kind: kind, rtpParameters: rtpParameters.description)
        
        zmLog.info("MediasoupClientManager-handleNewConsumer-end:peer:\(peerId),kind:\(kind)--\(Thread.current)")
        if let peer = self.peerConsumers.first(where: { return $0.peerId == peerUId }) {
            peer.addConsumer(consumer, listener: consumerListen)
        } else {
            let peer = MediasoupPeerConsumer(peerId: peerUId)
            peer.addConsumer(consumer, listener: consumerListen)
            self.peerConsumers.append(peer)
        }
        self.membersManagerDelegate.memberConnectStateChanged(with: peerUId, state: .connected)

        if kind == "video" {
            let videoTrack = consumer.getTrack() as! RTCVideoTrack
            self.mediaStateManagerDelegate.addVideoTrack(with: peerUId, videoTrack: videoTrack)
            self.membersManagerDelegate.setMemberVideo(.started, mid: peerUId)
        }
    }
    
    func handleConsumerState(with action: MediasoupSignalAction.Notification, consumerInfo: JSON) {
        guard let consumerId = consumerInfo["consumerId"].string,
            let peer = self.getPeer(with: consumerId),
            let consumer = peer.consumer(with: consumerId) else {
            return
        }
        
        switch (consumer.getKind(), action) {
        case ("audio", .consumerResumed):
            consumer.resume()
            self.membersManagerDelegate.setMemberAudio(false, mid: peer.peerId)
        case ("audio", .consumerPaused):
            consumer.pause()
            self.membersManagerDelegate.setMemberAudio(true, mid: peer.peerId)
        case ("audio", .consumerClosed):break
            //peer.removeConsumer(consumerId)
        case ("video", .consumerClosed):
            //peer.removeConsumer(consumerId)
            if consumer.getKind() == "video" {
                self.mediaStateManagerDelegate.removeVideoTrack(with: peer.peerId)
                self.membersManagerDelegate.setMemberVideo(.stopped, mid: peer.peerId)
            }
        default: break
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
    weak var delegate: ConsumerListener?
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
    
    func onProduce(_ transportId: String, kind: String, rtpParameters: String, appData: String) -> String? {
        guard let produceId = signalManager.produceWebRtcTransportRequest(with: transportId, kind: kind, rtpParameters: rtpParameters, appData: appData) else {
            self.changeMediasoupConnectStep(.connectFailure)
            return nil
        }
        zmLog.info("MediasoupClientManager-transport-onProduce====callBack-produceId:\(produceId)\n")
        return produceId
    }
    
    func onConnect(_ transportId: String, dtlsParameters: String, isProduce: Bool) {
        signalManager.connectWebRtcTransportRequest(with: transportId, dtlsParameters: dtlsParameters)
    }
    
    func onTransportConnectionStateChange(isProduce: Bool, connectionState: String) {
        
    }
}


protocol MediasoupTransportListenerDelegate {
    //触发请求
    func onProduce(_ transportId: String, kind: String, rtpParameters: String, appData: String) -> String?
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
        callback(self.delegate.onProduce(transport.getId(), kind: kind, rtpParameters: rtpParameters, appData: appData))
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

