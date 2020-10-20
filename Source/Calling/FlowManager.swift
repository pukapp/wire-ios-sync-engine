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

@objc
public protocol FlowManagerType {

    func setVideoCaptureDevice(_ device : CaptureDevice)
}

@objc
public class FlowManager : NSObject, FlowManagerType {
    public static let AVSFlowManagerCreatedNotification = Notification.Name("AVSFlowManagerCreatedNotification")
    
    fileprivate var mediaManager : MediaManagerType?
    
    init(mediaManager: MediaManagerType) {
        super.init()
        self.mediaManager = mediaManager
    }
    
    public func setVideoCaptureDevice(_ device : CaptureDevice) {
        CallingRoomManager.shareInstance.mediaOutputManager?.flipCamera(capture: device)
    }
    
}
