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

extension CallingRoomManager: CallingSocketStateDelegate {
    
    func socketConnected() {
        guard self.roomState == .socketConnecting else { return }
        self.roomState = .socketConnected
        self.roomConnected()
    }
    
    func socketDisconnected(needDestory: Bool) {
        if needDestory {
            self.roomState = .disonnected
            self.delegate?.leaveRoom(conversationId: self.roomId!, reason: .internalError)
        } else {
            self.roomState = .socketConnecting
            self.disConnectedRoom()
            //self.delegate?.onReconnectingCall(conversationId: self.roomId!)
        }
    }

}

protocol CallingRoomManagerDelegate {
    func onEstablishedCall(conversationId: UUID)
    func onReconnectingCall(conversationId: UUID)
    func leaveRoom(conversationId: UUID, reason: CallClosedReason)
    func onVideoStateChange(conversationId: UUID, memberId: UUID, videoState: VideoState)
    func onGroupMemberChange(conversationId: UUID, memberCount: Int)
    
    //仅为会议支持
    func onReceiveMeetingPropertyChange(in mid: UUID, with property: MeetingProperty)
}

///client连接管理，具体实现分别由继承类独自实现
protocol CallingClientConnectProtocol: CallingSignalManagerDelegate {
    init(signalManager: CallingSignalManager, mediaManager: MediaOutputManager, membersManagerDelegate: CallingMembersManagerProtocol, mediaStateManagerDelegate: CallingMediaStateManagerProtocol, observe: CallingClientConnectStateObserve, isStarter: Bool, videoState: VideoState)
    func webSocketConnected()
    func webSocketDisConnected()
    func dispose()
    func setLocalAudio(mute: Bool)
    func setLocalVideo(state: VideoState)
    
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
    private var videoState: VideoState = .stopped
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
        signalManager = CallingSignalManager(socketStateDelegate: self)
    }
    
    func setCallingConfigure(_ callingConfigure: CallingConfigure) {
        self.callingConfigure = callingConfigure
    }
    
    func connectToRoom(with roomId: UUID, userId: UUID, roomMode: AVSConversationType, videoState: VideoState, isStarter: Bool, members: [CallMemberProtocol], token: String?) {
        zmLog.info("CallingRoomManager-connectToRoom roomId:\(roomId) userId:\(userId)")
        guard let callingConfigure = self.callingConfigure,
            let wsUrl = callingConfigure.vaildGateway,
            self.roomId == nil else {
            ///已经在房间里面了
            zmLog.info("CallingRoomManager-connectToRoom err:获取configuare出错，或者roomId不为空")
            return
        }
        self.roomId = roomId
        self.userId = userId
        self.roomMode = roomMode
        self.videoState = videoState
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
            self.clientConnectManager = WebRTCClientManager(signalManager: self.signalManager, mediaManager: self.mediaOutputManager!, membersManagerDelegate: self.roomMembersManager!, mediaStateManagerDelegate: self.roomMembersManager!, observe: self, isStarter: self.isStarter, videoState: self.videoState)
            //获取穿透服务器地址
            (clientConnectManager as! WebRTCClientManager).callingConfigure = callingConfigure
        case .group, .conference:
            self.clientConnectManager = MediasoupClientManager(signalManager: self.signalManager, mediaManager: self.mediaOutputManager!, membersManagerDelegate: self.roomMembersManager!, mediaStateManagerDelegate: self.roomMembersManager!, observe: self, isStarter: self.isStarter, videoState: self.videoState)
        }
        self.signalManager.setSignalDelegate(self.clientConnectManager!)
    }
    
    private func roomConnected() {
        self.roomState = .socketConnected
        self.clientConnectManager?.webSocketConnected()
    }
    
    ///网络断开连接
    private func disConnectedRoom() {
        zmLog.info("CallingRoomManager-disConnectedRoom--thread:\(Thread.current)")
        self.clientConnectManager?.webSocketDisConnected()
    }
    
    func leaveRoom(with roomId: UUID) {
        ///需要在此线程中释放资源
        roomWorkQueue.async {
            guard self.roomId == roomId else {
                return
            }
            zmLog.info("CallingRoomManager-leaveRoom---thread:\(Thread.current)")

            self.signalManager.peerLeave()
            
            self.roomState = .none

            self.clientConnectManager?.dispose()
            
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
        self.clientConnectManager?.muteOther(userId, isMute: isMute)
    }
    
    func topUser(_ userId: String) {
        self.roomMembersManager?.topUser(userId)
    }
}

/// media + deal
extension CallingRoomManager {
    
    func setLocalAudio(mute: Bool) {
        roomWorkQueue.async {
            zmLog.info("CallingRoomManager-setLocalAudio--\(mute)")
            self.clientConnectManager?.setLocalAudio(mute: mute)
            self.roomMembersManager?.setMemberAudio(mute, mid: self.userId!)
        }
    }
    
    func setLocalVideo(state: VideoState) {
        roomWorkQueue.async {
            zmLog.info("CallingRoomManager-setLocalVideo--\(state)")
            self.videoState = state
            self.clientConnectManager?.setLocalVideo(state: state)
            self.roomMembersManager?.setMemberVideo(state, mid: self.userId!)
        }
    }
}

extension CallingRoomManager: CallingClientConnectStateObserve {
    
    func onReceivePropertyChange(with property: MeetingProperty) {
        if case .terminateMeet = property {
            self.delegate?.leaveRoom(conversationId: self.roomId!, reason: .terminate)
        }
        self.delegate?.onReceiveMeetingPropertyChange(in: self.roomId!, with: property)
    }
    
    func establishConnectionFailed() {
        if case .oneToOne = self.roomMode {
            //p2p模式下打洞失败的话，就走mediasoup模式
            self.switchMode(mode: .group)
        } else {
            self.delegate?.leaveRoom(conversationId: self.roomId!, reason: .internalError)
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
                self.clientConnectManager = MediasoupClientManager(signalManager: self.signalManager, mediaManager: self.mediaOutputManager!, membersManagerDelegate: self.roomMembersManager!, mediaStateManagerDelegate: self.roomMembersManager!, observe: self, isStarter: self.isStarter, videoState: self.videoState)
                self.signalManager.setSignalDelegate(self.clientConnectManager!)
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
        self.leaveRoom(with: roomId)
        self.delegate?.leaveRoom(conversationId: roomId, reason: .normal)
    }
    
    func roomEstablished() {
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
