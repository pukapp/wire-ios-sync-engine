//
//  MediaEventManager.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/7/17.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import AVFoundation

private let zmLog = ZMSLog(tag: "calling")

public enum MediaEvent {
    case exit
    case playSound, stopSound
    
    case startCall
    case incomingCall
    case connectingCall
    case enterCall
    case exitCall
    
    case enableSpeaker
    case microphoneMuted
    case headsetConnected, btDeviceConnected, deviceChanged
    
    case setUserStartAudio
    
    case audioAlloc, audioRelease, audioReset
    
    case startRecoding, stopRecoding
}

@objcMembers
public class MediaEventNotification: NSObject {
    public static let notificationName = Notification.Name("MediaMgcNotification")
    public static let userInfoKey = notificationName.rawValue
    
    public let event : MediaEvent
    public let data: Any?
    
    public init(event: MediaEvent, data: Any?) {
        self.event = event
        self.data = data
        
        super.init()
    }
    
    public func post() {
        NotificationCenter.default.post(name: MediaEventNotification.notificationName, object: nil, userInfo: [MediaEventNotification.userInfoKey: self])
    }
    
}

///集中处理音频事件，管理音频设备
class MediaEventManager {
    static let shareInstance: MediaEventManager = MediaEventManager()
    
    private var playingAudio: [AVSSound] = []
    var isActive: Bool = false
    var isRecording: Bool = false
    var isPlaying: Bool = false
    var isCalling: Bool = false
    
    var interrupted: Bool = false
    
    ///放在一个串行队列中，依次处理事件
    private static let mediaEventQueue = DispatchQueue(label: "MediaEventHandler")
    
    private init() {
        NotificationCenter.default.addObserver(forName: MediaEventNotification.notificationName, object: nil, queue: nil) { (noti) in
            guard let model = noti.userInfo?[MediaEventNotification.userInfoKey] as? MediaEventNotification else { return }
            MediaEventManager.mediaEventQueue.async {
                zmLog.info("MediaEventManager--deal-event:\(model.event) isCalling:\(self.isCalling) isRecording:\(self.isRecording) isActive:\(self.isActive) isPlaying:\(self.isPlaying)")
                self.handlerEvent(event: model.event, data: model.data)
            }
        }
    }
    
    func handlerEvent(event: MediaEvent, data: Any?) {
        
        switch event {
        case .playSound:
            guard let sound = data as? AVSSound else { return }
            self.playSound(with: sound)
        case .stopSound:
            guard let sound = data as? AVSSound else { return }
            self.stopSound(with: sound)
        case .startRecoding:
            guard let data = data as? (_ canRecord: Bool) -> () else { return }
            self.startRecoding(with: data)
        case .stopRecoding:
            self.stopRecoding()
        case .startCall:
            guard let usingCallKit = data as? Bool else { return }
            self.startCall(with: usingCallKit)
        case .incomingCall:
            guard let usingCallKit = data as? Bool else { return }
            self.invokeIncoming(with: usingCallKit)
        case .connectingCall:
            self.connectingCall()
        case .enterCall:
            self.enterCall()
        case .exitCall:
            self.exitCall()
        case .enableSpeaker:
            guard let enableSpeaker = data as? Bool else { return }
            self.enableSpeake(isEnable: enableSpeaker)
        case .microphoneMuted:
            guard let microphoneMuted = data as? Bool else { return }
            self.microphoneMuted(isMute: microphoneMuted)
        default:
            break
        }
    }
    
}

// MARK: HandleCallingEvent
fileprivate extension MediaEventManager {
    
    func startCall(with usingCallKit: Bool) {
        self.isCalling = true
        ///由于callkit会自动设置category
        if !usingCallKit {
            self.setAudioSessionCategory(with: .playAndRecord)
            self.setAudioSessionActive(isActive: true)
        }
    }
    
    func invokeIncoming(with usingCallKit: Bool) {
        self.isCalling = true
        if !usingCallKit {
            self.setAudioSessionCategory(with: .playAndRecord)
            ///设置外放，播放铃声
            self.enableSpeake(isEnable: true)
            self.setAudioSessionActive(isActive: true)
        }
    }
    
    func connectingCall() {
        self.stopAllSound()
        setAudioSessionCategory(with: .playAndRecord)
        setAudioSessionActive(isActive: true)
    }
    
    func enterCall() {
        //TODO: 这里也需要停止音乐播放，当群里直接同时拨打电话，有可能通过websocket连接直接通话成功，而不需要收到消息
        self.stopAllSound()
        if interrupted {
            self.interrupted = false
            setAudioSessionActive(isActive: true)
        }
    }
    
    func exitCall() {
        self.stopAllSound()
        self.isCalling = false
        setDefaultCategory()
        setAudioSessionActive(isActive: false)
    }
    
}


