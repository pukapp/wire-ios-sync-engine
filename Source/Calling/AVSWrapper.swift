//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
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

/**
 * The type of objects that can provide an interface to calling APIs.
 * This provides strong typing, dependency injection and better testing.
 */

public protocol AVSWrapperType {
    init(userId: UUID, clientId: String, observer: UnsafeMutableRawPointer?)
    //TODO: 由于p2p模式下无法从websocket获取peerId,所以这里新增了一个参数
    func startCall(conversationId: UUID, callerName: String, mediaState: AVSCallMediaState, conversationType: AVSConversationType, useCBR: Bool, members: [CallMemberProtocol], token: String?) -> Bool
    func answerCall(conversationId: UUID, mediaState: AVSCallMediaState, conversationType: AVSConversationType, useCBR: Bool, members: [CallMemberProtocol], token: String?) -> Bool
    func endCall(conversationId: UUID, reason: CallClosedReason)
    func rejectCall(conversationId: UUID)
    func close()
    func received(callEvent: CallEvent) -> CallError?
    func setVideoState(conversationId: UUID, videoState: VideoState)
    func handleResponse(httpStatus: Int, reason: String, context: WireCallMessageToken)
    func members(in conversationId: UUID) -> [CallMemberProtocol]
    func update(callConfig: String?, httpStatusCode: Int)
    
    func muteSelf(isMute: Bool)
    func muteOther(_ userId: String, isMute: Bool)
    func topUser(_ userId: String)
    func setScreenShare(isStart: Bool)
}
