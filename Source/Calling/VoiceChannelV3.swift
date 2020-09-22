//
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
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

public enum VoiceChannelV3Error: LocalizedError {
    case switchToVideoNotAllowed

    public var errorDescription: String? {
        switch self {
        case .switchToVideoNotAllowed:
            return "Switch to video is not allowed"
        }
    }
}

public class VoiceChannelV3 : NSObject, VoiceChannel {

    public var callCenter: WireCallCenterV3? {
        return self.relyModel?.managedObjectContext?.zm_callCenter
    }
    
    /// The date and time of current call start
    public var callStartDate: Date? {
        return self.callCenter?.establishedDate
    }
    
    weak public var relyModel: CallRelyModel?
    
    public var callTitle: String? {
        return self.relyModel?.callTitle
    }
    
    /// Voice channel participants. May be a subset of conversation participants.
    public var participants: NSOrderedSet {
        guard let callCenter = self.callCenter,
              let remoteIdentifier = relyModel?.remoteIdentifier,
              let context = relyModel?.managedObjectContext
        else { return NSOrderedSet() }
        
        if let conversation = relyModel as? ZMConversation {
            let userIds = callCenter.callParticipants(conversationId: remoteIdentifier)
            let users = userIds.compactMap({ ZMUser(remoteID: $0, createIfNeeded: false, in: conversation, in:context) })
            return NSOrderedSet(array: users)
        } else {
            return NSOrderedSet(array: callCenter.meetingParticipants(meetingId: remoteIdentifier))
        }
    }
    
    public required init(relyModel: CallRelyModel) {
        self.relyModel = relyModel
        super.init()
    }

    public func connectState(forParticipant participant: ZMUser) -> CallParticipantState {
        guard let relyModel = self.relyModel,
            let convID = relyModel.remoteIdentifier,
            let userID = participant.remoteIdentifier,
            let callCenter = self.callCenter
        else { return .unconnected }
        
        if participant.isSelfUser {
            return callCenter.callState(conversationId: convID).callParticipantState
        } else {
            return callCenter.state(forUser: userID, in: convID)
        }
    }
    
    public func videoState(forParticipant participant: ZMUser) -> VideoState {
        guard let relyModel = self.relyModel,
            let convID = relyModel.remoteIdentifier,
            let userID = participant.remoteIdentifier,
            let callCenter = self.callCenter
        else { return .stopped }
        
        if participant.isSelfUser {
             return callCenter.videoState(conversationId: convID)
        } else {
            return callCenter.callParticipantVideoState(conversationId: convID, userId: userID)
        }
    }
    
    public var state: CallState {
        if let remoteIdentifier = relyModel?.remoteIdentifier, let callCenter = self.callCenter {
            return callCenter.callState(conversationId: remoteIdentifier)
        } else {
            return .none
        }
    }
    
    public var isVideoCall: Bool {
        guard let remoteIdentifier = relyModel?.remoteIdentifier else { return false }
        
        return self.callCenter?.isVideoCall(conversationId: remoteIdentifier) ?? false
    }
    
    public var isConstantBitRateAudioActive: Bool {
        guard let remoteIdentifier = relyModel?.remoteIdentifier else { return false }
        
        return self.callCenter?.isContantBitRate(conversationId: remoteIdentifier) ?? false
    }

    public var networkQuality: NetworkQuality {
        guard let remoteIdentifier = relyModel?.remoteIdentifier, let callCenter = self.callCenter else { return .normal }

        return callCenter.networkQuality(conversationId: remoteIdentifier)
    }
    
    public var initiator : ZMUser? {
        guard let context = relyModel?.managedObjectContext,
              let convId = relyModel?.remoteIdentifier,
              let userId = self.callCenter?.initiatorForCall(conversationId: convId)
        else {
            return nil
        }
        return ZMUser.fetch(withRemoteIdentifier: userId, in: context)
    }
    
    public var videoState: VideoState {
        get {
            guard let remoteIdentifier = relyModel?.remoteIdentifier else { return .stopped }
            
            return self.callCenter?.videoState(conversationId: remoteIdentifier) ?? .stopped
        }
        set {
            guard let remoteIdentifier = relyModel?.remoteIdentifier else { return }
            
            callCenter?.setVideoState(conversationId: remoteIdentifier, videoState: newValue)
        }
    }
    
    public func setVideoCaptureDevice(_ device: CaptureDevice) throws {
        guard let conversationId = relyModel?.remoteIdentifier else { throw VoiceChannelV3Error.switchToVideoNotAllowed }
        
        self.callCenter?.setVideoCaptureDevice(device, for: conversationId)
    }
    
}

extension VoiceChannelV3 : CallActions {
    
    public func mute(_ muted: Bool, userSession: ZMUserSession) {
//        if userSession.callNotificationStyle == .callKit, #available(iOS 10.0, *) {
//            userSession.callKitDelegate?.requestMuteCall(in: conversation!, muted: muted)
//        }
        /** 这里由于callKit无法同步的改变isMicrophoneMuted的状态，
         *  但是按钮点击静音之后，会同步的刷新页面，就会导致状态刷新的有问题
         *  所以这里不采用callKit
         **/
        if let manager = userSession.mediaManager as? AVSMediaManager {
            manager.isMicrophoneMuted = muted
        }
    }
    
