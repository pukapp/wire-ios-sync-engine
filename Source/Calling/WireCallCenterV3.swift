/*
 * Wire
 * Copyright (C) 2016 Wire Swiss GmbH
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

import Foundation

private let zmLog = ZMSLog(tag: "calling")

/**
 * WireCallCenter is used for making Wire calls and observing their state. There can only be one instance of the
 * WireCallCenter.
 *
 * Thread safety: WireCallCenter instance methods should only be called from the main thread, class method can be
 * called from any thread.
 */
@objc public class WireCallCenterV3: NSObject {

    /// The maximum number of participants for a video call.
    let videoParticipantsLimit = 10

    // MARK: - Properties

    /// The selfUser remoteIdentifier
    let selfUserId : UUID
    
    /// The selfUser current clientId
    let selfClientId : String
    
    /// The selfUser nickname
    let selfUserName: String

    /// The object that controls media flow.
    let flowManager: FlowManagerType

    /// The object to use to record stats about the call.
    let analytics: AnalyticsType?

    /// The bridge to use to communicate with and receive events from AVS.
    var callWrapper: CallWrapperType!

    /// The Core Data context to use to coordinate events.
    weak var uiMOC: NSManagedObjectContext?

    /// The object that performs network requests when the call center requests them.
    weak var transport : WireCallCenterTransport? = nil

    // MARK: - Calling State

    /**
     * The date when the call was established (Participants can talk to each other).
     * - note: This property is only valid when the call state is `.established`.
     */

    var establishedDate : Date?

    /**
     * Whether we use constant bit rate for calls.
     * - note: Changing this property after the call has started has no effect.
     */

    var useConstantBitRateAudio: Bool = false

    /// The snaphot of the call state for each non-idle conversation.
    var callSnapshots : [UUID : CallSnapshot] = [:]

    /// Used to collect incoming events (e.g. from fetching the notification stream) until AVS is ready to process them.
    var bufferedEvents : [(event: CallEvent, completionHandler: () -> Void)]  = []
    
    /// Set to true once AVS calls the ReadyHandler. Setting it to `true` forwards all previously buffered events to AVS.
    var isReady : Bool = false {
        didSet {
            if isReady {
                bufferedEvents.forEach { (item: (event: CallEvent, completionHandler: () -> Void)) in
                    let (event, completionHandler) = item
                    handleCallEvent(event, completionHandler: completionHandler)
                }
                bufferedEvents = []
            }
        }
    }

    // MARK: - Initialization
    
    deinit {
        zmLog.info("WireCallCenterV3 --- deinit")
    }

    /**
     * Creates a call center with the required details.
     * - parameter userId: The identifier of the current signed-in user.
     * - parameter clientId: The identifier of the current client on the user's account.
     * - parameter callWrapper: The bridge to use to communicate with and receive events from AVS.
     * If you don't specify one, a default object will be created. Defaults to `nil`.
     * - parameter uiMOC: The Core Data context to use to coordinate events.
     * - parameter flowManager: The object that controls media flow.
     * - parameter analytics: The object to use to record stats about the call. Defaults to `nil`.
     * - parameter transport: The object that performs network requests when the call center requests them.
     */
    
    public required init(userId: UUID, userName: String, clientId: String, uiMOC: NSManagedObjectContext, flowManager: FlowManagerType, analytics: AnalyticsType? = nil, transport: WireCallCenterTransport) {
        self.selfUserId = userId
        self.selfClientId = clientId
        self.selfUserName = userName
        self.uiMOC = uiMOC
        self.flowManager = flowManager
        self.analytics = analytics
        self.transport = transport
        
        super.init()
        
        self.callWrapper = CallingRoomManager.shareInstance
        self.requestCallConfig()
    }

}

// MARK: - Snapshots

extension WireCallCenterV3 {

    /// Removes the participantSnapshot and remove the conversation from the list of ignored conversations.
    func clearSnapshot(conversationId: UUID) {
        callSnapshots.removeValue(forKey: conversationId)
    }

    /**
     * Creates a snapshot for the specified call and adds it to the `callSnapshots` array.
     * - parameter callState:
     * - parameter members: The current members of the call.
     * - parameters callStarter: The ID of the user that started the call.
     * - parameter video: Whether the call is a video call.
     * - parameter conversationId: The identifier of the conversation that hosts the call.
     */

