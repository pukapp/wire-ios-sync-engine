//
//  WebRTCClientManager.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/6/30.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import WebRTC
import SwiftyJSON

private let zmLog = ZMSLog(tag: "calling")

extension CallingConfigure {
    //将服务器返回的json数据转成[RTCIceServer]
    func transIceServer(with json: JSON) -> RTCIceServer? {
        if let urls = json["urls"].arrayObject as? [String] {
            return RTCIceServer(urlStrings: urls, username: json["username"].string, credential: json["credential"].string)
        }
        return nil
    }
    
    var rtcIceServers: [RTCIceServer] {
        return self.iceServers.compactMap({ return transIceServer(with: $0) })
    }
    
}

private extension CallingMembersManager {
    //由于成员已经提前被加入到CallingMembersManager中，所以可以直接强制取
    var p2pMemberId: UUID {
        return self.callMembers.first!.remoteId
    }
}

class WebRTCClientManager: NSObject, CallingClientConnectProtocol {
    
    private var peerId: UUID {
        return (self.membersManagerDelegate as! CallingMembersManager).p2pMemberId
    }
    
    var callingConfigure: CallingConfigure!
    
    private let signalManager: CallingSignalManager
    private let mediaManager: MediaOutputManager
    private let membersManagerDelegate: CallingMembersManagerProtocol
    private let mediaStateManagerDelegate: CallingMediaStateManagerProtocol
    private let connectStateObserver: CallingClientConnectStateObserve
    
    private let connectRole: ConnectRole
    private let mediaState: CallMediaType
    // The `RTCPeerConnectionFactory` is in charge of creating new RTCPeerConnection instances.
    // A new RTCPeerConnection should be created every new call, but the factory is shared.
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
    
    private var peerConnection: RTCPeerConnection?
    private let mediaConstrains = [kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                                   kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueTrue,
                                   kRTCMediaConstraintsIceRestart: kRTCMediaConstraintsValueTrue]
    
    private static let MEDIA_STREAM_ID: String = "ARDAMS"
    private var localAudioTrack: RTCAudioTrack?
    private var localVideoTrack: RTCVideoTrack?
    
    //当前角色
    private enum ConnectRole {
        case offer //发起方
        case answer //接收方
    }
    //连接状态
    private enum ConnectState {
        case waitForPeerReady
        case peerIsReady
        case startICE
        case connectd
        case disconnected
        case faild
        case close
        case end
    }
    
    private var connectState: ConnectState = .waitForPeerReady
    private var timer: ZMTimer?
    private var getStatstimer: Timer?
    
    required init(signalManager: CallingSignalManager,
                  mediaManager: MediaOutputManager,
                  membersManagerDelegate: CallingMembersManagerProtocol,
                  mediaStateManagerDelegate: CallingMediaStateManagerProtocol,
                  observe: CallingClientConnectStateObserve,
                  isStarter: Bool,
                  mediaState: CallMediaType) {
        self.signalManager = signalManager
        self.mediaManager = mediaManager
        self.membersManagerDelegate = membersManagerDelegate
        self.mediaStateManagerDelegate = mediaStateManagerDelegate
        self.connectStateObserver = observe
        self.connectRole = isStarter ? .offer : .answer
        
        self.mediaState = mediaState
        super.init()
    }
    
    deinit {
        zmLog.info("WebRTCClientManager -- deinit")
    }
    
    func webSocketConnected() {
        guard self.connectState == .waitForPeerReady, self.peerConnection == nil else { return }
        self.requestToSwitchToP2PMode(completion: { isSuccess in
            
        })
        zmLog.info("WebRTCClientManager: startConnect")
        
        if self.connectRole == .offer {
            self.signalManager.requestToJudgeIsPeerAlreadyInRoom { (isInRoom) in
                if isInRoom {
                    self.changeConnectState(.peerIsReady)
                    self.offer()
                }
            }
        }
    }
    
    func webSocketDisConnected() {
        zmLog.info("WebRTCClientManager: disConnected")
        self.peerConnection?.close()
    }
    
