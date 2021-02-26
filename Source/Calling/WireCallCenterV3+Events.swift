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

private let zmLog = ZMSLog(tag: "calling")

// MARK: Conversation Changes

extension WireCallCenterV3 : ZMConversationObserver {

    public func conversationDidChange(_ changeInfo: ConversationChangeInfo) {
        guard
            changeInfo.securityLevelChanged,
            let conversationId = changeInfo.conversation.remoteIdentifier,
            let previousSnapshot = callSnapshots[conversationId]
        else { return }

        if changeInfo.conversation.securityLevel == .secureWithIgnored, isActive(conversationId: conversationId) {
            // If an active call degrades we end it immediately
            return closeCall(conversationId: conversationId, reason: .securityDegraded)
        }

        let updatedCallState = previousSnapshot.callState.update(withSecurityLevel: changeInfo.conversation.securityLevel)

        if updatedCallState != previousSnapshot.callState {
            callSnapshots[conversationId] = previousSnapshot.update(with: updatedCallState)

            if let context = uiMOC, let callerId = initiatorForCall(conversationId: conversationId) {
                WireCallCenterCallStateNotification(context: context, callState: updatedCallState, remoteIdentifier: conversationId, callType: changeInfo.conversation.callType, callerId: callerId, messageTime: Date(), previousCallState: previousSnapshot.callState).post(in: context.notificationContext)
            }
        }
    }

}

// MARK: - AVS Callbacks

extension WireCallCenterV3 {

    private func handleEvent(_ description: String, _ handlerBlock: @escaping () -> Void) {
        guard let context = self.uiMOC else {
            zmLog.error("Cannot handle event '\(description)' because the UI context is not available.")
            return
        }

        context.performGroupedBlock {
            handlerBlock()
        }
    }

    private func handleEventInContext(_ description: String, _ handlerBlock: @escaping (NSManagedObjectContext) -> Void) {
        guard let context = self.uiMOC else {
            zmLog.error("Cannot handle event '\(description)' because the UI context is not available.")
            return
        }

        context.performGroupedBlock {
            handlerBlock(context)
        }
    }

    /// Handles incoming calls.
    func handleIncomingCall(conversationId: UUID, callType: CallRoomType, messageTime: Date, callStater: CallStarterInfo, isVideoCall: Bool, shouldRing: Bool) {
        handleEvent("incoming-call") {
            let callState : CallState = .incoming(video: isVideoCall, shouldRing: shouldRing, degraded: self.isDegraded(conversationId: conversationId))
            let members = [ConversationCallMember(userId: callStater.id, callParticipantState: .connecting, isMute: false, videoState: .stopped)]
            self.createSnapshot(callState: callState,
                           members: members,
                           callStarter: callStater,
                           mediaState: isVideoCall ? .bothAudioAndVideo : .audioOnly,
                           for: conversationId,
                           callType: callType)
            self.handleCallState(callState: callState, remoteIdentifier: conversationId, messageTime: messageTime)
        }
    }

    /// Handles missed calls.
    func handleMissedCall(conversationId: UUID, messageTime: Date, userId: UUID, isVideoCall: Bool) {
        handleEvent("missed-call") {
            self.missed(conversationId: conversationId, userId: userId, timestamp: messageTime, isVideoCall: isVideoCall)
        }
    }

    /// Handles answered calls.
    func handleAnsweredCall(conversationId: UUID) {
        handleEvent("answered-call") {
            self.handleCallState(callState: .answered(degraded: self.isDegraded(conversationId: conversationId)),
                                 remoteIdentifier: conversationId)
        }
    }

    /// Handles when data channel gets established.
    func handleDataChannelEstablishement(conversationId: UUID) {
        handleEvent("data-channel-established") {
            self.handleCallState(callState: .establishedDataChannel, remoteIdentifier: conversationId)
        }
    }

    /// Handles established calls.
    func handleEstablishedCall(conversationId: UUID) {
        handleEvent("established-call") {
            self.handleCallState(callState: .established, remoteIdentifier: conversationId)
        }
    }
    