// MARK: HandlePlaySoundEvent
fileprivate extension MediaEventManager {
    
    ///停止所有音乐播放
    func stopAllSound() {
        playingAudio.forEach({ stopSound(with: $0) })
        playingAudio.removeAll()
    }
    
    func playSound(with sound: AVSSound) {
        zmLog.info("MediaEventManager--playSound name:\(sound.name)")
        
        guard !self.isRecording else {
            return
        }
        if !self.isActive && !self.isCalling {
            if sound.canMixing {
                setAudioSessionCategory(with: .ambient)
            } else {
                setAudioSessionCategory(with: .soloAmbient)
            }
            setAudioSessionActive(isActive: true)
        }
        
        playingAudio.append(sound)
        sound.play()
    }
    
    func stopSound(with sound: AVSSound) {
        setAudioSessionActive(isActive: false)
        sound.stop()
        if let index = playingAudio.firstIndex(of: sound) {
            playingAudio.remove(at: index)
        }
    }
    
}

// MARK: HandleRecordEvent
fileprivate extension MediaEventManager {
    
    func startRecoding(with blk: @escaping (_ canRecord: Bool) -> ()) {
        zmLog.info("MediaEventManager--startRecoding isCalling:\(isCalling ? 1 : 0) isRecording:\(isRecording ? 1 : 0)")
        
        guard !self.isCalling, !self.isRecording else {
            DispatchQueue.main.async {
                blk(false)
            }
            return
        }
        
        self.isRecording = true
        setAudioSessionCategory(with: .record)
        setAudioSessionActive(isActive: true)
        
        DispatchQueue.main.sync {
            blk(true)
        }
    }
    
    func stopRecoding() {
        zmLog.info("MediaEventManager--stopRecoding")
        
        self.isRecording = false
        if !self.isCalling {
            setDefaultCategory()
            setAudioSessionActive(isActive: false)
        }
    }
}


// MARK: AVAudioSession
fileprivate extension MediaEventManager {
    
    func setAudioSessionActive(isActive: Bool) {
        guard self.isActive != isActive else { return }
        if (isCalling || isRecording) && !isActive { return }
        
        zmLog.info("MediaEventManager--setAudioSessionActive: \(isActive ? 1 : 0)")
        
        let options: AVAudioSession.SetActiveOptions = .notifyOthersOnDeactivation
        do {
            try AVAudioSession.sharedInstance().setActive(isActive, options: options)
            self.isActive = isActive
        } catch (let err) {
            zmLog.info("MediaEventManager--setAudioSessionActive: err:\(err.localizedDescription)")
        }
    }
    
    
    func setDefaultCategory() {
        zmLog.info("MediaEventManager--setDefaultCategory")
        
        if AVAudioSession.sharedInstance().category != .ambient {
            setAudioSessionCategory(with: .ambient)
        }
    }
    
    func setAudioSessionCategory(with cat: AVAudioSession.Category) {
        let sess: AVAudioSession = AVAudioSession.sharedInstance()
        guard sess.category != cat else { return }
        zmLog.info("MediaEventManager--setAudioSessionCategory: \(cat.rawValue) oldCat:\(sess.category.rawValue)")
        do {
            var options: AVAudioSession.CategoryOptions = [.mixWithOthers]
            
            if cat == .playAndRecord {
                if self.isRecording {
                    options =  options.union([.defaultToSpeaker])
                }
                options = options.union([.allowBluetooth, .allowBluetoothA2DP])
            } else {
                options =  options.union([.duckOthers])
            }
            
            try sess.setCategory(cat, options: options)
        } catch (let err) {
            zmLog.info("MediaEventManager--setAudioSessionCategory error: \(err.localizedDescription)")
        }
    }
    
    func enableSpeake(isEnable: Bool) {
        zmLog.info("MediaEventManager--enableSpeake-isEnable:\(isEnable)")
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(isEnable ? .speaker : .none)
        } catch (let err) {
            zmLog.info("MediaEventManager--enableSpeake error: \(err.localizedDescription)")
        }
    }
    
    ///直接此处调用MediasoupRoomManager的方法
    func microphoneMuted(isMute: Bool) {
        zmLog.info("MediaEventManager--microphoneMuted-isMute:\(isMute)")
        if self.isCalling {
            CallingRoomManager.shareInstance.setLocalAudio(mute: isMute)
        }
    }
}