    func webSocketReceiveRequest(with method: String, info: JSON, completion: (Bool) -> Void) {
        self.handleSocketForwardMessage(with: method, info: info)
        completion(true)
    }
    
    func webSocketReceiveNewNotification(with noti: String, info: JSON) {
        self.handleSocketNewNotification(with: noti, info: info)
    }
    
    func createPeerConnection() {
        guard self.peerConnection == nil else { return }
        zmLog.info("WebRTCClientManager: createPeerConnection")

        let config = RTCConfiguration()
        config.iceServers = callingConfigure.rtcIceServers
        config.candidateNetworkPolicy = .all
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil,
                                              optionalConstraints: ["DtlsSrtpKeyAgreement":kRTCMediaConstraintsValueTrue])
        self.peerConnection = WebRTCClientManager.factory.peerConnection(with: config, constraints: constraints, delegate: self)
    }
    
    func produceAudio() {
        guard self.localAudioTrack == nil else { return }
        self.localAudioTrack = self.mediaManager.produceAudioTrack()
        self.peerConnection?.add(self.localAudioTrack!, streamIds: [WebRTCClientManager.MEDIA_STREAM_ID])
    }
    
    func produceVideo(isEnabled: Bool) {
        if TARGET_OS_SIMULATOR == 1 {
            return
        }
        guard self.localVideoTrack == nil else { return }
        self.localVideoTrack = self.mediaManager.produceVideoTrack(with: .high)
        self.peerConnection?.add(self.localVideoTrack!, streamIds: [WebRTCClientManager.MEDIA_STREAM_ID])
        self.localVideoTrack?.isEnabled = isEnabled
    }
    
    func setLocalAudio(mute: Bool) {
        self.localAudioTrack?.isEnabled = !mute
    }
    
    func setLocalVideo(state: VideoState) {
        switch state {
        case .started:
            self.localVideoTrack?.isEnabled = true
        case .stopped:
            self.localVideoTrack?.isEnabled = false
        case .paused:
            self.localVideoTrack?.isEnabled = false
        case .screenSharing, .badConnection:
            break
        }
        self.forwardP2PMessage(.videoState(state))
    }
    
    func setScreenShare(isStart: Bool) {
        // no-op
    }
    
    func muteOther(_ userId: String, isMute: Bool) {
        // no-op
    }
    
    func dispose() {
        zmLog.info("WebRTCClientManager: dispose")
        self.timer?.cancel()
        self.timer = nil
        //self.peerConnection?.delegate = nil
        self.peerConnection?.close()
//        self.localAudioTrack = nil
//        self.localVideoTrack = nil
        self.peerConnection = nil
    }
    
}

// MARK: Signaling
extension WebRTCClientManager {
    
    func offer() {
        self.changeConnectState(.startICE)
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains,
                                             optionalConstraints: nil)
        self.peerConnection?.offer(for: constrains) { (sdp, error) in
            guard let sdp = sdp else {
                zmLog.info("WebRTCClientManager: offer error:\(String(describing: error))")
                return
            }
            
            self.peerConnection?.setLocalDescription(sdp, completionHandler: { (error) in
                guard error == nil else {
                    zmLog.info("WebRTCClientManager: setLocalDescription error:\(String(describing: error))")
                    return
                }
                let sdp = SessionDescription(from: sdp)
                self.forwardP2PMessage(.sdp(sdp))
            })
        }
    }
    
    private func answer()  {
        self.changeConnectState(.startICE)
        let constrains = RTCMediaConstraints(mandatoryConstraints: self.mediaConstrains,
                                             optionalConstraints: nil)
        self.peerConnection?.answer(for: constrains) { (sdp, error) in
            guard let sdp = sdp else {
                zmLog.info("WebRTCClientManager: answer error:\(String(describing: error))")
                return
            }
            self.peerConnection?.setLocalDescription(sdp, completionHandler: { (error) in
                guard error == nil else {
                    zmLog.info("WebRTCClientManager: setLocalDescription error:\(String(describing: error))")
                    return
                }
                let sdp = SessionDescription(from: sdp)
                self.forwardP2PMessage(.sdp(sdp))
            })
        }
    }
    
    private func set(remoteSdp: RTCSessionDescription) {
        self.peerConnection?.setRemoteDescription(remoteSdp, completionHandler: { (error) in
            guard error == nil else {
                zmLog.info("WebRTCClientManager: setRemoteSdp error:\(String(describing: error))")
                return
            }
        })
    }
    
    private func set(remoteCandidate: RTCIceCandidate) {
        self.peerConnection?.add(remoteCandidate)
    }
    
}