    public func continueByDecreasingConversationSecurity(userSession: ZMUserSession) {
        guard let conversation = relyModel as? ZMConversation else { return }
        conversation.acknowledgePrivacyWarning(withResendIntent: false)
    }
    
    public func leaveAndDecreaseConversationSecurity(userSession: ZMUserSession) {
        guard let conversation = relyModel as? ZMConversation else { return }
        conversation.acknowledgePrivacyWarning(withResendIntent: false)
        userSession.syncManagedObjectContext.performGroupedBlock {
            let conversationId = conversation.objectID
            if let syncConversation = (try? userSession.syncManagedObjectContext.existingObject(with: conversationId)) as? ZMConversation {
                userSession.callingStrategy.dropPendingCallMessages(for: syncConversation)
            }
        }
        leave(userSession: userSession, completion: nil)
    }
    
    public func join(video: Bool, userSession: ZMUserSession) -> Bool {
        if userSession.callNotificationStyle == .callKit, #available(iOS 10.0, *),
            relyModel?.needCallKit ?? false {
            userSession.callKitDelegate?.requestJoinCall(in: relyModel as! ZMConversation, video: video)
            return true
        } else {
            return join(video: video)
        }
    }
    
    public func leave(userSession: ZMUserSession, completion: (() -> ())?) {
        if userSession.callNotificationStyle == .callKit, #available(iOS 10.0, *),
            relyModel?.needCallKit ?? false  {
            userSession.callKitDelegate?.requestEndCall(in: relyModel as! ZMConversation, completion: completion)
        } else {
            leave()
            completion?()
        }
    }
    
}

extension VoiceChannelV3 : CallActionsInternal {
    
    public func join(video: Bool) -> Bool {
        guard let relyModel = relyModel else { return false }
        
        var joined = false
        
        switch state {
        case .incoming(video: _, shouldRing: _, degraded: let degraded):
            if !degraded {
                joined = callCenter?.answerCall(relyModel: relyModel, video: video) ?? false
            }
        default:
            joined = self.callCenter?.startCall(relyModel: relyModel, video: true) ?? false
        }
        
        return joined
    }
    
    public func leave() {
        guard let relyModel = relyModel,
              let remoteID = relyModel.remoteIdentifier
        else { return }
        
        switch state {
        case .incoming:
            callCenter?.rejectCall(conversationId: remoteID)
        default:
            callCenter?.closeCall(conversationId: remoteID)
        }
    }
    
}

extension VoiceChannelV3 : CallObservers {

    public func addNetworkQualityObserver(_ observer: NetworkQualityObserver) -> Any {
        return WireCallCenterV3.addNetworkQualityObserver(observer: observer, for: relyModel!, context: relyModel!.managedObjectContext!)
    }
    
    /// Add observer of voice channel state. Returns a token which needs to be retained as long as the observer should be active.
    public func addCallStateObserver(_ observer: WireCallCenterCallStateObserver) -> Any {
        return WireCallCenterV3.addCallStateObserver(observer: observer, for: relyModel!, context: relyModel!.managedObjectContext!)
    }
    
    /// Add observer of voice channel participants. Returns a token which needs to be retained as long as the observer should be active.
    public func addParticipantObserver(_ observer: WireCallCenterCallParticipantObserver) -> Any {
        return WireCallCenterV3.addCallParticipantObserver(observer: observer, for: relyModel!, context: relyModel!.managedObjectContext!)
    }
    
    /// Add observer of voice gain. Returns a token which needs to be retained as long as the observer should be active.
    public func addVoiceGainObserver(_ observer: VoiceGainObserver) -> Any {
        return WireCallCenterV3.addVoiceGainObserver(observer: observer, for: relyModel!, context: relyModel!.managedObjectContext!)
    }
        
    /// Add observer of constant bit rate audio. Returns a token which needs to be retained as long as the observer should be active.
    public func addConstantBitRateObserver(_ observer: ConstantBitRateAudioObserver) -> Any {
        return WireCallCenterV3.addConstantBitRateObserver(observer: observer, context: relyModel!.managedObjectContext!)
    }
    
    /// Add observer of the state of all voice channels. Returns a token which needs to be retained as long as the observer should be active.
    public class func addCallStateObserver(_ observer: WireCallCenterCallStateObserver, userSession: ZMUserSession) -> Any {
        return WireCallCenterV3.addCallStateObserver(observer: observer, context: userSession.managedObjectContext!)
    }
    
}

public extension CallState {
        
    var callParticipantState : CallParticipantState {
        switch self {
        case .unknown, .terminating, .incoming, .none, .establishedDataChannel, .mediaStopped:
            return .unconnected
        case .established:
            return .connected
        case .outgoing, .answered, .reconnecting, .answeredIncomingCall:
            return .connecting
        }
    }
    
}