    func createSnapshot(callState : CallState, members: [CallMemberProtocol], callStarter: CallStarterInfo, mediaState: CallMediaType, for remoteIdentifier: UUID, callType: CallRoomType) {
//        guard
//            let moc = uiMOC
//            let conversation = ZMConversation(remoteID: conversationId, createIfNeeded: false, in: moc)
//        else {
//            return
//        }

        let callParticipants = CallParticipantsSnapshot(remoteIdentifier: remoteIdentifier, callType: callType, members: members, callCenter: self)
// TODO: NewCall
//        if let conversation = ZMConversation(remoteID: conversationId, createIfNeeded: false, in: moc) {
//            let token = ConversationChangeInfo.add(observer: self, for: conversation)
//        }
//        let group = conversation.conversationType == .group

        callSnapshots[remoteIdentifier] = CallSnapshot(
            callParticipants: callParticipants,
            callState: callState,
            callStarter: callStarter,
            mediaState: mediaState,
            callType: callType,
            isConstantBitRate: false,
            videoState: mediaState.needSendVideo ? .started : .stopped,
            networkQuality: .normal,
            conversationObserverToken: nil
        )
    }

}

// MARK: - State Helpers

extension WireCallCenterV3 {

    /// All non idle conversations and their corresponding call state.
    public var nonIdleCalls : [UUID: CallState] {
        return callSnapshots.mapValues( { $0.callState })
    }

    /// The list of conversation with established calls.
    public var activeCalls: [UUID: CallState] {
        return nonIdleCalls.filter { _, callState in
            switch callState {
            case .established, .establishedDataChannel:
                return true
            default:
                return false
            }
        }
    }

    /**
     * Checks the state of video calling in the conversation.
     * - parameter conversationId: The identifier of the conversation to check the state of.
     * - returns: Whether the conversation hosts a video call.
     */

    @objc(isVideoCallForConversationID:)
    public func isVideoCall(conversationId: UUID) -> Bool {
        return callSnapshots[conversationId]?.mediaState.needSendVideo ?? false
    }

    /**
     * Checks the call bitrate type used in the conversation.
     * - parameter conversationId: The identifier of the conversation to check the state of.
     * - returns: Whether the call is being made with a constant bitrate.
     */

    @objc(isConstantBitRateInConversationID:)
    public func isContantBitRate(conversationId: UUID) -> Bool {
        return callSnapshots[conversationId]?.isConstantBitRate ?? false
    }

    /**
     * Determines the video state of the specified user in the conversation.
     * - parameter conversationId: The identifier of the conversation to check the state of.
     * - returns: The video-sending state of the user inside conversation.
     */

    public func videoState(conversationId: UUID) -> VideoState {
        return callSnapshots[conversationId]?.videoState ?? .stopped
    }

    /**
     * Determines the call state of the conversation.
     * - parameter conversationId: The identifier of the conversation to check the state of.
     * - returns: The state of calling of conversation, if any.
     */

    public func callState(conversationId: UUID) -> CallState {
        return callSnapshots[conversationId]?.callState ?? .none
    }

    /**
     * Determines the call state of the conversation.
     * - parameter conversationId: The identifier of the conversation to check the state of.
     * - returns: Whether there is an active call in the conversation.
     */

    public func isActive(conversationId: UUID) -> Bool {
        switch callState(conversationId: conversationId) {
        case .established, .establishedDataChannel:
            return true
        default:
            return false
        }
    }

    /**
     * Determines the degradation of the conversation.
     * - parameter conversationId: The identifier of the conversation to check the state of.
     * - returns: Whether the conversation has degraded security.
     */

    public func isDegraded(conversationId: UUID) -> Bool {
        let conversation = ZMConversation(remoteID: conversationId, createIfNeeded: false, in: uiMOC!)
        let degraded = conversation?.securityLevel == .secureWithIgnored
        return degraded
    }

    /// Returns conversations with active calls.
    public func activeCallConversations(in userSession: ZMUserSession) -> [ZMConversation] {
        let conversations = nonIdleCalls.compactMap { (key: UUID, value: CallState) -> ZMConversation? in
            switch value {
            case .establishedDataChannel, .established, .answered, .outgoing:
                return ZMConversation(remoteID: key, createIfNeeded: false, in: userSession.managedObjectContext)
            default:
                return nil
            }
        }

        return conversations
    }

    /// Returns conversations with a non idle call state.
    public func nonIdleCallConversations(in userSession: ZMUserSession) -> [ZMConversation] {
        let conversations = nonIdleCalls.compactMap { (key: UUID, value: CallState) -> ZMConversation? in
            return ZMConversation(remoteID: key, createIfNeeded: false, in: userSession.managedObjectContext)
        }

        return conversations
    }

