//
//  AVSMediaManager.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/7/17.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import AVFoundation

private let zmLog = ZMSLog(tag: "calling")

///判断音效通知的等级
@objc public enum AVSIntensityLevel: UInt {
    case none = 0   //不通知
    case some = 50  //首个消息或招呼
    case full = 100 //所有
}

public enum AVSPlaybackRoute: NSInteger {
    case unknown, builtIn, headset, speaker, bluetooth
}

@objc public class AVSMediaManager: NSObject {
    
    @objc public static let sharedInstance = AVSMediaManager()
    
    private var _intensity: AVSIntensityLevel
    private var _isMicrophoneMuted: Bool
    private var _isSpeakerEnabled: Bool
    
    private var soundPlayManager: AVSSoundPlayManager = AVSSoundPlayManager()
    
    ///电话的几种状态，并在合适的状态下播放或者停止铃声
    private enum CallState {
        case normal, calling, incoming, connecting, connected, end
    }
    private var callState: CallState = .normal
    private var oldCategory: AVAudioSession.Category = .ambient
    
    ///是否使用了callKit
    fileprivate var usingCallKit: Bool = false
    
    
    override init() {
        _intensity = .full
        _isMicrophoneMuted = false
        _isSpeakerEnabled = false
        ///启动MediaEventManager
        let _ = MediaEventManager.shareInstance
        super.init()
    }
    
}

// MARK: Calling: 通话状态
@objc public extension AVSMediaManager {
    
    ///开始通话
    func startCall() {
        MediaEventNotification(event: .startCall, data: self.usingCallKit).post()
        self.callState = .calling
    }
    
    func incomingCall(isVideo: Bool) {
        MediaEventNotification(event: .incomingCall, data: self.usingCallKit).post()
        self.callState = .incoming
    }
    
    func callConnecting() {
        MediaEventNotification(event: .connectingCall, data: nil).post()
        self.callState = .connecting
    }
    
    func enterdCall() {
        MediaEventNotification(event: .enterCall, data: nil).post()
        self.callState = .connected
    }
    
    func exitCall() {
        MediaEventNotification(event: .exitCall, data: nil).post()
        self.callState = .end
        ///打完电话将静音状态，免提状态重置
        self._isMicrophoneMuted = false
        self._isSpeakerEnabled = false
    }
}

// MARK: Record: 录制声音
@objc public extension AVSMediaManager {
    
    func startRecordingWhenReady(blk: @escaping (_ canRecord: Bool) -> ()) {
        MediaEventNotification(event: .startRecoding, data: blk).post()
    }
    
    func stopRecording() {
        MediaEventNotification(event: .stopRecoding, data: nil).post()
    }
    
}

// MARK: Sound: 播放语音消息
@objc public extension AVSMediaManager {
    func playAudioMessage() {
        MediaEventNotification(event: .playAudioMessage, data: nil).post()
    }
    
    func stopAudioMessage() {
        MediaEventNotification(event: .stopAudioMessage, data: nil).post()
    }
}

// MARK: Sound: 播放声音
@objc public extension AVSMediaManager {
    
    func playSound(_ name: String) {
        guard self.soundPlayManager.canPlayMedia(by: name, intensity: self._intensity) else {
            return
        }
        self.soundPlayManager.playMedia(by: name)
    }
    
    func stopSound(_ name: String) {
        self.soundPlayManager.stopMedia(by: name)
    }
    
    @objc(registerMediaFromConfiguration:inDirectory:)
    func registerMedia(from configuration: NSDictionary, in directory: String) {
        self.soundPlayManager.registerMedia(from: configuration, in: directory)
    }
    
    func registerMedia(name: String, url: URL) {
        self.soundPlayManager.registerMedia(name: name, url: url)
    }
    
    func register(_ url: URL?, forMedia name: String) {
        guard let url = url else { return }
        self.soundPlayManager.registerMedia(name: name, url: url)
    }
    
    func unregisterMedia(by name: String) {
        self.soundPlayManager.unregisterMedia(by: name)
    }
    
    @objc func unregisterMedia(_ media: AVSMedia) {
        self.soundPlayManager.unregisterMedia(by: media.name)
    }
}

///AVSMediaManagerInterface
@objc public extension AVSMediaManager {
    
    var intensityLevel: AVSIntensityLevel {
        get {
            return self._intensity
        }
        set {
            self._intensity = newValue
        }
    }
    var isMicrophoneMuted: Bool {
        get {
            return self._isMicrophoneMuted
        }
        set {
            self._isMicrophoneMuted = newValue
            MediaEventNotification(event: .microphoneMuted, data: newValue).post()
        }
    }
    var isSpeakerEnabled: Bool {
        get {
            return self._isSpeakerEnabled
        }
        set {
            self._isSpeakerEnabled = newValue
            MediaEventNotification(event: .enableSpeaker, data: newValue).post()
        }
    }
    
}

extension AVSMediaManager: MediaManagerType {
    
    public func setUiStartsAudio(_ enabled: Bool) {
        self.usingCallKit = enabled
    }
    
    public func startAudio() {
        
    }
    
    public func setupAudioDevice() {
        
    }
    
    public func resetAudioDevice() {
        
    }
    
}
