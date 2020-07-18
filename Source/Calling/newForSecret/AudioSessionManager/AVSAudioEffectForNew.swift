//
//  AVSAudioEffectForNew.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/7/17.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import Mediasoupclient

@objc public enum AVSAudioEffectType: Int {
    case chorusMin = 0
    case chorusMed
    case chorusMax
    case reverbMin
    case reverbMed
    case reverbMax
    case pitchupMin
    case pitchupMed
    case pitchupMax
    case pitchupInsane
    case pitchdownMin
    case pitchdownMed
    case pitchdownMax
    case pitchdownInsane
    case paceupMin
    case paceupMed
    case paceupMax
    case pacedownMin
    case pacedownMed
    case pacedownMax
    case reverse
    case vocoderMin
    case vocoderMed
    case autoTuneMin
    case autoTuneMed
    case autoTuneMax
    case pitchUpDownMin
    case pitchUpDownMed
    case pitchUpDownMax
    case none
    
    ///由于之前的avs库被替换，所以将其中的变音模块提取出来，放入了mediasoup库中，然后这里对其进行引用
    public static func applyWav(_ delegate: AVSAudioEffectProgressDelegate?, inFile: String, outFile: String, effect: AVSAudioEffectType, nr_flag: Bool) -> Int {
        let result =
            AVSAudioEffect().applyWav(delegate, inFile: inFile, outFile: outFile, effect: Int32(effect.rawValue), nr_flag: nr_flag)
        return Int(result)
    }
}