    public func networkQuality(conversationId: UUID) -> NetworkQuality {
        return callSnapshots[conversationId]?.networkQuality ?? .normal
    }

}

// MARK: - Call Participants

extension WireCallCenterV3 {

    /// Returns the callParticipants currently in the conversation
    func callParticipants(conversationId: UUID) -> [UUID] {
        return callSnapshots[conversationId]?.callParticipants.members.map { $0.remoteId } ?? []
    }

    /// Returns the remote identifier of the user that initiated the call.
    func initiatorForCall(conversationId: UUID) -> UUID? {
        return callSnapshots[conversationId]?.callStarter.id
    }

    /// Call this method when the callParticipants changed and avs calls the handler `wcall_group_changed_h`
    func callParticipantsChanged(conversationId: UUID, participants: [CallMemberProtocol]) {
        //guard callSnapshots[conversationId]!.callType != .oneToOne else { return }
        if callSnapshots[conversationId]?.callParticipants.members.count != participants.count {
            zmLog.info("callParticipantsChanged : conversationId:\(conversationId), participants:\(participants.count)")
        }
        callSnapshots[conversationId]?.callParticipants.callParticipantsChanged(participants: participants)
    }

    /// Call this method when the video state of a participant changes and avs calls the `wcall_video_state_change_h`.
    func callParticipantVideoStateChanged(conversationId: UUID, userId: UUID, videoState: VideoState) {
        callSnapshots[conversationId]?.callParticipants.callParticpantVideoStateChanged(userId: userId, videoState: videoState)
    }
    
    /// Returns the state for a call participant.
    public func state(forUser userId: UUID, in conversationId: UUID) -> CallParticipantState {
        return callSnapshots[conversationId]?.callParticipants.callParticipantState(forUser: userId) ?? .unconnected
    }
    
    public func callParticipantVideoState(conversationId: UUID, userId: UUID) -> VideoState {
        return callSnapshots[conversationId]?.callParticipants.callParticipantVideoState(forUser: userId) ?? .stopped
    }

}

// MARK: - Actions

extension WireCallCenterV3 {

    /**
     * Answers an incoming call in the given conversation.
     * - parameter conversation: The conversation hosting the incoming call.
     * - parameter video: Whether to join the call with video.
     */

    public func answerCall(relyModel: CallRelyModel, mediaState: CallMediaType) -> Bool {
        guard let remoteIdentifier = relyModel.remoteIdentifier else { return false }
        
        endAllCalls(exluding: remoteIdentifier)
        
        if !mediaState.needSendVideo {
            setVideoState(conversationId: remoteIdentifier, videoState: VideoState.stopped)
        }
        
        let answered = callWrapper.connectToRoom(with: remoteIdentifier, userId: self.selfUserId, roomMode: relyModel.callType, mediaState: mediaState, isStarter: false, members: relyModel.initialMember, token: relyModel.token, delegate: self)
        if answered {
            let callState : CallState = .answered(degraded: isDegraded(conversationId: remoteIdentifier))
            sendCallingAction(.answer, cid: remoteIdentifier)
            handleCallState(callState: callState, remoteIdentifier: remoteIdentifier)
        }
        
        return answered
    }

    /**
     * Starts a call in the given conversation.
     * - parameter conversation: The conversation to start the call.
     * - parameter video: Whether to start the call as a video call.
     */
    
    public func startCall(relyModel: CallRelyModel, mediaState: CallMediaType) -> Bool {
        guard let remoteIdentifier = relyModel.remoteIdentifier else { return false }
        
        endAllCalls(exluding: remoteIdentifier)
        clearSnapshot(conversationId: remoteIdentifier) // make sure we don't have an old state for this conversation
        
        let started = callWrapper.connectToRoom(with: remoteIdentifier, userId: self.selfUserId, roomMode: relyModel.callType, mediaState: mediaState, isStarter: true, members: relyModel.initialMember, token: relyModel.token, delegate: self)
        if started {
            let callState: CallState = .outgoing(degraded: isDegraded(conversationId: remoteIdentifier))
            createSnapshot(callState: callState, members: relyModel.initialMember, callStarter: (selfUserId, selfUserName), mediaState: mediaState, for: remoteIdentifier, callType: relyModel.callType)
            
            sendCallingAction(.start, cid: remoteIdentifier)
            
            handleCallState(callState: callState, remoteIdentifier: remoteIdentifier)
        }
        return started
    }

    /**
     * Closes the call in the specified conversation.
     * - parameter conversationId: The ID of the conversation where the call should be ended.
     * - parameter reason: The reason why the call should be ended. The default is `.normal` (user action).
     */

