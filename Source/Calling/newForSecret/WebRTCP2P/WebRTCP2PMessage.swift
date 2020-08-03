//
//  Message.swift
//  WebRTC-Demo
//
//  Created by Stasel on 20/02/2019.
//  Copyright © 2019 Stasel. All rights reserved.
//

import Foundation
import WebRTC
import SwiftyJSON

/// This enum is a swift wrapper over `RTCSdpType` for easy encode and decode
enum SdpType: String {
    case offer, answer
    
    var rtcSdpType: RTCSdpType {
        switch self {
        case .offer:    return .offer
        case .answer:   return .answer
        }
    }
}

/// This struct is a swift wrapper over `RTCSessionDescription` for easy encode and decode
struct SessionDescription {
    let sdp: String
    let type: SdpType
    
    init(from rtcSessionDescription: RTCSessionDescription) {
        self.sdp = rtcSessionDescription.sdp
        
        switch rtcSessionDescription.type {
        case .offer:    self.type = .offer
        case .answer:   self.type = .answer
        @unknown default:
            fatalError("Unknown RTCSessionDescription type: \(rtcSessionDescription.type.rawValue)")
        }
    }
    
    init(json: JSON) {
        self.type = SdpType(rawValue: json["type"].stringValue)!
        self.sdp = json["sdp"].stringValue
    }
    
    var json: JSON {
        let data:JSON = ["type": type.rawValue, "sdp": sdp]
        return data
    }
    
    var rtcSessionDescription: RTCSessionDescription {
        return RTCSessionDescription(type: self.type.rtcSdpType, sdp: self.sdp)
    }
}

/// This struct is a swift wrapper over `RTCIceCandidate` for easy encode and decode
struct IceCandidate: Codable {
    let sdp: String
    let sdpMLineIndex: Int32
    let sdpMid: String?
    
    init(from iceCandidate: RTCIceCandidate) {
        self.sdpMLineIndex = iceCandidate.sdpMLineIndex
        self.sdpMid = iceCandidate.sdpMid
        self.sdp = iceCandidate.sdp
    }
    
    init(json: JSON) {
        self.sdp = json["sdp"].stringValue
        self.sdpMLineIndex = json["sdpMLineIndex"].int32Value
        self.sdpMid = json["sdpMid"].string
    }
    
    var json: JSON {
        let data:JSON = ["sdp": sdp,
                         "sdpMLineIndex": sdpMLineIndex,
                         "sdpMid": sdpMid ?? ""]
        return data
    }
    
    var rtcIceCandidate: RTCIceCandidate {
        return RTCIceCandidate(sdp: self.sdp, sdpMLineIndex: self.sdpMLineIndex, sdpMid: self.sdpMid)
    }
}

enum WebRTCP2PMessage {
    case sdp(SessionDescription)
    case candidate(IceCandidate)
    case videoState(VideoState)
    case isReady //适用于answer端发信息给offer端，自己已经连接上websocket，offer可以发sdp信息了
    case switchMode
}

extension WebRTCP2PMessage {
    
    init(json: JSON) {
        let type = json["type"].stringValue
        if type == "sdp" {
            self = .sdp(SessionDescription(json: json["sdp"]))
        } else if type == "candidate" {
            self = .candidate(IceCandidate(json: json["candidate"]))
        } else if type == "videoState" {
            self = .videoState(VideoState(rawValue: json["state"].int32Value) ?? .stopped)
        } else if type == "switchMode" {
            self = .switchMode
        } else if type == "isReady" {
            self = .isReady
        } else {
            fatal("wrong p2p message")
        }
    }
    
    var json: JSON {
        var data:JSON
        switch self {
        case .sdp(let sdp):
            data = ["type": "sdp", "sdp": sdp.json]
        case .candidate(let candidate):
            data = ["type": "candidate", "candidate": candidate.json]
        case .videoState(let state):
            data = ["type": "videoState", "state": state.rawValue]
        case .switchMode:
            data = ["type": "switchMode"]
        case .isReady:
            data = ["type": "isReady"]
        }
        return data
    }
    
}

