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

extension CallingRoomManager: CallingSignalManagerDelegate {
    
    func socketConnected() {
        guard self.roomState == .socketConnecting else { return }
        self.roomState = .socketConnected
        self.roomConnected()
    }
    
    func socketDisconnected(needDestory: Bool) {
        if needDestory {
            self.roomState = .disonnected
            self.delegate?.onCallEnd(conversationId: self.roomId!, reason: .internalError)
        } else {
            self.roomState = .socketConnecting
            self.disConnectedRoom()
            //self.delegate?.onReconnectingCall(conversationId: self.roomId!)
        }
    }

    func onReceiveRequest(with method: String, info: JSON) {
        roomWorkQueue.async {
            self.clientConnectManager?.webSocketReceiveRequest(with: method, info: info)
        }
    }
    
    func onNewNotification(with noti: String, info: JSON) {
        roomWorkQueue.async {
            self.clientConnectManager?.webSocketReceiveNewNotification(with: noti, info: info)
        }
    }
    
}

protocol CallingRoomManagerDelegate {
    func onEstablishedCall(conversationId: UUID)
    func onReconnectingCall(conversationId: UUID)
    func onCallEnd(conversationId: UUID, reason: CallClosedReason)
    func onVideoStateChange(conversationId: UUID, memberId: UUID, videoState: VideoState)
    func onGroupMemberChange(conversationId: UUID, memberCount: Int)
    
    //仅为会议支持
    func onReceiveMeetingPropertyChange(in mid: UUID, with property: MeetingProperty)
}

///client连接管理，具体实现分别由继承类独自实现
protocol CallingClientConnectProtocol {
    init(signalManager: CallingSignalManager, mediaManager: MediaOutputManager, membersManagerDelegate: CallingMembersManagerProtocol, mediaStateManagerDelegate: CallingMediaStateManagerProtocol, observe: CallingClientConnectStateObserve, isStarter: Bool, mediaState: AVSCallMediaState)
    func webSocketConnected()
    func webSocketDisConnected()
    func webSocketReceiveRequest(with method: String, info: JSON)
    func webSocketReceiveNewNotification(with noti: String, info: JSON)
    func dispose()
    func setLocalAudio(mute: Bool)
    func setLocalVideo(state: VideoState)
    func setScreenShare(isStart: Bool)
    
    func muteOther(_ userId: String, isMute: Bool)
}
//client连接回调状态变化
protocol CallingClientConnectStateObserve {
    func establishConnectionFailed()
    //仅为会议支持
    func onReceivePropertyChange(with property: MeetingProperty)
}

/*
 * 由于关闭房间会有两种情况
 * 1.收到外部消息或主动调用，则关闭房间，释放资源
 * 2.收到socket信令，然后判断当前房间状态，为空，则释放资源
 * 由于目前im端消息的推送延迟问题，所以目前socket的peerLeave信令需要处理，im端的消息也需要处理，所以就会造成多个线程同时创建，或者同时释放的问题
 * 所以这需要是一条串行队列，否则会造成很多闪退bug
 * 目前，websocket的响应都是在此线程调用，用户的主动操作也都需要放在线程中操作
 */
let roomWorkQueue: DispatchQueue = DispatchQueue.init(label: "MediasoupSignalWorkQueue")

class CallingRoomManager: NSObject {
    
    enum RoomState {
        case none
        case socketConnecting
        case socketConnected
        case connected
        case disonnected
    }
    
    static let shareInstance: CallingRoomManager = CallingRoomManager()
    
    var callingConfigure: CallingConfigure?
    var delegate: CallingRoomManagerDelegate?
    
    var roomId: UUID?
    private var userId: UUID?
    private var mediaState: AVSCallMediaState = .none
    private var isStarter: Bool = false
    private var roomMode: AVSConversationType = .group
    private var roomState: RoomState = .none
    
    //房间信令的管理
    private var signalManager: CallingSignalManager!
    //房间连接具体实现管理类
    var clientConnectManager: CallingClientConnectProtocol?
    //房间内成员状态管理
    var roomMembersManager: CallingMembersManager?
    //本机音频和视频track的生产管理类
    var mediaOutputManager: MediaOutputManager?
    

    var isCalling: Bool {
        return (self.roomState != .none && self.roomState != .disonnected)
    }
    
    override init() {
        super.init()
        signalManager = CallingSignalManager(signalManagerDelegate: self)
    }
    
    func setCallingConfigure(_ callingConfigure: CallingConfigure) {
        self.callingConfigure = callingConfigure
    }
    
