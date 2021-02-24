//
//  WireCallCenterV3+CallingRoomDelegate.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2021/2/23.
//  Copyright © 2021 Zeta Project Gmbh. All rights reserved.
//

import Foundation


public protocol CallingRoomManagerDelegate {
    func onEstablishedCall(conversationId: UUID)
    func onReconnectingCall(conversationId: UUID)
    func onCallEnd(conversationId: UUID, reason: CallClosedReason)
    func onVideoStateChange(conversationId: UUID, memberId: UUID, videoState: VideoState)
    func onGroupMemberChange(conversationId: UUID, memberCount: Int)
    
    //仅为会议支持
    func onReceiveMeetingPropertyChange(in mid: UUID, with property: MeetingProperty)
}

extension WireCallCenterV3: CallingRoomManagerDelegate {
    public func onEstablishedCall(conversationId: UUID) {
        handleEstablishedCall(conversationId: conversationId)
    }
    
    public func onReconnectingCall(conversationId: UUID) {
        handleReconnectingCall(conversationId: conversationId)
    }
    
    public func onCallEnd(conversationId: UUID, reason: CallClosedReason) {
        handleCallEnd(reason: reason, conversationId: conversationId, messageTime: Date())
    }
    
    public func onVideoStateChange(conversationId: UUID, memberId: UUID, videoState: VideoState) {
        handleVideoStateChange(userId: conversationId, newState: videoState)
    }
    
    public func onGroupMemberChange(conversationId: UUID, memberCount: Int) {
        handleGroupMemberChange(conversationId: conversationId)
    }
    
    public func onReceiveMeetingPropertyChange(in mid: UUID, with property: MeetingProperty) {
        meetingPropertyChange(in: mid, with: property)
    }
}
