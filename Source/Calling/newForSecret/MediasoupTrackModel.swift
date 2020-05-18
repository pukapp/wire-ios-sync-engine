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

open class MediasoupPreviewView : RTCEAGLVideoView {
    
    private var attached: Bool = false
    
    
    override open func didMoveToWindow() {
        guard let videoTrack = MediasoupRoomManager.shareInstance.mediaOutputManager?.getVideoTrack() else {
            return
        }
        
        if self.window != nil && !attached {
            videoTrack.add(self)
        } else {
            videoTrack.remove(self)
            attached = false
        }
    }
    
    open func startVideoCapture() {
        MediasoupRoomManager.shareInstance.mediaOutputManager?.startVideoCapture()
    }
    
    open func stopVideoCapture() {
        MediasoupRoomManager.shareInstance.mediaOutputManager?.stopVideoCapture()
    }
    
    deinit {
        zmLog.info("Mediasoup::deinit:---MediasoupPreviewView")
    }
    
}

open class MediasoupVideoView : RTCEAGLVideoView {
    
    deinit {
        zmLog.info("Mediasoup::deinit:---MediasoupVideoView")
    }
    
    open var shouldFill: Bool = false
    open var fillRatio: CGFloat = 0.0
    open var userid: String? {
        didSet {
            if let id = userid,
                let uid = UUID(uuidString: id),
                let track = MediasoupRoomManager.shareInstance.roomPeersManager?.getVideoTrack(with: uid)
            {
                zmLog.info("mediasoup:addTrack--track")
                track.isEnabled = true
                track.add(self)
            }
        }
    }
        
    open var videoSize: CGSize = CGSize(width: 100, height: 100)
    
    open func removeAddedTrack() {
        if let id = userid {
            if let uid = UUID(uuidString: id),
            let track = MediasoupRoomManager.shareInstance.roomPeersManager?.getVideoTrack(with: uid)
            {
                zmLog.info("mediasoup:removeAddedTrack--")
               track.remove(self)
            }
            zmLog.info("mediasoup:removeAddedTrack--track == nil")
        }
    }
}


