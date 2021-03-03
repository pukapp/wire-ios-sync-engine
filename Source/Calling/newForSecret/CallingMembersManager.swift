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

protocol CallingMembersManagerProtocol {
    
    init(observer: CallingMembersObserver)

    func addNewMember(_ member: CallMemberProtocol)
    func removeMember(with id: UUID)
    func replaceMember(with member: CallMemberProtocol)
    ///连接状态
    func memberConnectStateChanged(with id: UUID, state: CallParticipantState)
    ///媒体状态
    func setMemberAudio(_ isMute: Bool, mid: UUID)
    func setMemberVideo(_ state: VideoState, mid: UUID)
    
    func clear()
}

//会议相关的特有逻辑
protocol CallingMembersManagerForMeetingProtocol: CallingMembersManagerProtocol {
    func containUser(with id: UUID) -> Bool
    func user(with uid: UUID) -> CallMemberProtocol?
    
    //会议
    func topUser(_ userId: String)
    func setActiveSpeaker(_ uid: UUID, volume: Int)
}

//当前谁在说话
fileprivate protocol ActiveSpeakerManagerProtocol {
    var activeSpeakers: [UUID : Date] { get set }
    func setActiveSpeaker(_ uid: UUID, volume: Int)
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
    
    private let observer: CallingMembersObserver
    
    private var members : [CallMemberProtocol] = []
    private var connectStateObserve: [UUID: ZMTimer] = [:]
    
    private var audioTracks: [(UUID, RTCAudioTrack)] = []
    private var videoTracks: [(UUID, RTCVideoTrack)] = []
    
    fileprivate var activeSpeakers: [UUID : Date] = [:]
    
    required init(observer: CallingMembersObserver) {
        self.observer = observer
    }
    
    func addNewMember(_ newMember: CallMemberProtocol) {
        self.addConnectStateObserve(for: newMember)
        self.internalAddNewMember(newMember)
    }
    
    func removeMember(with id: UUID) {
        guard let member = self.members.first(where: { return $0.remoteId == id }) else {
            zmLog.info("CallingMembersManager--no peer to remove")
            return
        }
        self.removeConnectStateObserve(for: member)
        self.internalRemoveMember(with: member)
    }
    
    func replaceMember(with updateMember: CallMemberProtocol) {
        guard self.containUser(with: updateMember.remoteId) else {
            return
        }
        if updateMember.callParticipantState == .connecting {
            self.addConnectStateObserve(for: updateMember)
        } else {
            self.removeConnectStateObserve(for: updateMember)
        }
        self.internalReplaceMember(updateMember)
    }
    
    func memberConnectStateChanged(with id: UUID, state: CallParticipantState) {
        guard var member = self.members.first(where: { return $0.remoteId == id }) else {
            return
        }
        member.callParticipantState = state
        switch state {
        case .unconnected:
            member.needRemoveWhenUnconnected ? self.removeMember(with: member.remoteId) : self.replaceMember(with: member)
        case .connecting, .connected:
            self.replaceMember(with: member)
        }
        
        if state == .connected {
            ///只要有一个用户连接，就认为此次会话已经连接
            self.observer.roomEstablished()
        }
    }
    
    var membersCount: Int {
        return self.members.count
    }
    
    func setMemberAudio(_ isMute: Bool, mid: UUID) {
        zmLog.info("CallingMembersManager--setMemberAudio:\(mid)-\(isMute)")
        guard var member = self.members.first(where: { return $0.remoteId == mid }), member.isMute != isMute else {
            zmLog.info("CallingMembersManager--no peer to setMemberAudio")
            return
        }
        member.isMute = isMute
        self.members.replaceMember(with: member)
        self.membersChanged()
    }
    
    func setMemberVideo(_ state: VideoState, mid: UUID) {
        guard var member = self.members.first(where: { return $0.remoteId == mid }) else {
            zmLog.info("CallingMembersManager--no peer to setMemberVideo")
            return
        }
        zmLog.info("CallingMembersManager--setMemberVideo:\(mid)-\(state)")
        member.videoState = state
        self.members.replaceMember(with: member)
        self.membersChanged()
    }

    ///总共接收到的视频个数
    var totalVideoTracksCount: Int {
        return self.members.filter({ return $0.videoState == .started }).count
    }
    
    func clear() {
        self.connectStateObserve.removeAll()
        self.members.removeAll()
    }
    
    deinit {
        zmLog.info("CallingMembersManager-deinit")
    }
    
}

// MARK: Private
extension CallingMembersManager {
    
    private func internalAddNewMember(_ newMember: CallMemberProtocol) {
        guard !self.containUser(with: newMember.remoteId) else {
            self.internalReplaceMember(newMember)
            return
        }
        self.members.append(newMember)
        self.membersChanged()
    }
    
    private func internalRemoveMember(with member: CallMemberProtocol) {
        self.members = self.members.filter({ return $0.remoteId != member.remoteId })
        if self.members.count == 0 {
            self.observer.roomEmpty()
        }
        self.membersChanged()
    }
    
    private func internalReplaceMember(_ updateMember: CallMemberProtocol) {
        self.members.replaceMember(with: updateMember)
        self.membersChanged()
    }
    
    private func membersChanged() {
        //对成员进行一次排序
        self.members.sort(by: { return $0.sortLevel > $1.sortLevel })
        self.observer.roomMembersConnectStateChange()
    }
    
}


