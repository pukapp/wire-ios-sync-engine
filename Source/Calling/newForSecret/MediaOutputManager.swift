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

class WRRTCAudioTrack: Equatable {
    
    public let track: RTCAudioTrack
    
    public var isEnabled: Bool {
        get {
            return self.track.isEnabled
        }
        set {
            self.track.isEnabled = newValue
        }
    }
    
    init(_ audioTrack: RTCAudioTrack) {
        zmLog.info("Track: WRRTCAudioTrack -- init - \(audioTrack)")
        self.track = audioTrack
    }
    
    deinit {
        zmLog.info("Track: WRRTCAudioTrack -- deinit")
    }
    
    static func == (lhs: WRRTCAudioTrack, rhs: WRRTCAudioTrack) -> Bool {
        return lhs.track == rhs.track
    }
    
}

class WRRTCVideoTrack: Equatable {
    
    public let track: RTCVideoTrack
    
    public var isEnabled: Bool {
        get {
            return self.track.isEnabled
        }
        set {
            self.track.isEnabled = newValue
        }
    }
    
    init(_ videoTrack: RTCVideoTrack) {
        zmLog.info("Track: WRRTCVideoTrack -- init - \(videoTrack)")
        self.track = videoTrack
    }
    
    func add(_ render: RTCVideoRenderer) {
        self.track.add(render)
    }
    
    func remove(_ render: RTCVideoRenderer) {
        self.track.remove(render)
    }
    
    deinit {
        zmLog.info("Track: WRRTCVideoTrack -- deinit")
    }
    
    static func == (lhs: WRRTCVideoTrack, rhs: WRRTCVideoTrack) -> Bool {
        return lhs.track == rhs.track
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
    
    private let peerConnectionFactory: RTCPeerConnectionFactory
    private var videoSource: RTCVideoSource!
    private var videoCapturer: RTCCameraVideoCapturer!
    
    //默认为中等质量
    private var currentOutputFormat: VideoOutputFormat = .medium {
        didSet {
            self.videoSource.adaptOutputFormat(toWidth: currentOutputFormat.width, height: currentOutputFormat.height, fps: Int32(MEDIA_VIDEO_FPS))
        }
    }
    
    private var captureType: CaptureDevice = .front
    private var frontCapture: AVCaptureDevice?
    private var backCapture: AVCaptureDevice?
    private var currentCapture: AVCaptureDevice? {
        return captureType == .front ? frontCapture : backCapture
    }
    
    /// 由于主界面和room管理类可能会同时异步获取videoTrack，从而会造成获取两个track，这里需要加一个锁。
    let getVideoTracklock = NSLock()
    private var mediaSoupVideoTrack: WRRTCVideoTrack?
    private var mediaSoupAudioTrack: WRRTCAudioTrack?
    
    private var isScreenShare: Bool = false
    
    override init() {
        self.peerConnectionFactory = RTCPeerConnectionFactory();
        super.init()
        self.videoSource = self.peerConnectionFactory.videoSource()
        self.videoCapturer = RTCCameraVideoCapturer(delegate: self)
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
        }
    }
    
    func produceVideoTrack(with format: VideoOutputFormat) -> WRRTCVideoTrack {
        getVideoTracklock.lock()
        
        if let track = self.mediaSoupVideoTrack {
            getVideoTracklock.unlock()
            return track
        }
        zmLog.info("MediaOutputManager-getVideoTrack:\(format)")
        self.currentOutputFormat = format

        self.videoCapturer.startCapture(with: self.currentCapture!, format: self.currentCapture!.activeFormat, fps: MEDIA_VIDEO_FPS)
        self.videoSource.adaptOutputFormat(toWidth: VideoOutputFormat.high.height, height: VideoOutputFormat.high.width, fps: Int32(MEDIA_VIDEO_FPS))
        let videoTrack: WRRTCVideoTrack = WRRTCVideoTrack(self.peerConnectionFactory.videoTrack(with: self.videoSource, trackId: MediaOutputManager.VIDEO_TRACK_ID))
        self.mediaSoupVideoTrack = videoTrack
        getVideoTracklock.unlock()
        return videoTrack
    }
    
    func produceAudioTrack() -> WRRTCAudioTrack {
        if let track = self.mediaSoupAudioTrack {
            return track
        }
        
        let audioTrack: RTCAudioTrack = self.peerConnectionFactory.audioTrack(withTrackId: MediaOutputManager.AUDIO_TRACK_ID)
        audioTrack.isEnabled = true
        
        
        self.mediaSoupAudioTrack = WRRTCAudioTrack(audioTrack)
        return self.mediaSoupAudioTrack!
    }
    
    func clear() {
        self.releaseAudioTrack()
        self.releaseVideoTrack()
        if self.isScreenShare {
            self.stopRecording()
        }
        
        self.videoSource = nil
        self.videoCapturer = nil
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
        }
    }
    
}

extension MediaOutputManager: RTCVideoCapturerDelegate {
    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) {
        if !isScreenShare {
            //当前正在屏幕分享的话就不传递摄像头的数据
            self.videoSource.capturer(capturer, didCapture: frame)
        }
    }
}

// Deal ScreenRecording CMSampleBufferGetImageBuffer
extension MediaOutputManager: DataWormholeDataTransportDelegate {
    
    func startRecording() {
        guard !isScreenShare else {
            return
        }
        zmLog.info("MediaOutputManager-startRecording")
        DataWormholeServerManager.sharedManager.setupSocket(with: self)
        let screenScale = UIScreen.main.bounds.height/UIScreen.main.bounds.width
        let scaleHeight = Int32(CGFloat(self.currentOutputFormat.width)*screenScale)
        self.videoSource.adaptOutputFormat(toWidth: self.currentOutputFormat.width, height: scaleHeight, fps: Int32(MEDIA_VIDEO_FPS))
        isScreenShare = true
    }
    
    func onRecvData(data: Data) {
        guard isScreenShare, self.videoSource != nil, let helper = CVPixelBufferConvertDataHelper.init(data: data), let pixelBuffer = helper.pixelBuffer else {
            zmLog.info("DataWormholeDataTransportDelegate-获取pixelBuffer出错")
            return
        }
        let buffer: RTCCVPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)

        let videoFrame = RTCVideoFrame(buffer: buffer, rotation: RTCVideoRotation._0, timeStampNs: helper.timeStampNs)
        //传递当前屏幕实时数据
        self.videoSource.capturer(self.videoCapturer, didCapture: videoFrame)
    }
    
    func stopRecording() {
        zmLog.info("MediaOutputManager-stopRecording")
        isScreenShare = false
        DataWormholeServerManager.sharedManager.stopSocket()
    }
    
}
