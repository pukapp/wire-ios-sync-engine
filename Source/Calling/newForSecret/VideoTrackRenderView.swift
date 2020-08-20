//
//  MediasoupTrackModel.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/4/16.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import Mediasoupclient

private let zmLog = ZMSLog(tag: "calling")

open class SelfVideoRenderView : RTCEAGLVideoView {
    
    private var attached: Bool = false
    
    
    override open func didMoveToWindow() {
        guard let videoTrack = CallingRoomManager.shareInstance.mediaOutputManager?.produceVideoTrack(with: .high) else {
            zmLog.info("SelfVideoRenderView-videoTrack == nil  mediaOutputManager:\(CallingRoomManager.shareInstance.mediaOutputManager == nil)")
            return
        }
        
        if self.window != nil && !attached {
            zmLog.info("SelfVideoRenderView-addTrack")
            videoTrack.add(self)
        } else {
            zmLog.info("SelfVideoRenderView-removeTrack")
            videoTrack.remove(self)
            attached = false
        }
    }
    
    open func startVideoCapture() {
        CallingRoomManager.shareInstance.mediaOutputManager?.startVideoCapture()
    }
    
    open func stopVideoCapture() {
        CallingRoomManager.shareInstance.mediaOutputManager?.stopVideoCapture()
    }
    
    deinit {
        zmLog.info("SelfVideoRenderView-deinit")
    }
    
}

open class VideoRenderView : RTCEAGLVideoView {
    
    deinit {
        zmLog.info("VideoRenderView--deinit")
    }
    
    open var shouldFill: Bool = false
    open var fillRatio: CGFloat = 0.0
    open var videoSize: CGSize = CGSize(width: 100, height: 100)
    open var userid: String? {
        didSet {
            zmLog.info("VideoRenderView--userid--newValue:\(String(describing: userid)),oldValue\(String(describing: oldValue))")
            if let id = userid,
                let uid = UUID(uuidString: id),
                let track = CallingRoomManager.shareInstance.roomMembersManager?.getVideoTrack(with: uid)
            {
                self.videoTrack = track
            }
        }
    }
    
    private var videoTrack: RTCVideoTrack? {
        didSet {
            zmLog.info("VideoRenderView--videoTrack--newValue:\(String(describing: videoTrack)),oldValue\(String(describing: oldValue))")
            oldValue?.remove(self)
            videoTrack?.add(self)
        }
    }
    
    
    @objc open func removeAddedTrack() {
        self.videoTrack = nil
    }
}


