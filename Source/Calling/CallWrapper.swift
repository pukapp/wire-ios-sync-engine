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

public protocol CallWrapperType {
    func setCallingConfigure(_ callingConfigure: CallingConfigure)
    func connectToRoom(with roomId: UUID, userId: UUID, roomMode: CallRoomType, mediaState: CallMediaType, isStarter: Bool, members: [CallMemberProtocol], token: String?, delegate: CallingRoomManagerDelegate) -> Bool
    func leaveRoom(with roomId: UUID)
    func setLocalAudio(mute: Bool)
    func setLocalVideo(state: VideoState)
    func members(in conversationId: UUID) -> [CallMemberProtocol]
    func removePeer(with id: UUID)
    
    //meeting
    func muteOther(_ userId: String, isMute: Bool)
    func topUser(_ userId: String)
    func setScreenShare(isStart: Bool)
}
