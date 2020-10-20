//
//  MediaOutputCapturer.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/4/9.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import Mediasoupclient
import ReplayKit

private let zmLog = ZMSLog(tag: "calling")

public enum MediaOutputError : Error {
    case CAMERA_DEVICE_NOT_FOUND
}
private let MEDIA_VIDEO_FPS: Int = 15

///视频输出参数，当视频的人数改变时，显示的视频越多，则使用不同的画面质量，从而减少服务器带宽压力，以及手机网速压力
enum VideoOutputFormat: Int {
    case high       // 640x480
    case medium     // 480x320
    case low        // 320x240
    case veryLow    // 176x144
    
    var width: Int32 {
        switch self {
        case .high:
            return 640
        case .medium:
            return 480
        case .low:
            return 320
        case .veryLow:
            return 176
        }
    }
    var height: Int32 {
        switch self {
        case .high:
            return 480
        case .medium:
            return 320
        case .low:
            return 240
        case .veryLow:
            return 144
        }
    }
    
    init(count: Int) {
        if count < 2 {
            self = .high
        } else if count < 4 {
            self = .medium
        } else if count < 8 {
            self = .low
        } else {
            self = .veryLow
        }
    }
    
}


///应当注意，此类每次使用时初始化，断开后就需要销毁,否则会占用系统类型
final class MediaOutputManager: NSObject {
    
    deinit {
        zmLog.info("MediaOutputManager-deinit")
    }
    
    private static let MEDIA_STREAM_ID: String = "ARDAMS"
    private static let VIDEO_TRACK_ID: String = "ARDAMSv0"
    private static let AUDIO_TRACK_ID: String = "ARDAMSa0"
    private static let SCREEN_TRACK_ID: String = "ARDAMSv1"
    
    private let peerConnectionFactory: RTCPeerConnectionFactory

    private var videoCapturer: RTCCameraVideoCapturer?
    private var videoSource: RTCVideoSource?
    private var currentOutputFormat: VideoOutputFormat?
        
    private var captureType: CaptureDevice = .front
    private var frontCapture: AVCaptureDevice?
    private var backCapture: AVCaptureDevice?
    private var currentCapture: AVCaptureDevice? {
        return captureType == .front ? frontCapture : backCapture
    }
    
    /// 由于主界面和room管理类可能会同时异步获取videoTrack，从而会造成获取两个track，这里需要加一个锁。
    let getVideoTracklock = NSLock()
    private var mediaSoupVideoTrack: RTCVideoTrack?
    private var mediaSoupAudioTrack: RTCAudioTrack?
    
    /// 远端输出屏幕共享的流，本地继续播放摄像头的内容，所以这里重新创建videoSource，videoTrack，不干扰本地摄像头的工作
    private var recordSource: RTCVideoSource?
    private var mediaSoupScreenTrack: RTCVideoTrack?
    
    override init() {
        self.peerConnectionFactory = RTCPeerConnectionFactory();

        self.frontCapture = AVCaptureDevice.DiscoverySession.init(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .front).devices.first;
        self.backCapture = AVCaptureDevice.DiscoverySession.init(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .back).devices.first;
    }
    
    func startVideoCapture() {
        zmLog.info("MediaOutputManager-startVideoCapture")
        guard let capture = self.currentCapture else { return }
        self.videoCapturer?.startCapture(with: capture, format: capture.activeFormat, fps: MEDIA_VIDEO_FPS)
    }
    
    func stopVideoCapture() {
        zmLog.info("MediaOutputManager-stopVideoCapture-thread:\(Thread.current)")
        self.videoCapturer?.stopCapture()
    }
    
    func flipCamera(capture: CaptureDevice) {
        self.captureType = capture
        guard let capture = self.currentCapture else { return }
        self.videoCapturer?.startCapture(with: capture, format: capture.activeFormat, fps: MEDIA_VIDEO_FPS)
    }
    
    func changeVideoOutputFormat(with format: VideoOutputFormat) {
        if self.currentOutputFormat != format {
            zmLog.info("MediaOutputManager-changeVideoOutputFormat:\(format)")
            self.currentOutputFormat = format
            self.videoSource?.adaptOutputFormat(toWidth: format.width, height: format.height, fps: Int32(MEDIA_VIDEO_FPS))
        }
    }
    