extension WebRTCClientManager: ZMTimerClient {
    
    private func changeConnectState(_ currentState: ConnectState) {
        switch currentState {
        case .waitForPeerReady:
            fatal("这只是初始状态")
        case .peerIsReady:
            self.createPeerConnection()
            //由于双方交换sdp的时候就必须包含有是否开启音频或者视频，所以为了能从语音切换到视频，此处先创建视频的track，但是设置enable为false，当开关视频的时候，通过enable的设置
            self.produceAudio()
            self.produceVideo(isEnabled: self.mediaState.needSendVideo)
        case .startICE:
            //打洞仅给30s时间，不成功则直接走mediasoup
            self.invalidTimer()
            self.timer = ZMTimer(target: self)
            self.timer!.fire(afterTimeInterval: 30)
        case .connectd:
            self.invalidTimer()
            self.membersManagerDelegate.memberConnectStateChanged(with: self.peerId, state: .connected)
            //建立连接成功了之后才发消息通知对方自己的视频状态，来让对方更新界面
            self.forwardP2PMessage(.videoState(self.mediaState.needSendVideo ? .started : .stopped))
        case .disconnected:
            self.membersManagerDelegate.memberConnectStateChanged(with: self.peerId, state: .connecting)
        case .faild:
            self.membersManagerDelegate.memberConnectStateChanged(with: self.peerId, state: .connecting)
            guard self.connectState != .disconnected else {
                //只要connectState不是从disconnected变成failed，就认为该用户没有ice穿透的可能性，直接走失败处理方法
                self.establishConnectionFailed()
                return
            }
            if self.connectRole == .offer {
                zmLog.info("RTCPeerConnectionDelegate restart ICE")
                self.offer()
            } else {
                self.changeConnectState(.startICE)
                self.forwardP2PMessage(.restart)
            }
        case .close:
            self.establishConnectionFailed()
        case .end:
            self.invalidTimer()
            self.dispose()
            self.membersManagerDelegate.removeMember(with: self.peerId)
        }
        self.connectState = currentState
    }
    
    func establishConnectionFailed() {
        self.peerConnection?.statistics(completionHandler: { (report) in
            zmLog.info("webrtc: report--111\(report.statistics)")
        })
        self.invalidTimer()
        self.requestToSwitchToChatMode(completion: { isSuccess in
            
        })
        self.forwardP2PMessage(.switchMode(.chat))
        //断开连接之后需要将视频重置
        self.membersManagerDelegate.setMemberVideo(.stopped, mid: self.peerId)
        self.connectStateObserver.establishConnectionFailed()
    }
     
    //定时器目前只用来计算从开启p2p穿透之后30内能否连接成功，不能连接成功就回调状态，并切换mediasoup模式
    func timerDidFire(_ timer: ZMTimer!) {
        zmLog.info("WebRTCClientManager timerDidFire 连接超时了")
        self.establishConnectionFailed()
    }
    
    private func invalidTimer() {
        guard self.timer != nil else { return }
        zmLog.info("WebRTCClientManager invalidTimer")
        self.timer?.cancel()
        self.timer = nil
    }

}