    public func closeCall(conversationId: UUID, reason: CallClosedReason = .normal) {
        callWrapper.leaveRoom(with: conversationId)
        guard let previousSnapshot = callSnapshots[conversationId] else { return }
        var newState: CallState = .terminating(reason: reason)
        switch previousSnapshot.callType {
        case .group:
            if self.callWrapper.members(in: conversationId).count > 1 {
                sendCallingAction(.leave, cid: conversationId)
                newState = .terminating(reason: .stillOngoing)
            } else {
                sendCallingAction(.end, cid: conversationId)
            }
        case .oneToOne:
            sendCallingAction(.end, cid: conversationId)
        case .conference:
            newState = .terminating(reason: .terminate)
        }
        handleCallState(callState: newState, remoteIdentifier: conversationId)
    }

    /**
     * Rejects an incoming call in the conversation.
     * - parameter conversationId: The ID of the conversation where the incoming call is hosted.
     */
    
    @objc(rejectCallForConversationID:)
    public func rejectCall(conversationId: UUID) {
        sendCallingAction(.reject, cid: conversationId)
        
        guard let snapshot = callSnapshots[conversationId] else { return }
        var closeReason: CallClosedReason = .busy
        switch snapshot.callType {
        case .group:
            closeReason = .stillOngoing
        case .oneToOne, .conference: break
        }
        handleCallState(callState: .terminating(reason: closeReason), remoteIdentifier: conversationId)
    }

    /**
     * Ends all the calls. You can specify the identifier of a conversation where the call shouldn't be ended.
     * - parameter excluding: If you need to terminate all calls except one, pass the identifier of the conversation
     * that hosts the call to keep alive. If you pass `nil`, all calls will be ended. Defaults to `nil`.
     */
    
    public func endAllCalls(exluding: UUID? = nil) {
        nonIdleCalls.forEach { (key: UUID, callState: CallState) in
            guard exluding == nil || key != exluding else { return }
            
            switch callState {
            case .incoming:
                rejectCall(conversationId: key)
            default:
                closeCall(conversationId: key)
            }
        }
    }

    /**
     * Enables or disables video for a call.
     * - parameter conversationId: The identifier of the conversation where the video call is hosted.
     * - parameter videoState: The new video state for the self user.
     */
    
    public func setVideoState(conversationId: UUID, videoState: VideoState) {
        guard videoState != .badConnection else { return }
        
        if let snapshot = callSnapshots[conversationId] {
            callSnapshots[conversationId] = snapshot.updateVideoState(videoState)
        }
        
        callWrapper.setLocalVideo(state: videoState)
    }
    
    public func muteSelf(isMute: Bool) {
        callWrapper.setLocalAudio(mute: isMute)
    }
    
    public func muteOther(_ userId: String, isMute: Bool) {
        callWrapper.muteOther(userId, isMute: isMute)
    }

    func topUser(_ userId: String) {
        callWrapper.topUser(userId)
    }
    
    func setScreenShare(isStart: Bool) {
        callWrapper.setScreenShare(isStart: isStart)
    }
    /**
     * Sets the capture device type to use for video.
     * - parameter captureDevice: The device type to use to capture video for the call.
     * - parameter conversationId: The identifier of the conversation where the video call is hosted.
     */

    public func setVideoCaptureDevice(_ captureDevice: CaptureDevice) {
        flowManager.setVideoCaptureDevice(captureDevice)
    }

}

// MARK: - AVS Integration

extension WireCallCenterV3 {

    /// Sends a call OTR message when requested by AVS through `wcall_send_h`.
    func send(conversationId: UUID, userId: UUID, newCalling: ZMNewCalling) {
        transport?.send(newCalling: newCalling, conversationId: conversationId, userId: userId, completionHandler: { [weak self] status in
            
        })
    }

    /// Sends the config request when requested by AVS through `wcall_config_req_h`.
    func requestCallConfig() {
        CallingService.getConfigInfo(completionHandler: { callingConfigure in
            guard let callingConfigure = callingConfigure else { return }
            zmLog.debug("\(self): requestCallConfig(), callingConfigure = \(callingConfigure)")
            self.setCallReady(version: 3)
            self.callWrapper.setCallingConfigure(callingConfigure)
        })
    }

    /// Tags a call as missing when requested by AVS through `wcall_missed_h`.
    func missed(conversationId: UUID, userId: UUID, timestamp: Date, isVideoCall: Bool) {
        zmLog.debug("missed call")
        //TODO: newCall
        if let context = uiMOC {
            WireCallCenterMissedCallNotification(context: context, remoteIdentifier: conversationId, callType: .group, callerId: userId, timestamp: timestamp, video: isVideoCall).post(in: context.notificationContext)
        }
    }

