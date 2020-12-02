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
    //case exit
    case playSound, stopSound
    
    case startCall
    case incomingCall
    case connectingCall
    case enterCall
    case exitCall
    
    case enableSpeaker
    case microphoneMuted
    //case headsetConnected, btDeviceConnected, deviceChanged
    
    //case setUserStartAudio
    
    //case audioAlloc, audioRelease, audioReset
    
    case startRecoding, stopRecoding
    
    case playAudioMessage, stopAudioMessage
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
    
    var isCalling: Bool = false //正在通话中
    var isRecording: Bool = false //正在录音中
    var isPlayingAudioMessage: Bool = false //播放语音消息
    var isPlayingNotifitionMusic: Bool = false //播放提示音乐
    
    //当前使用了耳机
    var isUseHeadphones: Bool {
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains(where: { return ($0.portType == .headphones || $0.portType == .bluetoothA2DP) })
    }
    //是否监听距离感应器
    var needObserverProximityChange: Bool = false {
        didSet {
            guard needObserverProximityChange != oldValue else { return }
            //目前仅当播放语音消息时需要监听
            guard self.isPlayingAudioMessage else { return }
            needObserverProximityChange ? self.startListening() : self.stopListening()
        }
    }
    
    var interrupted: Bool = false
    
    ///放在一个串行队列中，依次处理事件
    private static let mediaEventQueue = DispatchQueue(label: "MediaEventHandler")
    
    private init() {
        self.setDefaultCategory()
        NotificationCenter.default.addObserver(forName: MediaEventNotification.notificationName, object: nil, queue: nil) { (noti) in
            guard let model = noti.userInfo?[MediaEventNotification.userInfoKey] as? MediaEventNotification else { return }
            MediaEventManager.mediaEventQueue.async {
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
        case .playAudioMessage:
            self.playAudioMessage()
        case .stopAudioMessage:
            self.stopAudioMessage()
        }
    }
    
}

// MARK: HandleCallingEvent
fileprivate extension MediaEventManager {
    
    func startCall(with usingCallKit: Bool) {
        self.isCalling = true
    }
    
    func invokeIncoming(with usingCallKit: Bool) {
        self.isCalling = true
        ///设置外放，播放铃声
        self.enableSpeake(isEnable: true)
    }
    
    func connectingCall() {
        self.stopAllSound()
        setAudioSessionActive(isActive: true)
        setAudioSessionCategory(with: .calling)
    }
    
    func enterCall() {
        //TODO: 这里也需要停止音乐播放，当群里直接同时拨打电话，有可能通过websocket连接直接通话成功，而不需要收到消息
        self.stopAllSound()
        setAudioSessionActive(isActive: true)
        setAudioSessionCategory(with: .calling)
    }
    
    func exitCall() {
        self.stopAllSound()
        self.isCalling = false
        setAudioSessionActive(isActive: false)
        setDefaultCategory()
    }
    
}

