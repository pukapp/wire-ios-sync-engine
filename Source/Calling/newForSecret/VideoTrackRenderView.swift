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

/*
 此界面仅用于MeetingStartViewController中使用
 因为内存泄漏的问题，MediaOutputManager不可能做为单例类来使用，所以在还没有进行通话时，只能单独初始化一个outputManager
 */
public class SelfVideoRenderView : RTCEAGLVideoView {
    
    private var outputManager: MediaOutputManager = MediaOutputManager()
    private var attached: Bool = false
    
    deinit {
        zmLog.info("SelfVideoRenderView--deinit")
    }
    
    override open func didMoveToWindow() {
        if TARGET_OS_SIMULATOR == 1 {
            return
        }
        
        if self.transform != CGAffineTransform(scaleX: -1.0, y: 1.0) {
            self.transform = CGAffineTransform(scaleX: -1.0, y: 1.0)
        }
        
        let videoTrack = outputManager.produceVideoTrack(with: .high)
        
        if self.window != nil && !attached {
            zmLog.info("SelfVideoRenderView-addTrack-- \(videoTrack)")
            videoTrack.add(self)
        } else {
            zmLog.info("SelfVideoRenderView-removeTrack")
            videoTrack.remove(self)
            attached = false

        }
    }
    
    public func startVideoCapture() {
        outputManager.startVideoCapture()
    }
    
    public func stopVideoCapture() {
         outputManager.stopVideoCapture()
    }
    
    public func switchCamera(capture: CaptureDevice) {
        outputManager.flipCamera(capture: capture)
    }
}


public enum VideoRenderMode: Equatable {
    case renderSelf
    case renderOther(userId: String)
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.renderSelf, .renderSelf):
            return true
        default:
            return false
        }
    }
}

public class VideoRenderView : RTCEAGLVideoView {
    
    deinit {
        self.removeAddedTrack()
        zmLog.info("aaaa---VideoRenderView--deinit")
    }
    
    //由于项目中有用到collectionView展示成员视频，所以mode这个参数需要为可变的
    private var mode: VideoRenderMode?
    
    //MARK: 这个方法为必须调用的方法,必须给mode设置一个值
    public func updateMode(_ mode: VideoRenderMode) {
        zmLog.info("aaaa---VideoRenderView--updateMode--new:\(String(describing: self.mode)),old:\(mode)")
        guard self.mode != mode else { return }
        self.mode = mode
        self.renderView()
    }
    
    private func renderView() {
        guard let mode = self.mode else { return }
        switch mode {
        case .renderSelf:
            self.videoTrack = CallingRoomManager.shareInstance.mediaOutputManager?.produceVideoTrack(with: .high)
        case .renderOther(userId: let userId):
            guard let uid = UUID(uuidString: userId),
                let roomMembersManager = CallingRoomManager.shareInstance.roomMembersManager else {
                return
            }
            self.videoTrack = roomMembersManager.getVideoTrack(with: uid)
        }
        self.updateTransform(needFixMirror: mode == .renderSelf)
    }
    
    //当为自己的时候需要修复镜像的问题，他人的则不需要
    private func updateTransform(needFixMirror : Bool) {
        self.transform = CGAffineTransform(scaleX: needFixMirror ? -1 : 1, y: 1)
    }
    
    private var videoTrack: RTCVideoTrack? {
        didSet {
            guard videoTrack != oldValue else { return }
            zmLog.info("aaaa---VideoRenderView--videoTrack--newValue:\(String(describing: videoTrack)),oldValue\(String(describing: oldValue))")
            oldValue?.remove(self)
            videoTrack?.add(self)
        }
    }
    
    //当界面被移除时，也需要手动的移除track
    override public func removeFromSuperview() {
        super.removeFromSuperview()
        self.removeAddedTrack()
    }
    
    //由于track持有自己的引用，所以当出现track不能被释放，但是view需要被释放时，就手动的移除track的引用
    private func removeAddedTrack() {
        self.videoTrack?.remove(self)
        self.videoTrack = nil
    }
}


