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

let membersManagerQueue: DispatchQueue = DispatchQueue.init(label: "CallingMembersManagerQueue")

protocol CallingMembersManagerProtocol {
    
    init(observer: CallingMembersObserver)

    func addNewMember(_ member: CallMemberProtocol)
    func removeMember(with id: UUID)
    ///连接状态
    func memberConnectStateChanged(with id: UUID, state: CallParticipantState)
    ///媒体状态
    func setMemberAudio(_ isMute: Bool, mid: UUID)
    func setMemberVideo(_ state: VideoState, mid: UUID)
    
    func clear()
    
    func containUser(with id: UUID) -> Bool
    
    //会议
    func muteAll(isMute: Bool)
    func topUser(_ userId: String)
}

protocol CallingMembersObserver {
    func roomEmpty()
    func roomEstablished()
    func roomMembersConnectStateChange()
    func roomMembersAudioStateChange(with memberId: UUID)
    func roomMembersVideoStateChange(with memberId: UUID, videoState: VideoState)
}


//由于struct是值类型，所以这里通过替换来修改
private extension Array where Element == CallMemberProtocol {
    mutating func replaceMember(with member: CallMemberProtocol) {
        if let index = self.firstIndex(where: { return $0.remoteId == member.remoteId }) {
            self[index] = member
        }
    }
}

class CallingMembersManager: CallingMembersManagerProtocol {
    
    let observer: CallingMembersObserver
    var members : [CallMemberProtocol] = []
    private var audioTracks: [(UUID, RTCAudioTrack)] = []
    private var videoTracks: [(UUID, RTCVideoTrack)] = []
    
    required init(observer: CallingMembersObserver) {
        self.observer = observer
    }
    
    func addNewMember(_ member: CallMemberProtocol) {
        membersManagerQueue.async {
            if var member = self.members.first(where: { return $0.remoteId == member.remoteId }) {
                if member.callParticipantState != .connected {
                    member.callParticipantState = .connecting
                    self.members.replaceMember(with: member)
                }
            } else {
                self.members.append(member)
            }
            self.membersChanged()
        }
    }
    
    func removeMember(with id: UUID) {
        membersManagerQueue.async {
            guard var member = self.members.first(where: { return $0.remoteId == id }) else {
                zmLog.info("CallingMembersManager--no peer to remove")
                return
            }
            member.callParticipantState = .unconnected
            self.members = self.members.filter({ return $0.remoteId != id })
            if self.members.count == 0 {
                self.observer.roomEmpty()
            }
            self.membersChanged()
        }
    }
    
    func memberConnectStateChanged(with id: UUID, state: CallParticipantState) {
        membersManagerQueue.async {
            if var member = self.members.first(where: { return $0.remoteId == id }) {
                member.callParticipantState = state
                self.members.replaceMember(with: member)
                if state == .connected {
                    ///只要有一个用户连接，就认为此次会话已经连接
                    self.observer.roomEstablished()
                }
                self.membersChanged()
            }
        }
    }
    
    var membersCount: Int {
        return self.members.count
    }
    
    func setMemberAudio(_ isMute: Bool, mid: UUID) {
        membersManagerQueue.async {
            guard var member = self.members.first(where: { return $0.remoteId == mid }), member.isMute != isMute else {
                zmLog.info("CallingMembersManager--no peer to setMemberVideo")
                return
            }
            member.isMute = isMute
            self.members.replaceMember(with: member)
            self.membersChanged()
        }
    }
    
    func setMemberVideo(_ state: VideoState, mid: UUID) {
        membersManagerQueue.async {
            guard var member = self.members.first(where: { return $0.remoteId == mid }) else {
                zmLog.info("CallingMembersManager--no peer to setMemberVideo")
                return
            }
            member.videoState = state
            self.members.replaceMember(with: member)
            self.membersChanged()
        }
    }
    
    func muteAll(isMute: Bool) {
        membersManagerQueue.async {
            self.members = self.members.map({ member in
                if member.isMute == isMute {
                    return member
                } else {
                    var updateMember = member
                    updateMember.isMute = isMute
                    return updateMember
                }
            })
            self.membersChanged()
        }
    }
    
    func topUser(_ userId: String) {
        membersManagerQueue.async {
            guard var member = self.members.first(where: { return $0.remoteId == UUID(uuidString: userId) }) as? MeetingParticipant,
                 !member.isTop else { return }
            member.isTop = true
            self.members.replaceMember(with: member)
            self.membersChanged()
        }
    }
    
    func containUser(with id: UUID) -> Bool {
        return self.members.contains(where: { return $0.remoteId == id })
    }
    
    ///总共接收到的视频个数
    var totalVideoTracksCount: Int {
        return self.members.filter({ return $0.videoState == .started }).count
    }
    
