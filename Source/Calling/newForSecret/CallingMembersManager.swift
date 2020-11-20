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
    func replaceMember(_ member: CallMemberProtocol)
    ///连接状态
    func memberConnectStateChanged(with id: UUID, state: CallParticipantState)
    ///媒体状态
    func setMemberAudio(_ isMute: Bool, mid: UUID)
    func setMemberVideo(_ state: VideoState, mid: UUID)
    
    func clear()
    
    func containUser(with id: String) -> Bool
    func containUser(with id: UUID) -> Bool
    func user(with id: String) -> CallMemberProtocol?
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
    
    let observer: CallingMembersObserver
    
    var members : [CallMemberProtocol] = []
    private var connectStateObserve: [UUID: ZMTimer] = [:]
    
    private var audioTracks: [(UUID, RTCAudioTrack)] = []
    private var videoTracks: [(UUID, RTCVideoTrack)] = []
    
    fileprivate var activeSpeakers: [UUID : Date] = [:]
    
    required init(observer: CallingMembersObserver) {
        self.observer = observer
    }
    
    func addNewMember(_ newMember: CallMemberProtocol) {
        if self.containUser(with: newMember.remoteId) {
            self.members.replaceMember(with: newMember)
        } else {
            self.members.append(newMember)
        }
        self.membersChanged()
    }
    
    func removeMember(with id: UUID) {
        guard var member = self.members.first(where: { return $0.remoteId == id }) else {
            zmLog.info("CallingMembersManager--no peer to remove")
            return
        }
        member.callParticipantState = .unconnected
        self.members = self.members.filter({ return $0.remoteId != id })
        if self.members.count == 0 {
            self.observer.roomEmpty()
        }
        zmLog.info("CallingMembersManager--removeMember:\(id)--lastMember:\(self.members.map({return $0.remoteId}))")
        self.membersChanged()
    }
    
    func replaceMember(_ updateMember: CallMemberProtocol) {
        if self.containUser(with: updateMember.remoteId) {
            self.members.replaceMember(with: updateMember)
            self.membersChanged()
        }
    }
    
    func memberConnectStateChanged(with id: UUID, state: CallParticipantState) {
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
    
    var membersCount: Int {
        return self.members.count
    }
    
    func setMemberAudio(_ isMute: Bool, mid: UUID) {
        zmLog.info("CallingMembersManager--setMemberAudio:\(mid)-\(isMute)")
        guard var member = self.members.first(where: { return $0.remoteId == mid }), member.isMute != isMute else {
            zmLog.info("CallingMembersManager--no peer to setMemberVideo")
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
    
    func topUser(_ userId: String) {
        guard var member = self.members.first(where: { return $0.remoteId == UUID(uuidString: userId) }) as? MeetingParticipant,
             !member.isTop else { return }
        member.isTop = true
        self.members.replaceMember(with: member)
        self.membersChanged()
    }
    
    func containUser(with uid: UUID) -> Bool {
        return self.user(with: uid) != nil
    }
    func containUser(with id: String) -> Bool {
        guard let uid = UUID(uuidString: id) else { return false }
        return self.containUser(with: uid)
    }
    
    func user(with uid: UUID) -> CallMemberProtocol? {
        return self.members.first(where: { return $0.remoteId == uid })
    }
    func user(with id: String) -> CallMemberProtocol? {
        guard let uid = UUID(uuidString: id) else { return nil }
        return self.user(with: uid)
    }
    
    ///总共接收到的视频个数
    var totalVideoTracksCount: Int {
        return self.members.filter({ return $0.videoState == .started }).count
    }
    
    func clear() {
        self.members.removeAll()
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
