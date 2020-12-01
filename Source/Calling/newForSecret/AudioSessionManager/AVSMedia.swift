//
//  AVSMedia.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/7/17.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import AVFoundation

private let zmLog = ZMSLog(tag: "calling")

@objc public protocol AVSMediaDelegate: NSObjectProtocol {
    
    @objc(canStartPlayingMedia:)
    func canStartPlayingMedia(media: AVSMedia) -> Bool
    
    @objc(didStartPlayingMedia:)
    func didStartPlayingMedia(media: AVSMedia)
    
    @objc(didPausePlayingMedia:)
    func didPausePlayingMedia(media: AVSMedia)
    
    @objc(didResumePlayingMedia:)
    func didResumePlayingMedia(media: AVSMedia)
    
    @objc(didFinishPlayingMedia:)
    func didFinishPlayingMedia(media: AVSMedia)
    
}

@objc public protocol AVSMedia: NSObjectProtocol {
    
    @objc(play)
    func play()
    @objc(stop)
    func stop()
    
    @objc(pause)
    func pause()
    @objc(resume)
    func resume()
    
    @objc(reset)
    func reset()
    
    var name: String { get set }
    
    @objc var delegate: AVSMediaDelegate? { get set }
    
    var volume: Float { get set }
    var looping: Bool { get set }
    
    var playbackMuted: Bool { get set }
    var recordingMuted: Bool { get set }
    
}


class AVSSound: NSObject, AVSMedia {
    
    //protocol - AVSMedia
    var name: String
    var delegate: AVSMediaDelegate?
    var volume: Float {
        get {
            return self.level
        }
        set {
            self.level = newValue
            self.updateVolume()
        }
    }
    var playbackMuted: Bool {
        get {
            return self.muted
        }
        set {
            self.muted = newValue
            self.updateVolume()
        }
    }
    
    var looping: Bool
    var recordingMuted: Bool = false
    
    fileprivate var configuration: SoundConfiguration?
    var canMixing: Bool {
        return self.configuration?.mixing ?? false
    }
    
    //private
    private let url: URL
    private var muted: Bool = false
    private var level: Float = 0
    private var player: AVAudioPlayer?
    
    init(name: String, url: URL, looping: Bool) {
        self.name = name
        self.url = url
        self.looping = looping
        super.init()
    }
    
    func play() {
        zmLog.info("MediaEventManager--AVSSound: play:\(self.name)--currentThread:\(Thread.current.description)")
        
        if self.player == nil {
            DispatchQueue.main.sync {
                try! self.player = AVAudioPlayer(contentsOf: self.url)
                
                self.player?.delegate = self
                self.player?.numberOfLoops = self.looping ? -1 : 0
                self.player?.prepareToPlay()
            }
        }
        
        guard self.delegate?.canStartPlayingMedia(media: self) ?? true else {
            return
        }
        
        DispatchQueue.main.sync {
            self.player?.currentTime = 0
            self.player?.play()
        }
        
        var n: Int = 50
        while !self.player!.isPlaying && (n-1 > 0) {
            n = n-1
            usleep(20000)
        }
        
        if n <= 0 {
            zmLog.info("MediaEventManager--AVSSound playing did not start\n")
        } else {
            self.delegate?.didStartPlayingMedia(media: self)
        }
    }
    
    func stop() {
        zmLog.info("MediaEventManager--AVSSound: stop: \(self.name) player=\(String(describing: self.player))")
        
        if self.player == nil {
            return
        }
        
        DispatchQueue.main.async {
            self.player?.stop()
            self.player?.currentTime = 0
        }
        
        self.delegate?.didFinishPlayingMedia(media: self)
    }
    
    func pause() {
        if self.player == nil {
            return
        }
        
        self.player?.pause()
        self.delegate?.didPausePlayingMedia(media: self)
    }
    
    func resume() {
        if self.player == nil {
            return
        }
        
        self.player?.play()
        self.delegate?.didResumePlayingMedia(media: self)
    }
    