    func connectToRoom(with roomId: UUID, userId: UUID, roomMode: AVSConversationType, mediaState: AVSCallMediaState, isStarter: Bool, members: [CallMemberProtocol], token: String?) {
        roomWorkQueue.async {
            self.internalConnectToRoom(with: roomId, userId: userId, roomMode: roomMode, mediaState: mediaState, isStarter: isStarter, members: members, token: token)
        }
    }
    
    private func internalConnectToRoom(with roomId: UUID, userId: UUID, roomMode: AVSConversationType, mediaState: AVSCallMediaState, isStarter: Bool, members: [CallMemberProtocol], token: String?) {
        guard let callingConfigure = self.callingConfigure,
            let wsUrl = callingConfigure.vaildGateway,
            self.roomId == nil else {
            ///已经在房间里面了
            zmLog.info("CallingRoomManager-connectToRoom err:获取configuare出错，或者roomId不为空")
            return
        }
        
        zmLog.info("CallingRoomManager-connectToRoom roomId:\(roomId) userId:\(userId)")
        
        self.roomId = roomId
        self.userId = userId
        self.roomMode = roomMode
        self.mediaState = mediaState
        self.isStarter = isStarter
        self.roomState = .socketConnecting
        
        self.mediaOutputManager = MediaOutputManager()
        self.roomMembersManager = CallingMembersManager(observer: self)
        self.signalManager.connectRoom(with: wsUrl, roomId: roomId.transportString(), userId: self.userId!.transportString(), token: token)
        //成员管理
        members.forEach({
            self.roomMembersManager?.addNewMember($0)
        })
        switch roomMode {
        case .oneToOne:
            self.clientConnectManager = WebRTCClientManager(signalManager: self.signalManager, mediaManager: self.mediaOutputManager!, membersManagerDelegate: self.roomMembersManager!, mediaStateManagerDelegate: self.roomMembersManager!, observe: self, isStarter: self.isStarter, mediaState: self.mediaState)
            //获取穿透服务器地址
            (clientConnectManager as! WebRTCClientManager).callingConfigure = callingConfigure
        case .group, .conference:
            self.clientConnectManager = MediasoupClientManager(signalManager: self.signalManager, mediaManager: self.mediaOutputManager!, membersManagerDelegate: self.roomMembersManager!, mediaStateManagerDelegate: self.roomMembersManager!, observe: self, isStarter: self.isStarter, mediaState: self.mediaState)
            (clientConnectManager as! MediasoupClientManager).mode = roomMode
        }
    }
    
    private func roomConnected() {
        roomWorkQueue.async {
            self.roomState = .socketConnected
            self.clientConnectManager?.webSocketConnected()
        }
    }
    
    ///网络断开连接
    private func disConnectedRoom() {
        roomWorkQueue.async {
            zmLog.info("CallingRoomManager-disConnectedRoom--thread:\(Thread.current)")
            self.clientConnectManager?.webSocketDisConnected()
        }
    }
    
    func leaveRoom(with roomId: UUID) {
        /**需要先将线程解锁
          *当前在roomWorkQueue中，则说明当前无同步请求，线程没有被卡住
          *当前不在roomWorkQueue中，则不论roomWorkQueue是否被卡住，leaveGroup都会解锁线程，下面再在roomWorkQueue中异步释放资源，就不会造成等待的问题
         */
        self.signalManager.leaveGroup()
        
        ///必须此线程中释放资源，所以关于资源的操作都在roomWorkQueue中执行，防止异步线程访问已经被释放的资源造成崩溃
        roomWorkQueue.async {
            guard self.roomId == roomId else {
                return
            }
            zmLog.info("CallingRoomManager-leaveRoom---thread:\(Thread.current)")

            self.signalManager.peerLeave()
            
            self.roomState = .none

            self.clientConnectManager?.dispose()
            self.clientConnectManager = nil
            
            self.roomId = nil
            
            ///这两个需在上面的变量释放之后再进行释放
            self.mediaOutputManager?.clear()
            self.mediaOutputManager = nil
            
            self.roomMembersManager?.clear()
            self.roomMembersManager = nil
            ///关闭socket
            self.signalManager.leaveRoom()
        }
    }
    
    ///当外部收到end消息时，需要主动remove，确保该成员已经被移除
    func removePeer(with id: UUID) {
        roomWorkQueue.async {
            self.roomMembersManager?.removeMember(with: id)
        }
    }
}

extension CallingRoomManager {
    
    func muteOther(_ userId: String, isMute: Bool) {
        roomWorkQueue.async {
            self.clientConnectManager?.muteOther(userId, isMute: isMute)
        }
    }
    
    func topUser(_ userId: String) {
        roomWorkQueue.async {
            self.roomMembersManager?.topUser(userId)
        }
    }
    
