//
//  CallingMemberManager.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/7/23.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import WebRTC

private let zmLog = ZMSLog(tag: "calling")

private let membersManagerQueue: DispatchQueue = DispatchQueue.init(label: "CallingMembersManagerQueue")

protocol CallingMembersManagerProtocol {
    
    init(observer: CallingMembersObserver)

    func addNewMember(with id: UUID, isSelf: Bool, hasVideo: Bool)
    func removeMember(with id: UUID)
    ///连接状态
    func memberConnectStateChanged(with id: UUID, state: CallParticipantState)
    ///媒体状态
    func setMemberVideo(_ state: VideoState, mid: UUID)
    
    func clear()
}

protocol CallingMembersObserver {
    func roomEmpty()
    func roomMembersConnectStateChange(with mid: UUID, isConnected: Bool)
    func roomMembersVideoStateChange(with memberId: UUID, videoState: VideoState)
}

class CallingMembersManager: CallingMembersManagerProtocol {
    
    private let observer: CallingMembersObserver
    private var members: [CallingMember] = []
    
    required init(observer: CallingMembersObserver) {
        self.observer = observer
    }
    
    func addNewMember(with id: UUID, isSelf: Bool, hasVideo: Bool) {
        membersManagerQueue.async {
            if let member = self.members.first(where: { return $0.memberId == id }) {
                member.setMemberConnectState(with: .connecting)
            } else {
                let member = CallingMember(memberId: id, isSelf: isSelf, stateObserver: self, hasAudio: true, videoState: hasVideo ? .started : .stopped)
                self.members.append(member)
            }
        }
    }
    
    func removeMember(with id: UUID) {
        membersManagerQueue.async {
            guard let member = self.members.first(where: { return $0.memberId == id }) else {
                zmLog.info("CallingMembersManager--no peer to remove")
                return
            }
            member.clear()
            self.members = self.members.filter({ return $0.memberId != id })
            member.setMemberConnectState(with: .unconnected)
            if self.members.count == 0 {
                self.observer.roomEmpty()
            }
        }
    }
    
    func memberConnectStateChanged(with id: UUID, state: CallParticipantState) {
        membersManagerQueue.async {
            if let member = self.members.first(where: { return $0.memberId == id }) {
                member.setMemberConnectState(with: state)
            }
        }
    }
    
    var membersCount: Int {
        return self.members.count
    }
    
    func setMemberVideo(_ state: VideoState, mid: UUID) {
        membersManagerQueue.async {
            guard let member = self.members.first(where: { return $0.memberId == mid }) else {
                zmLog.info("CallingMembersManager--no peer to setMemberVideo")
                return
            }
            member.setVideoState(state)
        }
    }
    
    ///总共接收到的视频个数
    var totalVideoTracksCount: Int {
        return self.members.filter({ return $0.videoState == .started }).count
    }
    
    func clear() {
        membersManagerQueue.async {
            self.members.forEach({ $0.clear() })
            self.members.removeAll()
        }
    }
    
    deinit {
        zmLog.info("CallingMembersManager-deinit")
    }
    
}

///videoTrack相关
protocol CallingMediaStateManagerProtocol {
    
    func addVideoTrack(with mid: UUID, videoTrack: RTCVideoTrack)
    func removeVideoTrack(with mid: UUID)
    func getVideoTrack(with mid: UUID) -> RTCVideoTrack?

    var totalVideoTracksCount: Int { get }
}

extension CallingMembersManager: CallingMediaStateManagerProtocol {
    
    func addVideoTrack(with mid: UUID, videoTrack: RTCVideoTrack) {
        membersManagerQueue.async {
            if let member = self.members.first(where: { return $0.memberId == mid }) {
                member.videoTrack = videoTrack
            } else {
                zmLog.info("CallingMembersManager-addVideoTrack:---there is no member")
            }
        }
    }
    
    func removeVideoTrack(with mid: UUID) {
        membersManagerQueue.async {
            if let member = self.members.first(where: { return $0.memberId == mid }) {
                member.videoTrack = nil
            } else {
                zmLog.info("CallingMembersManager-removeVideoTrack:---there is no member")
            }
        }
    }
    