    func reset() {
        let player = try! AVAudioPlayer.init(contentsOf: self.url)
        player.delegate = self
        player.numberOfLoops = self.player?.numberOfLoops ?? 0
        player.prepareToPlay()
        
        self.player = player
    }
    
    func updateVolume() {
        if self.player == nil {
            return
        }
        self.player?.volume = self.muted ? 0 : self.level
    }
    
}

extension AVSSound: AVAudioPlayerDelegate {
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        zmLog.info("MediaEventManager--AVSSound: \(name) audioPlayerDecodeErrorDidOccur: error=\(error.debugDescription)")
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        zmLog.info("MediaEventManager--AVSSound: \(name) audioPlayerDidFinishPlaying")
        MediaEventNotification(event: MediaEvent.stopSound, data: self).post()
        self.delegate?.didFinishPlayingMedia(media: self)
    }
}


private struct SoundConfiguration {
    var name: String, path: String, format: String
    var loopAllowed: Bool, mixing: Bool, incall: Bool
    var intensity: Int, priority: Int
    
    init(name: String,dic: NSDictionary) {
        self.name = name
        if let path = dic["path"] as? String,
            let format = dic["format"] as? String {
            self.path = path
            self.format = format
        } else {
            fatal("errInfo")
        }
        
        if let loopAllowed = dic["loopAllowed"] as? Int,
            let mixing = dic["mixingAllowed"] as? Int,
            let incall = dic["incallAllowed"] as? Int,
            let intensity = dic["intensity"] as? Int {
            self.loopAllowed = loopAllowed > 0
            self.mixing = mixing > 0
            self.incall = incall > 0
            self.intensity = intensity
        } else {
            fatal("errInfo")
        }
        
        self.priority = name.hasPrefix("ringing") ? 1 : 0
    }
}

class AVSSoundPlayManager {
    
    var isPlaying: Bool = false
    
    private var soundConfigurations: [SoundConfiguration] = []
    private var sounds: [AVSSound] = []
    
    func playMedia(by name: String) {
        if let sound = self.sounds.first(where: { return $0.name == name }) {
            MediaEventNotification(event: .playSound, data: sound).post()
        }
    }
    
    func canPlayMedia(by name: String, intensity: AVSIntensityLevel) -> Bool {
        if let media = self.soundConfigurations.first(where: { return $0.name == name }) {
            return media.intensity <= intensity.rawValue
        }
        return true
    }
    
    func stopMedia(by name: String) {
        if let sound = self.sounds.first(where: { return $0.name == name }) {
            MediaEventNotification(event: .stopSound, data: sound).post()
        }
    }
    
    func registerMedia(from configuration: NSDictionary, in directory: String) {
        self.soundConfigurations = self.transSounds(from: configuration)
        
        for sound in self.soundConfigurations {
            if let fullPath = Bundle.main.path(forResource: sound.path, ofType: sound.format, inDirectory: directory) {
                let url = URL(fileURLWithPath: fullPath)
                self.registerMedia(name: sound.name, url: url)
            }
        }
    }
    
    func registerMedia(name: String, url: URL) {
        guard let configuration = self.soundConfigurations.first(where: { return $0.name == name }) else {
            return
        }
        
        let sound = AVSSound(name: name, url: url, looping: configuration.loopAllowed)
        sound.configuration = configuration
        self.sounds.append(sound)
    }
    
    func unregisterMedia(by name: String) {
        self.sounds = self.sounds.filter({ return $0.name != name })
    }
    
    
    private func transSounds(from configuration: NSDictionary) -> [SoundConfiguration] {
        var soundConfigurations: [SoundConfiguration] = []
        if let soundsDic = configuration.value(forKey: "sounds") as? NSDictionary {
            for name in soundsDic.allKeys {
                if  let snd = soundsDic.value(forKey: name as! String) as? NSDictionary {
                    let sound = SoundConfiguration.init(name: name as! String, dic: snd)
                    soundConfigurations.append(sound)
                }
            }
        }
        return soundConfigurations
    }
    
}