    /// Handles incoming OTR calling messages, and transmist them to AVS when it is ready to process events, or adds it to the `bufferedEvents`.
    /// - parameter callEvent: calling event to process.
    /// - parameter completionHandler: called after the call event has been processed (this will for example wait for AVS to signal that it's ready).
    func processCallEvent(_ callEvent: CallEvent, completionHandler: @escaping () -> Void) {
    
        if isReady {
            handleCallEvent(callEvent, completionHandler: completionHandler)
        } else {
            bufferedEvents.append((callEvent, completionHandler))
        }
    }
    
    fileprivate func handleCallEvent(_ callEvent: CallEvent, completionHandler: @escaping () -> Void) {
        let result = self.received(callEvent: callEvent)
        
        if let context = uiMOC, let error = result {
            WireCallCenterCallErrorNotification(context: context, error: error).post(in: context.notificationContext)
        }
        
        completionHandler()
    }

    /**
     * Handles a change in calling state.
     * - parameter conversationId: The ID of the conversation where the calling state has changed.
     * - parameter userId: The identifier of the user that caused the event.
     * - parameter messageTime: The timestamp of the event.
     */

    func handleCallState(callState: CallState, remoteIdentifier: UUID, messageTime: Date? = nil) {
        callState.logState()
        var callState = callState

        switch callState {
        case .established:
            // WORKAROUND: the call established handler will is called once for every participant in a
            // group call. Until that's no longer the case we must take care to only set establishedDate once.
            if self.callState(conversationId: remoteIdentifier) != .established {
                establishedDate = Date()
            }

            if videoState(conversationId: remoteIdentifier) == .started {
                callWrapper.setLocalVideo(state: .started)
                //当连接成功之后，需要判断下视频状态是否是开启状态，如开启，则改为扩音模式
                AVSMediaManager.sharedInstance.isSpeakerEnabled = true
            }
        case .establishedDataChannel:
            if self.callState(conversationId: remoteIdentifier) == .established {
                return // Ignore if data channel was established after audio
            }
        case .terminating(reason: .stillOngoing):
            callState = .incoming(video: false, shouldRing: false, degraded: isDegraded(conversationId: remoteIdentifier))
        default:
            break
        }

        let callerId = initiatorForCall(conversationId: remoteIdentifier)

        guard let previousSnapshot = callSnapshots[remoteIdentifier] else { return }

        if case .terminating = callState {
            clearSnapshot(conversationId: remoteIdentifier)
        } else {
            callSnapshots[remoteIdentifier] = previousSnapshot.update(with: callState)
        }

        if let context = uiMOC, let callerId = callerId  {
            WireCallCenterCallStateNotification(context: context, callState: callState, remoteIdentifier: remoteIdentifier, callType: previousSnapshot.callType, callerId: callerId, messageTime: messageTime, previousCallState:previousSnapshot.callState).post(in: context.notificationContext)
        }
    }

    func meetingPropertyChange(in mid: UUID, with property: MeetingProperty) {
        if let context = uiMOC?.zm_sync {
            //修改coredata属性需要在syncContext中修改，才能触发通知,并且需要阻塞住线程
            context.perform {
                guard let meeting = ZMMeeting.fetchExistingMeeting(with: mid.transportString(), in: context) else {
                    return
                }
                switch property {
                case .mute(let state):
                    meeting.muteAll = state
                case .holder(let userId):
                    meeting.holdId = userId
                case .onlyHosterCanShareScreen(let isOnly):
                    meeting.onlyHosterCanShareScreen = isOnly
                case .setInternal(let isInternal):
                    meeting.isInternal = isInternal
                case .lockmMeeting(let isLocked):
                    meeting.isLocked = isLocked
                case .removeUser(let userId):
                    if userId == self.selfUserId.transportString() {
                        meeting.notificationState = .hide
                    }
                case .watchUser(let userId):
                    meeting.watchUserId = userId
                case .screenShareUser(let userId):
                    meeting.screenShareUserId = userId
                case .terminateMeet:
                    meeting.state = .off
                default:break
                }
                context.saveOrRollback()
                
                //需要回到主线程去刷新页面
                DispatchQueue.main.async {
                    WireCallCenterMeetingPropertyChangedNotification(meetingId: mid, property: property).post(in: self.uiMOC!.notificationContext)
                }
            }
            
        }
    }
    
}
