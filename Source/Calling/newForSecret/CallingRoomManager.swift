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
        signalWorkQueue.async {
            self.roomConnected()
        }
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
    func onEstablishedCall(conversationId: UUID, peerId: UUID)
    func onReconnectingCall(conversationId: UUID)
    func leaveRoom(conversationId: UUID, reason: CallClosedReason)
    func onVideoStateChange(conversationId: UUID, memberId: UUID, videoState: VideoState)
    func onGroupMemberChange(conversationId: UUID, memberCount: Int)
}

///client连接管理，具体实现分别由继承类独自实现
protocol CallingClientConnectProtocol: CallingSignalManagerDelegate {
    init(signalManager: CallingSignalManager, mediaManager: MediaOutputManager, membersManagerDelegate: CallingMembersManagerProtocol, mediaStateManagerDelegate: CallingMediaStateManagerProtocol, observe: CallingClientConnectStateObserve, isStarter: Bool, videoState: VideoState)
    func startConnect()
    func dispose()
    func setLocalAudio(mute: Bool)
    func setLocalVideo(state: VideoState)
}
//client连接回调状态变化
protocol CallingClientConnectStateObserve {
    func establishConnectionFailed()
}

/*
 * 由于关闭房间会有两种情况
 * 1.收到外部消息或主动调用，则关闭房间，释放资源
 * 2.收到socket信令，然后判断当前房间状态，为空，则释放资源
 * 由于目前im端消息的推送延迟问题，所以目前socket的peerLeave信令需要处理，im端的消息也需要处理，所以就会造成多个线程同时创建，或者同时释放的问题
 * 所以这需要是一条串行队列，否则会造成很多闪退bug
 */
let signalWorkQueue: DispatchQueue = DispatchQueue.init(label: "MediasoupSignalWorkQueue")

class CallingRoomManager: NSObject {
    
    enum RoomMode: Equatable {
        case p2p(peerId: UUID)
        case mp
        
