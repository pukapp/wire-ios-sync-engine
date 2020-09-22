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
    
    private var outputManager: MediaOutputManager?
    
    override open func didMoveToWindow() {
        if TARGET_OS_SIMULATOR == 1 {
            return
        }
        
        if self.transform != CGAffineTransform(scaleX: -1.0, y: 1.0) {
            self.transform = CGAffineTransform(scaleX: -1.0, y: 1.0)
        }
        
        if outputManager == nil {
            outputManager = MediaOutputManager()
        }
        let videoTrack = outputManager!.produceVideoTrack(with: .high)
        
        if self.window != nil && !attached {
            zmLog.info("SelfVideoRenderView-addTrack-- \(videoTrack)")
            videoTrack.add(self)
        } else {
            zmLog.info("SelfVideoRenderView-removeTrack")
            videoTrack.remove(self)
            attached = false
        }
    }
    
    open func startVideoCapture() {
        self.outputManager?.startVideoCapture()
    }
    
    open func stopVideoCapture() {
        self.outputManager?.stopVideoCapture()
    }
    
    open func switchCamera(isFront: Bool) {
        self.outputManager?.flipCamera(isFront: isFront)
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
    
    open var isSelf: Bool = false {
        didSet {
            if isSelf {
                if TARGET_OS_SIMULATOR == 1 {
                    return
                }
                if self.transform != CGAffineTransform(scaleX: -1.0, y: 1.0) {
                    self.transform = CGAffineTransform(scaleX: -1.0, y: 1.0)
                }
                self.videoTrack = CallingRoomManager.shareInstance.mediaOutputManager?.produceVideoTrack(with: .high)
            }
        }
    }
    
    open var userid: String? {
        didSet {
            zmLog.info("VideoRenderView--userid--newValue:\(String(describing: userid)),oldValue\(String(describing: oldValue))")
            guard let id = userid,
                let uid = UUID(uuidString: id),
                let roomMembersManager = CallingRoomManager.shareInstance.roomMembersManager else {
                return
            }
            self.videoTrack = roomMembersManager.getVideoTrack(with: uid)
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