    func produceVideoTrack(with format: VideoOutputFormat) -> RTCVideoTrack {
        getVideoTracklock.lock()
        
        if let track = self.mediaSoupVideoTrack {
            getVideoTracklock.unlock()
            return track
        }
        zmLog.info("MediaOutputManager-getVideoTrack:\(format)")
        
        self.currentOutputFormat = format
        
        self.videoSource = self.peerConnectionFactory.videoSource();
        self.videoSource!.adaptOutputFormat(toWidth: format.width, height: format.height, fps: Int32(MEDIA_VIDEO_FPS));
        
        self.videoCapturer = RTCCameraVideoCapturer(delegate: self)
        self.videoCapturer?.startCapture(with: self.currentCapture!, format: self.currentCapture!.activeFormat, fps: MEDIA_VIDEO_FPS)
        let videoTrack: RTCVideoTrack = self.peerConnectionFactory.videoTrack(with: self.videoSource!, trackId: MediaOutputManager.VIDEO_TRACK_ID)
        videoTrack.isEnabled = true
        
        self.mediaSoupVideoTrack = videoTrack
        
        getVideoTracklock.unlock()
        return videoTrack
    }
    
    func produceAudioTrack() -> RTCAudioTrack {
        if let track = self.mediaSoupAudioTrack {
            return track
        }
        
        let audioTrack: RTCAudioTrack = self.peerConnectionFactory.audioTrack(withTrackId: MediaOutputManager.AUDIO_TRACK_ID)
        audioTrack.isEnabled = true
        
        self.mediaSoupAudioTrack = audioTrack
        return audioTrack
    }
    
    func clear() {
        self.releaseAudioTrack()
        self.releaseVideoTrack()
        self.releaseScreenTrack()
    }
    
    func releaseAudioTrack() {
        if let audioTrack = self.mediaSoupAudioTrack {
            audioTrack.isEnabled = false
            self.mediaSoupAudioTrack = nil
        }
    }
    
    func releaseVideoTrack() {
        if let videoTrack = self.mediaSoupVideoTrack {
            self.videoCapturer?.stopCapture()
            videoTrack.isEnabled = false
            self.mediaSoupVideoTrack = nil
            self.videoCapturer = nil
            self.videoSource = nil
        }
    }
    
    func releaseScreenTrack() {
        if let videoTrack = self.mediaSoupScreenTrack {
            videoTrack.isEnabled = false
            self.mediaSoupScreenTrack  = nil
            self.recordSource = nil
        }
    }
    
}

extension MediaOutputManager : RTCVideoCapturerDelegate {
    public func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        DispatchQueue.main.async {
            self.videoSource?.capturer(capturer, didCapture: frame)
        }
    }
}

// Deal ScreenRecording CMSampleBufferGetImageBuffer
extension MediaOutputManager: DataWormholeDataTransportDelegate {
    
    func startRecording() -> RTCVideoTrack {
        DataWormholeServerManager.sharedManager.setupSocket(with: self)
        //重新创建videoSource，videoTrack，不干扰本地摄像头的工作
        self.recordSource = self.peerConnectionFactory.videoSource()
        self.recordSource!.adaptOutputFormat(toWidth: 640, height: 640*16/9, fps: Int32(MEDIA_VIDEO_FPS));
        self.mediaSoupScreenTrack = self.peerConnectionFactory.videoTrack(with: self.recordSource!, trackId: MediaOutputManager.SCREEN_TRACK_ID)
        
        return self.mediaSoupScreenTrack!
    }
    
    func onRecvData(data: Data) {
        guard let helper = CVPixelBufferConvertDataHelper.init(data: data), let pixelBuffer = helper.pixelBuffer else {
            zmLog.info("DataWormholeDataTransportDelegate-获取pixelBuffer出错")
            return
        }
        
        let buffer: RTCCVPixelBuffer = RTCCVPixelBuffer.init(pixelBuffer: pixelBuffer)
        // create the RTCVideoFrame
        let videoFrame = RTCVideoFrame(buffer: buffer, rotation: RTCVideoRotation._0, timeStampNs: helper.timeStampNs)
        
        // connect the video frames to the WebRTC
        self.recordSource?.capturer(self.videoCapturer!, didCapture: videoFrame)
    }
    
    func stopRecording() {
        DataWormholeServerManager.sharedManager.stopSocket()
        self.releaseScreenTrack()
    }
    
}