extension CallingMembersManager: CallingMembersManagerForMeetingProtocol {
    
    func topUser(_ userId: String) {
        guard var member = self.members.first(where: { return $0.remoteId == UUID(uuidString: userId) }) as? MeetingParticipant,
             !member.isTop else { return }
        member.isTop = true
        self.members.replaceMember(with: member)
        self.membersChanged()
    }
    
    func setScreenShare(_ userId: String, isShare: Bool) {
        guard var member = self.members.first(where: { return $0.remoteId == UUID(uuidString: userId) }) as? MeetingParticipant,
             member.isScreenShare != isShare else { return }
        member.isScreenShare = isShare
        self.members.replaceMember(with: member)
        self.membersChanged()
    }
    
    func containUser(with uid: UUID) -> Bool {
        return self.user(with: uid) != nil
    }
    func user(with uid: UUID) -> CallMemberProtocol? {
        return self.members.first(where: { return $0.remoteId == uid })
    }
    
}

//限制成员连接的时间为30s
private let MemberReConnectingTimeLimit: TimeInterval = 30

//给状态为连接中的成员添加一个定时器，超过一定时间还没有连接成功，则需要切换成员的状态
extension CallingMembersManager: ZMTimerClient {
    
    //判断是否有成员被设置为了connecting的状态，有则开启一个计时器
    private func addConnectStateObserve(for member: CallMemberProtocol) {
        guard member.callParticipantState == .connecting,
              !self.connectStateObserve.contains(where: { return $0.key == member.remoteId }) else {
            return
        }
        zmLog.info("addConnectStateObserve for member:\(member.remoteId)")
        let timer = ZMTimer(target: self)
        timer?.fire(afterTimeInterval: MemberReConnectingTimeLimit)
        self.connectStateObserve[member.remoteId] = timer
    }
    
    //将连接上的和连接失败的成员从观察列表中移除
    private func removeConnectStateObserve(for member: CallMemberProtocol) {
        guard member.callParticipantState != .connecting,
              let timer = self.connectStateObserve.first(where: { return $0.key == member.remoteId })?.value else {
            return
        }
        zmLog.info("removeConnectStateObserve for member:\(member.remoteId)")
        timer.cancel()
        self.connectStateObserve.removeValue(forKey: member.remoteId)
    }
    
    //超时了则将该成员的状态改成未连接状态，且从观察列表中移除
    func timerDidFire(_ timer: ZMTimer!) {
        guard let mid = self.connectStateObserve.first(where: { return $0.value == timer })?.key else {
            return
        }
        zmLog.info("membersConnectStateObserve timerDidFire for member:\(mid)")
        self.memberConnectStateChanged(with: mid, state: .unconnected)
        self.connectStateObserve.removeValue(forKey: mid)
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
        if let index = self.videoTracks.firstIndex(where: { return $0.0 == mid }) {
            self.videoTracks[index] = (mid, videoTrack)
        } else {
            self.videoTracks.append((mid, videoTrack))
        }
    }
    
    func removeVideoTrack(with mid: UUID) {
        self.videoTracks = self.videoTracks.filter({ return $0.0 != mid })
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

private let resignActiveSpeakingTimeInterval: TimeInterval = 10 //从活跃状态变成不活跃状态的间隔默认为10s
private let activeSpeakingVolume: Int = -40 //当前音量大于这个值即认为是活跃状态

extension CallingMembersManager: ActiveSpeakerManagerProtocol {

    func setActiveSpeaker(_ uid: UUID, volume: Int) {
        let isSpeaking = volume >= activeSpeakingVolume
        
        if isSpeaking {
            self.activeSpeakers[uid] = Date()
            self.setMemberActiveSpeaking(uid)
        } else {
            if self.activeSpeakers.keys.contains(uid) {
                self.activeSpeakers.removeValue(forKey: uid)
                self.setMemberResignActiveSpeaking(uid)
            }
        }
        
        let needResignDate = Date(timeIntervalSinceNow: -resignActiveSpeakingTimeInterval)
        var tempNeedRemoveUser: [UUID] = []
        for uid in self.activeSpeakers.keys {
            let oldDate = self.activeSpeakers[uid]!
            if  oldDate.compare(needResignDate) == .orderedAscending {
                //距离上次设置活跃状态的时间间隔超过了规定时间，则将其变成不活跃的状态
                self.setMemberResignActiveSpeaking(uid)
                tempNeedRemoveUser.append(uid)
            }
        }
        tempNeedRemoveUser.forEach({ self.activeSpeakers.removeValue(forKey: $0) })
        
        self.membersChanged()
    }
    
    func setMemberActiveSpeaking(_ uid: UUID) {
        guard var member = self.members.first(where: { return $0.remoteId == uid }) as? MeetingParticipant, !member.isSpeaking else {
            zmLog.info("CallingMembersManager--no peer to setMemberActiveSpeaking")
            return
        }
        member.isSpeaking = true
        self.members.replaceMember(with: member)
    }
    
    func setMemberResignActiveSpeaking(_ uid: UUID) {
        guard var member = self.members.first(where: { return $0.remoteId == uid }) as? MeetingParticipant, member.isSpeaking else {
            zmLog.info("CallingMembersManager--no peer to setMemberResignActiveSpeaking")
            return
        }
        member.isSpeaking = false
        self.members.replaceMember(with: member)
    }

}