extension WebRTCClientManager: RTCPeerConnectionDelegate {
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        zmLog.info("RTCPeerConnectionDelegate new signaling state: \(stateChanged)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        zmLog.info("RTCPeerConnectionDelegate did add stream--\(stream)")
        if let remoteTrack = stream.videoTracks.first {
            zmLog.info("RTCPeerConnectionDelegate didReceiveVideoTrack--\(remoteTrack.isEnabled)")
            self.mediaStateManagerDelegate.addVideoTrack(with: self.peerId, videoTrack: remoteTrack)
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        zmLog.info("RTCPeerConnectionDelegate did remote stream")
    }
    
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        zmLog.info("RTCPeerConnectionDelegate should negotiate")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        zmLog.info("RTCPeerConnectionDelegate new connection state: \(newState)")
        if newState == .connected {
            self.changeConnectState(.connectd)
        } else if newState == .disconnected {
            self.changeConnectState(.disconnected)
        } else if newState == .failed {
            self.changeConnectState(.faild)
        }
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        zmLog.info("RTCPeerConnectionDelegate new gathering state: \(newState)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        if candidate.sdp.contains("tcp") { return }
        zmLog.info("RTCPeerConnectionDelegate didGenerate candidate: \(candidate.sdp)")
        self.forwardP2PMessage(.candidate(IceCandidate(from: candidate)))
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        zmLog.info("RTCPeerConnectionDelegate did remove candidate(s)")
    }
    
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        zmLog.info("RTCPeerConnectionDelegate did open data channel")
    }
    
}


extension WebRTCClientManager {
    
    private func requestToSwitchToP2PMode(completion: @escaping (Bool) -> Void) {
        self.signalManager.requestToSwitchRoomMode(to: .p2p, completion: completion)
    }
    
    private func requestToSwitchToChatMode(completion: @escaping (Bool) -> Void) {
        self.signalManager.requestToSwitchRoomMode(to: .chat, completion: completion)
    }
    
    private func forwardP2PMessage(_ message: WebRTCP2PMessage) {
        self.signalManager.forwardP2PMessage(to: self.peerId.transportString(), message: message)
    }
    
    func handleSDPMessage(_ message: WebRTCP2PMessage) {
        zmLog.info("WebRTCClientManager-handleSDPMessage message:\(message.json.count < 100 ? message.json : "sdp")")
        switch message {
        case .sdp(let sdp):
            switch sdp.type {
            case .offer:
                self.changeConnectState(.peerIsReady)
                self.set(remoteSdp: sdp.rtcSessionDescription)
                self.answer()
            case .answer:
                self.set(remoteSdp: sdp.rtcSessionDescription)
            }
        case .candidate(let candidate):
            self.set(remoteCandidate: candidate.rtcIceCandidate)
        case .videoState(let state):
            self.membersManagerDelegate.setMemberVideo(state, mid: self.peerId)
        case .switchMode:
            self.establishConnectionFailed()
        case .restart:
            if self.connectState != .startICE {
                self.offer()
            }
        }
    }
    
    func handleSocketForwardMessage(with method: String, info: JSON) {
        guard let action = WebRTCP2PSignalAction.ReceiveRequest(rawValue: method) else { return }
        zmLog.info("WebRTCClientManager-onReceiveRequest:action:\(action)")
        switch action {
        case .forward:
            let sdpMessage = WebRTCP2PMessage(json: info)
            self.handleSDPMessage(sdpMessage)
        }
    }
    
    func handleSocketNewNotification(with noti: String, info: JSON) {
        guard let action = WebRTCP2PSignalAction.Notification(rawValue: noti) else { return }
        zmLog.info("WebRTCClientManager-onNewNotification:action:\(action)")
        switch action {
        case .peerOpened:
            guard let peerId = info["peerId"].string, let peerUId = UUID(uuidString: peerId) else {
                zmLog.error("WebRTCClientManager- peerOpen: no peerId:\(info)")
                return
            }
            if self.peerId == peerUId {
                switch self.connectRole {
                case .offer:
                    self.changeConnectState(.peerIsReady)
                    self.offer()
                case .answer:
                    break;
                }
            } else {
                zmLog.error("WebRTCClientManager-peerOpen :wrong peerId:\(peerId)")
            }
        case .peerLeave:
            self.changeConnectState(.end)
        }
    }
    
}