// MARK: HandlePlayAudioMessageEvent
fileprivate extension MediaEventManager {
    
    func playAudioMessage() {
        guard !self.isCalling else { return }
        self.isPlayingAudioMessage = true
        self.setAudioSessionActive(isActive: true)
        //默认是playback模式，从扬声器播放声音
        self.setAudioSessionCategory(with: .playVoice(raisedToEar: false))
    }
    
    func stopAudioMessage() {
        guard !self.isCalling, !self.isRecording else { return }
        self.isPlayingAudioMessage = false
        self.setDefaultCategory()
        self.setAudioSessionActive(isActive: false)
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
        guard !playingAudio.contains(where: { return $0.name == sound.name }) else {
            zmLog.info("MediaEventManager--playSound alreadyExit name:\(sound.name)")
            return
        }
        guard !self.isRecording else {
            return
        }
        if !self.isActive {
            setAudioSessionCategory(with: .playNotificationSounds)
            setAudioSessionActive(isActive: true)
        }
        zmLog.info("MediaEventManager--playSound name:\(sound.name)")
        playingAudio.append(sound)
        sound.play()
    }
    
    func stopSound(with sound: AVSSound) {
        sound.stop()
        if let index = playingAudio.firstIndex(of: sound) {
            playingAudio.remove(at: index)
        }
        setAudioSessionActive(isActive: false)
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
        //这里不同担心线程死锁的问题，因为这个MediaEventManager的事件处理是在另外一个线程中的
        //这里同步返回就是为了确保SessionCategory被设置完成后再返回
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

//这是目前项目中用到的几种类型，设置了都不会中断其他app的音乐，要么压低，要么重新激活后，继续播放别的app的音乐
private enum AudioSessionCategory {
    case playNotificationSounds //播放提示音，需要响应用户的静音操作，压低其他app的背景音乐
    case record //录音
    case calling //电话
    case playVoice(raisedToEar: Bool) //播放语音或者音乐，当程序置于后台时应当也能播放
    
    var category: AVAudioSession.Category {
        switch self {
        case .playNotificationSounds:
            return .ambient
        case .record, .calling:
            return .playAndRecord
        case .playVoice(let raisedToEar):
            return raisedToEar ? .playAndRecord : .playback//由于听筒模式只能用于playAndRecord模式下
        }
    }
    
    //CategoryOptions与Category是有对应关心的，当设置了不正确的CategoryOptions的话，会设置失败，如ambient和allowBluetooth在一起就会设置失败
    var options: AVAudioSession.CategoryOptions {
        switch self {
        case .playNotificationSounds:
            return [.mixWithOthers, .duckOthers]
        case .record, .calling:
            return [.allowBluetooth, .allowBluetoothA2DP]
        case .playVoice(let raisedToEar):
            return raisedToEar ? [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP] : [.mixWithOthers]
        }
    }
}

// MARK: AVAudioSession
fileprivate extension MediaEventManager {
    
    func setAudioSessionActive(isActive: Bool) {
        guard self.isActive != isActive else { return }
        if !isActive {
            if isCalling || isRecording || isPlayingAudioMessage || isPlayingNotifitionMusic {
                //只有当没有任何要播放的音频时，才能解除激活状态
                return
            }
        }
        self.needObserverProximityChange = isActive
        do {
            try AVAudioSession.sharedInstance().setActive(isActive, options: .notifyOthersOnDeactivation)
            zmLog.info("MediaEventManager--setAudioSessionActive: \(isActive ? 1 : 0)")
            self.isActive = isActive
        } catch (let err) {
            zmLog.info("MediaEventManager--setAudioSessionActive: \(isActive ? 1 : 0) err:\(err.localizedDescription)")
        }
    }
    
    //默认为ambient
    func setDefaultCategory() {
        if AVAudioSession.sharedInstance().category != .ambient {
            setAudioSessionCategory(with: .playNotificationSounds)
        }
    }
    
    func setAudioSessionCategory(with cat: AudioSessionCategory) {
        let session: AVAudioSession = AVAudioSession.sharedInstance()
        if session.category == cat.category && session.categoryOptions == cat.options { return }
        do {
            try session.setCategory(cat.category, options: cat.options)
            zmLog.info("MediaEventManager--setAudioSessionCategory: \(cat.category.rawValue) oldCat:\(session.category) options:\(cat.options)")
        } catch (let err) {
            zmLog.info("MediaEventManager--setAudioSessionCategory: \(cat.category.rawValue) oldCat:\(session.category) options:\(cat.options) error: \(err.localizedDescription)")
        }
    }
    
    func enableSpeake(isEnable: Bool) {
        guard !isUseHeadphones else { return }
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(isEnable ? .speaker : .none)
            zmLog.info("MediaEventManager--enableSpeake isEnable:\(isEnable)")
        } catch (let err) {
            zmLog.info("MediaEventManager--enableSpeake isEnable:\(isEnable) error: \(err.localizedDescription)")
        }
    }
    
    func microphoneMuted(isMute: Bool) {
        zmLog.info("MediaEventManager--microphoneMuted isMute:\(isMute)")
    }
}

// MARK: ListeningProximityChange
extension MediaEventManager {
    
    func startListening() {
        //带了耳机就不用开启距离感应器
        guard !self.isUseHeadphones else { return }
        DispatchQueue.main.async {
            UIDevice.current.isProximityMonitoringEnabled = true
            NotificationCenter.default.addObserver(self,
                                                   selector: #selector(self.handleProximityChange),
                                                   name: UIDevice.proximityStateDidChangeNotification,
                                                   object: nil)
        }
    }
    
    func stopListening() {
        DispatchQueue.main.async {
            UIDevice.current.isProximityMonitoringEnabled = false
            NotificationCenter.default.removeObserver(self)
        }
    }
    
    @objc func handleProximityChange() {
        if self.isPlayingAudioMessage {
            self.setAudioSessionCategory(with: .playVoice(raisedToEar: UIDevice.current.proximityState))
        }
    }
    
}