    func clear() {
        membersManagerQueue.async {
            self.members.removeAll()
        }
    }
    
    deinit {
        zmLog.info("CallingMembersManager-deinit")
    }
    
    func membersChanged() {
        //对成员进行一次排序
        self.members.sort(by: { return $0.sortLevel > $1.sortLevel })
        self.observer.roomMembersConnectStateChange()
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
            if let index = self.videoTracks.firstIndex(where: { return $0.0 == mid }) {
                self.videoTracks[index] = (mid, videoTrack)
            } else {
                self.videoTracks.append((mid, videoTrack))
            }
        }
    }
    
    func removeVideoTrack(with mid: UUID) {
        membersManagerQueue.async {
            self.videoTracks = self.videoTracks.filter({ return $0.0 != mid })
        }
    }
    
    func getVideoTrack(with mid: UUID) -> RTCVideoTrack? {
        return self.videoTracks.first(where: { return $0.0 == mid })?.1
    }
    
}

extension CallingMembersManager {
    ///转换成avsMember 供上层调用
    public var callMembers : [CallMemberProtocol] {
        return self.members
    }
}

//extension CallingMembersManager: CallingMemberStateObserver {
//    func callMemberConnectStateChange(with mid: UUID, isConnected: Bool) {
//        self.observer.roomMembersConnectStateChange(with: mid, isConnected: isConnected)
//    }
//    func callMemberVideoStateChange(memberId: UUID, videoState: VideoState) {
//        self.observer.roomMembersVideoStateChange(with: memberId, videoState: videoState)
//    }
//    func callMemberConnectingTimeout(with memberId: UUID) {
//        self.removeMember(with: memberId)
//        self.observer.roomMembersConnectStateChange(with: memberId, isConnected: false)
//    }
//}-
//
//protocol CallingMemberStateObserver {
//    func callMemberConnectStateChange(with mid: UUID, isConnected: Bool)
//    func callMemberVideoStateChange(memberId: UUID, videoState: VideoState)
//    func callMemberConnectingTimeout(with memberId: UUID)
//}
//
//class CallingMember: ZMTimerClient {
//
//    private let connectTimeInterval: TimeInterval = 80
//
//    let memberId: UUID
//    let isSelf: Bool
//    let stateObserver: CallingMemberStateObserver
//
//    private var connectState: CallParticipantState = .connecting
//
//    var hasAudio: Bool
//    var videoState: VideoState
//    var videoTrack: RTCVideoTrack?
//
//    private var callTimer: ZMTimer?
//
//    fileprivate init(memberId: UUID, isSelf: Bool, stateObserver: CallingMemberStateObserver, hasAudio: Bool, videoState: VideoState) {
//        zmLog.info("CallingMember- peer init--\(memberId)\n")
//        self.memberId = memberId
//        self.isSelf = isSelf
//        if isSelf {
//            connectState = .connected
//        }
//        self.stateObserver = stateObserver
//        self.hasAudio = hasAudio
//        self.videoState = videoState
//
//        callTimer = ZMTimer(target: self)
//        callTimer?.fire(afterTimeInterval: connectTimeInterval)
//    }
//
//    fileprivate func setMemberConnectState(with state: CallParticipantState) {
//        self.connectState = state
//        callTimer?.cancel()
//        callTimer = nil
//        if state == .connecting {
//            callTimer = ZMTimer(target: self)
//            callTimer?.fire(afterTimeInterval: connectTimeInterval)
//        }
//        zmLog.info("CallingMember-setPeerConnectState--\(state)\n")
//        let isConnected = (state != .connecting && state != .unconnected)
//        self.stateObserver.callMemberConnectStateChange(with: self.memberId, isConnected: isConnected)
//    }
//
//    fileprivate func setVideoState(_ state: VideoState) {
//        if state != self.videoState {
//            self.videoState = state
//            self.stateObserver.callMemberVideoStateChange(memberId: self.memberId, videoState: state)
//        }
//    }
//
//    func timerDidFire(_ timer: ZMTimer!) {
//        if self.connectState == .connecting || self.connectState == .unconnected {
//            zmLog.info("CallingMember--timerDidFire--\(self.memberId)\n")
//            self.stateObserver.callMemberConnectingTimeout(with: self.memberId)
//        }
//    }
//
//    func toAvsMember() -> AVSCallMember {
//        return AVSCallMember(userId: self.memberId, callParticipantState: self.connectState, videoState: self.videoState, networkQuality: .normal)
//    }
//
//    func clear() {
//        self.videoTrack = nil
//    }
//
//    deinit {
//        zmLog.info("CallingMember-deinit")
//    }
//}
