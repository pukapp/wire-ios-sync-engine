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

@objc(ZMCaptureDevice)
public enum CaptureDevice : Int {
    case front
    case back
    
    var deviceIdentifier : String {
        switch  self {
        case .front:
            return "com.apple.avfoundation.avcapturedevice.built-in_video:1"
        case .back:
            return "com.apple.avfoundation.avcapturedevice.built-in_video:0"
        }
    }
}

public protocol CallRelyModel: NSObjectProtocol {
    
    var remoteIdentifier: UUID? { get }
    
    var managedObjectContext: NSManagedObjectContext? { get }
    
    var needCallKit: Bool { get }
    
    var activeParticipants: Set<ZMUser> { get }
    
    var callType: AVSConversationType { get }
    
    var peerId: UUID? { get }
    
    var initialMember: [AVSCallMember] { get }
    
    var callTitle: String? { get }
}

extension ZMMeeting: CallRelyModel {
    public var remoteIdentifier: UUID? {
        return UUID.init(uuidString: "C24461AA-E4D4-4D45-B9EE-58ABD3B07D7B")
    }
    
    public var needCallKit: Bool {
        return false
    }
    
    public var activeParticipants: Set<ZMUser> {
        return []
    }
    
    public var callType: AVSConversationType {
        return .conference
    }
    
    public var peerId: UUID? {
        return nil
    }
    
    public var initialMember: [AVSCallMember] {
        return []
    }
    
    public var callTitle: String? {
        return self.title
    }
}

extension ZMConversation: CallRelyModel {
    
    public var callType: AVSConversationType {
        return self.conversationType == .group ? .group : .oneToOne
    }
    
    public var needCallKit: Bool {
        return true
    }
    
    public var peerId: UUID? {
        if self.conversationType == .oneOnOne {
            return self.connectedUser!.remoteIdentifier
        } else {
            return nil
        }
    }
    
    public var initialMember: [AVSCallMember]  {
        guard let user = self.connectedUser, self.conversationType == .oneOnOne else { return [] }
        return [AVSCallMember(userId: user.remoteIdentifier, callParticipantState: .connecting, videoState: .stopped)]
    }
    
    public var callTitle: String? {
        return self.displayName
    }
}

public protocol VoiceChannel : class, CallProperties, CallActions, CallActionsInternal, CallObservers {
    
    init(relyModel: CallRelyModel)
    
}

public protocol CallProperties : NSObjectProtocol {
    
    var state: CallState { get }
    
    var relyModel: CallRelyModel? { get }
    
    var callTitle: String? { get }
    
    /// The date and time of current call start
    var callStartDate: Date? { get }
    
    /// Voice channel participants. May be a subset of conversation participants.
    var participants: NSOrderedSet { get }
    
    /// Voice channel is sending audio using a contant bit rate
    var isConstantBitRateAudioActive: Bool { get }
    var isVideoCall: Bool { get }
    var initiator: ZMUser? { get }
    var videoState: VideoState { get set }
    var networkQuality: NetworkQuality { get }
    
    func connectState(forParticipant: ZMUser) -> CallParticipantState
    func videoState(forParticipant: ZMUser) -> VideoState
    func setVideoCaptureDevice(_ device: CaptureDevice) throws
}

@objc
public protocol CallActions : NSObjectProtocol {
    
    func mute(_ muted: Bool, userSession: ZMUserSession)
    func join(video: Bool, userSession: ZMUserSession) -> Bool
    func leave(userSession: ZMUserSession, completion: (() -> ())?)
    func continueByDecreasingConversationSecurity(userSession: ZMUserSession)
    func leaveAndDecreaseConversationSecurity(userSession: ZMUserSession)
}

@objc
public protocol CallActionsInternal : NSObjectProtocol {
    
    func join(video: Bool) -> Bool
    func leave()
    
}

public protocol CallObservers : NSObjectProtocol {
    
    /// Add observer of voice channel state. Returns a token which needs to be retained as long as the observer should be active.
    func addCallStateObserver(_ observer: WireCallCenterCallStateObserver) -> Any
    
    /// Add observer of voice channel participants. Returns a token which needs to be retained as long as the observer should be active.
    func addParticipantObserver(_ observer: WireCallCenterCallParticipantObserver) -> Any
    
    /// Add observer of voice gain. Returns a token which needs to be retained as long as the observer should be active.
    func addVoiceGainObserver(_ observer: VoiceGainObserver) -> Any
    
    /// Add observer of constant bit rate audio. Returns a token which needs to be retained as long as the observer should be active.
    func addConstantBitRateObserver(_ observer: ConstantBitRateAudioObserver) -> Any

    /// Add observer of network quality. Returns a token which needs to be retained as long as the observer should be active.
    func addNetworkQualityObserver(_ observer: NetworkQualityObserver) -> Any
    
    /// Add observer of the state of all voice channels. Returns a token which needs to be retained as long as the observer should be active.
    static func addCallStateObserver(_ observer: WireCallCenterCallStateObserver, userSession: ZMUserSession) -> Any
}