    func setScreenShare(isStart: Bool) {
        roomWorkQueue.async {
            self.clientConnectManager?.setScreenShare(isStart: isStart)
        }
    }
}

/// media + deal
extension CallingRoomManager {
    
    func setLocalAudio(mute: Bool) {
        roomWorkQueue.async {
            zmLog.info("CallingRoomManager-setLocalAudio--\(mute)")
            self.mediaState.audioMuted(mute)
            self.clientConnectManager?.setLocalAudio(mute: mute)
            self.roomMembersManager?.setMemberAudio(mute, mid: self.userId!)
        }
    }
    
    func setLocalVideo(state: VideoState) {
        roomWorkQueue.async {
            zmLog.info("CallingRoomManager-setLocalVideo--\(state)")
            self.mediaState.videoStateChanged(state)
            self.clientConnectManager?.setLocalVideo(state: state)
            self.roomMembersManager?.setMemberVideo(state, mid: self.userId!)
        }
    }
}

extension CallingRoomManager: CallingClientConnectStateObserve {
    
    func onReceivePropertyChange(with property: MeetingProperty) {
        guard let roomId = self.roomId else { return }
        if case .terminateMeet = property {
            self.delegate?.onCallEnd(conversationId: roomId, reason: .terminate)
        }
        self.delegate?.onReceiveMeetingPropertyChange(in: roomId, with: property)
    }
    
    func establishConnectionFailed() {
        if case .oneToOne = self.roomMode {
            //p2p模式下打洞失败的话，就走mediasoup模式
            self.switchMode(mode: .group)
        } else {
            self.delegate?.onCallEnd(conversationId: self.roomId!, reason: .internalError)
        }
    }
    
    private func switchMode(mode: AVSConversationType) {
        guard self.roomMode != mode else { return }
        zmLog.info("CallingRoomManager-switchMode:\(mode)")
        roomWorkQueue.async {
            if self.roomState == .none { return }
            self.roomMode = mode
            if mode == .group {
                self.clientConnectManager?.dispose()
                self.clientConnectManager = MediasoupClientManager(signalManager: self.signalManager, mediaManager: self.mediaOutputManager!, membersManagerDelegate: self.roomMembersManager!, mediaStateManagerDelegate: self.roomMembersManager!, observe: self, isStarter: self.isStarter, mediaState: self.mediaState)
                self.clientConnectManager?.webSocketConnected()
            }
        }
    }
}

extension CallingRoomManager: CallingMembersObserver {
    
    func roomEmpty() {
        guard let roomId = self.roomId else {
            return
        }
        zmLog.info("CallingRoomManager-roomEmpty")
        self.delegate?.onCallEnd(conversationId: roomId, reason: .normal)
    }
    
    func roomEstablished() {
        zmLog.info("CallingRoomManager-roomEstablished")
        guard let roomId = self.roomId else {
            return
        }
        self.roomState = .connected
        self.delegate?.onEstablishedCall(conversationId: roomId)
    }
    
    func roomMembersConnectStateChange() {
        guard let roomId = self.roomId else {
            return
        }
        zmLog.info("CallingRoomManager-roomMembersConnectStateChange- membersCount:\(self.roomMembersManager!.membersCount)")
        self.delegate?.onGroupMemberChange(conversationId: roomId, memberCount: self.roomMembersManager!.membersCount)
    }
    
    func roomMembersAudioStateChange(with memberId: UUID) {
        guard let roomId = self.roomId else {
            return
        }
        zmLog.info("CallingRoomManager--roomMembersAudioStateChange--memberId:\(memberId)")
        self.delegate?.onGroupMemberChange(conversationId: roomId, memberCount: self.roomMembersManager!.membersCount)
    }
    
    func roomMembersVideoStateChange(with memberId: UUID, videoState: VideoState) {
        zmLog.info("CallingRoomManager--roomMembersVideoStateChange--videoState:\(videoState) memberId:\(memberId)")
//        if self.roomPeersManager!.selfProduceVideo {
//            ///实时监测显示的视频人数，并且更改自己所发出去的视频参数
//            ///这里由于受到视频关闭的时候，是先通知到界面，而不是先更改数据源的，所以这里需要判断
//            let totalCount = self.roomPeersManager!.totalVideoTracksCount
//            self.mediaOutputManager?.changeVideoOutputFormat(with: VideoOutputFormat(count: (videoState == .stopped ? totalCount - 1 : totalCount)))
//        }
        self.delegate?.onVideoStateChange(conversationId: self.roomId!, memberId: memberId, videoState: videoState)
    }
    
}