    func getVideoTrack(with mid: UUID) -> RTCVideoTrack? {
        if let member = self.members.first(where: { return $0.memberId == mid }) {
            return member.videoTrack
        }
        return nil
    }
    
}

extension CallingMembersManager {
    ///转换成avsMember 供上层调用
    public var avsMembers : [AVSCallMember] {
        return self.members.map({
            return $0.toAvsMember()
        })
    }
    
    func isSelf(with userId: UUID) -> Bool {
        guard let member = self.members.first(where: { return $0.memberId == userId }) else {
            return false
        }
        return member.isSelf
    }
}

extension CallingMembersManager: CallingMemberStateObserver {
    func callMemberConnectStateChange(with mid: UUID, isConnected: Bool) {
        self.observer.roomMembersConnectStateChange(with: mid, isConnected: isConnected)
    }
    func callMemberVideoStateChange(memberId: UUID, videoState: VideoState) {
        self.observer.roomMembersVideoStateChange(with: memberId, videoState: videoState)
    }
    func callMemberConnectingTimeout(with memberId: UUID) {
        self.removeMember(with: memberId)
        self.observer.roomMembersConnectStateChange(with: memberId, isConnected: false)
    }
}

protocol CallingMemberStateObserver {
    func callMemberConnectStateChange(with mid: UUID, isConnected: Bool)
    func callMemberVideoStateChange(memberId: UUID, videoState: VideoState)
    func callMemberConnectingTimeout(with memberId: UUID)
}

class CallingMember: ZMTimerClient {
    
    private let connectTimeInterval: TimeInterval = 80
    
    let memberId: UUID
    let isSelf: Bool
    let stateObserver: CallingMemberStateObserver
    
    private var connectState: CallParticipantState = .connecting
    
    var hasAudio: Bool
    var videoState: VideoState
    var videoTrack: RTCVideoTrack?
    
    private var callTimer: ZMTimer?

    fileprivate init(memberId: UUID, isSelf: Bool, stateObserver: CallingMemberStateObserver, hasAudio: Bool, videoState: VideoState) {
        zmLog.info("CallingMember- peer init--\(memberId)\n")
        self.memberId = memberId
        self.isSelf = isSelf
        if isSelf {
            connectState = .connected
        }
        self.stateObserver = stateObserver
        self.hasAudio = hasAudio
        self.videoState = videoState
        
        callTimer = ZMTimer(target: self)
        callTimer?.fire(afterTimeInterval: connectTimeInterval)
    }

    fileprivate func setMemberConnectState(with state: CallParticipantState) {
        self.connectState = state
        callTimer?.cancel()
        callTimer = nil
        if state == .connecting {
            callTimer = ZMTimer(target: self)
            callTimer?.fire(afterTimeInterval: connectTimeInterval)
        }
        zmLog.info("CallingMember-setPeerConnectState--\(state)\n")
        let isConnected = (state != .connecting && state != .unconnected)
        self.stateObserver.callMemberConnectStateChange(with: self.memberId, isConnected: isConnected)
    }
    
    fileprivate func setVideoState(_ state: VideoState) {
        if state != self.videoState {
            self.videoState = state
            self.stateObserver.callMemberVideoStateChange(memberId: self.memberId, videoState: state)
        }
    }
    
    func timerDidFire(_ timer: ZMTimer!) {
        if self.connectState == .connecting || self.connectState == .unconnected {
            zmLog.info("CallingMember--timerDidFire--\(self.memberId)\n")
            self.stateObserver.callMemberConnectingTimeout(with: self.memberId)
        }
    }
    
    func toAvsMember() -> AVSCallMember {
        return AVSCallMember(userId: self.memberId, callParticipantState: self.connectState, videoState: self.videoState, networkQuality: .normal)
    }
    
    func clear() {
        self.videoTrack = nil
    }
    
    deinit {
        zmLog.info("CallingMember-deinit")
    }
}