    /// Handles established calls.
    func handleReconnectingCall(conversationId: UUID) {
        handleEvent("reconnecting-call") {
            self.handleCallState(callState: .reconnecting, remoteIdentifier: conversationId)
        }
    }

    /**
     * Handles ended calls
     * If the user answers on the different device, we receive a `WCALL_REASON_ANSWERED_ELSEWHERE` followed by a
     * `WCALL_REASON_NORMAL` once the call ends.
     *
     * If the user leaves an ongoing group conversation or an incoming group call times out, we receive a
     * `WCALL_REASON_STILL_ONGOING` followed by a `WCALL_REASON_NORMAL` once the call ends.
     *
     * If messageTime is set to 0, the event wasn't caused by a message therefore we don't have a serverTimestamp.
     */

    func handleCallEnd(reason: CallClosedReason, conversationId: UUID, messageTime: Date?) {
        handleEvent("closed-call") {
            self.callWrapper.leaveRoom(with: conversationId)
            self.handleCallState(callState: .terminating(reason: reason), remoteIdentifier: conversationId, messageTime: messageTime)
        }
    }

    /// Handles call metrics.
    func handleCallMetrics(conversationId: UUID, metrics: String) {
        do {
            let metricsData = Data(metrics.utf8)
            guard let attributes = try JSONSerialization.jsonObject(with: metricsData, options: .mutableContainers) as? [String: NSObject] else { return }
            analytics?.tagEvent("calling.avs_metrics_ended_call", attributes: attributes)
        } catch {
            zmLog.error("Unable to parse call metrics JSON: \(error)")
        }
    }

    /// Handle requests for refreshing the calling configuration.
    func handleCallConfigRefreshRequest() {
        handleEvent("request-call-config") {
            self.requestCallConfig()
        }
    }
    
    /// Called when AVS is ready.
    func setCallReady(version: Int32) {
        zmLog.debug("wcall intialized with protocol version: \(version)")
        handleEvent("call-ready") {
            self.isReady = true
        }
    }

    /// Handles other users joining / leaving / connecting.
    func handleGroupMemberChange(conversationId: UUID) {
        handleEvent("group-member-change") {
            let members = self.callWrapper.members(in: conversationId)
            self.callParticipantsChanged(conversationId: conversationId, participants: members)
        }
    }

    /// Handles video state changes.
    func handleVideoStateChange(userId: UUID, newState: VideoState) {
        handleEvent("video-state-change") {
            self.nonIdleCalls.forEach {
                self.callParticipantVideoStateChanged(conversationId: $0.key, userId: userId, videoState: newState)
            }
        }
    }

    /// Handles audio CBR mode enabling.
    func handleConstantBitRateChange(enabled: Bool) {
        handleEventInContext("cbr-change") {
            if let establishedCall = self.callSnapshots.first(where: { $0.value.callState == .established || $0.value.callState == .establishedDataChannel }) {
                self.callSnapshots[establishedCall.key] = establishedCall.value.updateConstantBitrate(enabled)
                WireCallCenterCBRNotification(enabled: enabled).post(in: $0.notificationContext)
            }
        }
    }

    /// Stopped when the media stream of a call was ended.
    func handleMediaStopped(conversationId: UUID, callType: CallRoomType) {
        handleEvent("media-stopped") {
            self.handleCallState(callState: .mediaStopped, remoteIdentifier: conversationId)
        }
    }

    /// Handles network quality change
    func handleNetworkQualityChange(conversationId: UUID, callType: CallRoomType, userId: UUID, quality: NetworkQuality) {
        handleEventInContext("network-quality-change") {
            if let call = self.callSnapshots[conversationId] {
                self.callSnapshots[conversationId] = call.updateNetworkQuality(quality)
                WireCallCenterNetworkQualityNotification(remoteIdentifier: conversationId, userId: userId, networkQuality: quality).post(in: $0.notificationContext)
            }
        }
    }
    
    func handleMeetingPropertyChange(in mid: UUID, with property: MeetingProperty) {
        handleEvent("meeting-propertyChange") {
            self.meetingPropertyChange(in: mid, with: property)
        }
    }

}
