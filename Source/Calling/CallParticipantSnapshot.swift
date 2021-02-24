//
// Wire
// Copyright (C) 2018 Wire Swiss GmbH
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
//

import Foundation
import WireUtilities

class CallParticipantsSnapshot {
    
    public private(set) var members : [CallMemberProtocol]

    // We take the worst quality of all the legs
    public var networkQuality: NetworkQuality {
        return members.map(\.networkQuality)
            .sorted() { $0.rawValue < $1.rawValue }
            .last ?? .normal
    }
    
    fileprivate unowned var callCenter : WireCallCenterV3
    fileprivate let remoteIdentifier : UUID
    fileprivate let callType : CallRoomType
    
    init(remoteIdentifier: UUID, callType : CallRoomType, members: [CallMemberProtocol], callCenter: WireCallCenterV3) {
        self.callCenter = callCenter
        self.remoteIdentifier = remoteIdentifier
        self.callType = callType
        self.members = type(of: self).removeDuplicateMembers(members)
    }
    
    static func removeDuplicateMembers(_ members: [CallMemberProtocol]) -> [CallMemberProtocol] {
        // remove duplicates see: https://wearezeta.atlassian.net/browse/ZIOS-8610
        // When a user joins with two devices, we would have a duplicate entry for this user in the member array returned from AVS
        // For now, we will keep the one with "the highest state", meaning if one entry has `audioEstablished == false` and the other one `audioEstablished == true`, we keep the one with `audioEstablished == true`
        let callMembers = members.reduce([CallMemberProtocol]()){ (filtered, member) in
            var newFiltered = filtered
            if let idx = newFiltered.firstIndex(where: { return member.remoteId == $0.remoteId }) {
                if !newFiltered[idx].audioEstablished && member.audioEstablished {
                    newFiltered[idx] = member
                }
            } else {
                newFiltered.append(member)
            }
            return newFiltered
        }
        return callMembers
    }
    
    func callParticipantsChanged(participants: [CallMemberProtocol]) {
        members = type(of:self).removeDuplicateMembers(participants)
        notifyChange()
    }
    
    func update(updatedMember: CallMemberProtocol) {
        members = members.map({ member in
            if member.remoteId == updatedMember.remoteId {
                return updatedMember
            } else {
                return member
            }
        })
        notifyChange()
    }
    
    func notifyChange() {
        if let context = callCenter.uiMOC {
            WireCallCenterCallParticipantNotification(remoteIdentifier: remoteIdentifier, callType: callType, participants: members.map({ ($0.remoteId, $0.callParticipantState, $0.videoState) })).post(in: context.notificationContext)
        }
    }
    
    public func callParticipantState(forUser userId: UUID) -> CallParticipantState {
        guard let callMember = members.first(where: { $0.remoteId == userId }) else { return .unconnected }
        
        return callMember.callParticipantState
    }
    
    public func callParticipantVideoState(forUser userId: UUID) -> VideoState {
        guard let callMember = members.first(where: { $0.remoteId == userId }) else { return .stopped }
        
        return callMember.videoState
    }
}

//普通音视频
extension CallParticipantsSnapshot {
    
    func callParticpantVideoStateChanged(userId: UUID, videoState: VideoState) {
        guard var callMember = members.first(where: { $0.remoteId == userId }) else { return }
        callMember.videoState = videoState
        
        update(updatedMember: callMember)
    }

    func callParticpantNetworkQualityChanged(userId: UUID, networkQuality: NetworkQuality) {
        guard var callMember = members.first(where: { $0.remoteId == userId }) else { return }
        callMember.networkQuality = networkQuality

        update(updatedMember: callMember)
    }
    
}