        static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs, rhs) {
            case (.mp, .mp):
                return true
            case (.p2p, .p2p):
                return true
            default: return false
            }
        }
    }
    
    enum RoomState {
        case none
        case socketConnecting
        case socketConnected
        case connected
        case disonnected
    }
    
    static let shareInstance: CallingRoomManager = CallingRoomManager()
    
    var delegate: CallingRoomManagerDelegate?
    
    var roomId: UUID?
    private var userId: UUID?
    private var videoState: VideoState = .stopped
    private var isStarter: Bool = false
    private var roomMode: RoomMode = .mp
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
    
    func connectToRoom(with roomId: UUID, userId: UUID, roomMode: RoomMode, videoState: VideoState, isStarter: Bool) {
        zmLog.info("CallingRoomManager-connectToRoom workQueue--\(signalWorkQueue.debugDescription)")
        guard self.roomId == nil else {
            ///已经在房间里面了
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
        ///192.168.3.66----27.124.45.111
        self.signalManager.connectRoom(with: "wss://27.124.45.111:4443", roomId: roomId.transportString(), userId: self.userId!.transportString())
        
        switch roomMode {
        case .p2p(let peerId):
            self.clientConnectManager = WebRTCClientManager(signalManager: self.signalManager, mediaManager: self.mediaOutputManager!, membersManagerDelegate: self.roomMembersManager!, mediaStateManagerDelegate: self.roomMembersManager!, observe: self, isStarter: self.isStarter, videoState: self.videoState)
            //单聊通话需要知道好友信息，并且将其添加至房间成员管理类中
            (clientConnectManager as! WebRTCClientManager).setPeerInfo(peerId: peerId)
            self.roomMembersManager?.addNewMember(with: peerId, hasVideo: false)
        case .mp:
            self.clientConnectManager = MediasoupClientManager(signalManager: self.signalManager, mediaManager: self.mediaOutputManager!, membersManagerDelegate: self.roomMembersManager!, mediaStateManagerDelegate: self.roomMembersManager!, observe: self, isStarter: self.isStarter, videoState: self.videoState)
        }
        self.signalManager.setSignalDelegate(self.clientConnectManager!)
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
    
    private func roomConnected() {
        self.roomState = .socketConnected
        self.clientConnectManager?.startConnect()
    }
    
    ///网络断开连接
    fileprivate func disConnectedRoom() {
        ///需要在此线程中释放资源
        signalWorkQueue.async {
            zmLog.info("CallingRoomManager-disConnectedRoom--thread:\(Thread.current)")
            //self.clientConnectManager?.dispose()
        }
    }
    
    func leaveRoom(with roomId: UUID) {
        //不应在signalWorkQueue中调用，否则会死锁
        self.signalManager.readyToLeaveRoom()
        
        ///需要在此线程中释放资源
        signalWorkQueue.async {
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
        ///接收end消息时会调用，所以需要放在此线程中
        signalWorkQueue.async {
            self.roomMembersManager?.removeMember(with: id)
        }
    }
}

/// media + deal
extension CallingRoomManager {
    
    func setLocalAudio(mute: Bool) {
        zmLog.info("CallingRoomManager-setLocalAudio--\(mute)")
        self.clientConnectManager?.setLocalAudio(mute: mute)
    }
    
    func setLocalVideo(state: VideoState) {
        zmLog.info("CallingRoomManager-setLocalVideo--\(state)")
        self.videoState = state
        self.clientConnectManager?.setLocalVideo(state: state)
    }
}

extension CallingRoomManager: CallingClientConnectStateObserve {
    
    func establishConnectionFailed() {
        if case .p2p = self.roomMode {
            //p2p模式下打洞失败的话，就走mediasoup模式
            self.switchMode(mode: .mp)
        } else {
            self.delegate?.leaveRoom(conversationId: self.roomId!, reason: .internalError)
        }
    }
    
    private func switchMode(mode: RoomMode) {
        guard self.roomMode != mode else { return }
        zmLog.info("CallingRoomManager-switchMode:\(mode)")
        signalWorkQueue.async {
            if self.roomState == .none { return }
            self.roomMode = mode
            if mode == .mp {
                self.clientConnectManager?.dispose()
                self.clientConnectManager = MediasoupClientManager(signalManager: self.signalManager, mediaManager: self.mediaOutputManager!, membersManagerDelegate: self.roomMembersManager!, mediaStateManagerDelegate: self.roomMembersManager!, observe: self, isStarter: self.isStarter, videoState: self.videoState)
                self.signalManager.setSignalDelegate(self.clientConnectManager!)
                self.clientConnectManager?.startConnect()
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
    
    func roomMembersConnectStateChange(with mid: UUID, isConnected: Bool) {
        guard let roomId = self.roomId else {
            return
        }
        zmLog.info("CallingRoomManager-roomMembersConnectStateChange-mid:\(mid),isConnected:\(isConnected)")
        if isConnected {
            ///只要有一个用户连接，就认为此次会话已经连接
            self.roomState = .connected
            self.delegate?.onEstablishedCall(conversationId: roomId, peerId: mid)
        }
        self.delegate?.onGroupMemberChange(conversationId: roomId, memberCount: self.roomMembersManager!.membersCount)
    }
    
    func roomMembersVideoStateChange(with memberId: UUID, videoState: VideoState) {
        zmLog.info("CallingRoomManager--roomMembersVideoStateChange--videoState:\(videoState)")
//        if self.roomPeersManager!.selfProduceVideo {
//            ///实时监测显示的视频人数，并且更改自己所发出去的视频参数
//            ///这里由于受到视频关闭的时候，是先通知到界面，而不是先更改数据源的，所以这里需要判断
//            let totalCount = self.roomPeersManager!.totalVideoTracksCount
//            self.mediaOutputManager?.changeVideoOutputFormat(with: VideoOutputFormat(count: (videoState == .stopped ? totalCount - 1 : totalCount)))
//        }
        self.delegate?.onVideoStateChange(conversationId: self.roomId!, memberId: memberId, videoState: videoState)
    }
    
}
