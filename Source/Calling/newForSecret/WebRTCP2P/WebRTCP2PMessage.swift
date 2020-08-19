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
    let candidate: String
    let label: Int32
    let id: String?
    
    init(from iceCandidate: RTCIceCandidate) {
        self.label = iceCandidate.sdpMLineIndex
        self.id = iceCandidate.sdpMid
        self.candidate = iceCandidate.sdp
    }
    
    init(json: JSON) {
        self.candidate = json["candidate"].stringValue
        self.label = json["label"].int32Value
        self.id = json["id"].string
    }
    
    var json: JSON {
        let data:JSON = ["candidate": candidate,
                         "label": label,
                         "id": id ?? ""]
        return data
    }
    
    var rtcIceCandidate: RTCIceCandidate {
        return RTCIceCandidate(sdp: self.candidate, sdpMLineIndex: self.label, sdpMid: self.id)
    }
}

enum RoomMode: String {
    case p2p        = "p2p"
    case chat       = "chat"
    case meeting    = "meeting"
}

enum WebRTCP2PMessage {
    case sdp(SessionDescription)
    case candidate(IceCandidate)
    case videoState(VideoState)
    case restart //Answer发给offer端，offer端接收时需要重新创建offer
    case switchMode(RoomMode)
}

extension WebRTCP2PMessage {
    
    init(json: JSON) {
        let type = json["type"].stringValue
        if type == "sdp" {
            self = .sdp(SessionDescription(json: json["data"]))
        } else if type == "ice" {
            self = .candidate(IceCandidate(json: json["data"]))
        } else if type == "video_state" {
            self = .videoState(VideoState(rawValue: json["data"].int32Value) ?? .stopped)
        } else if type == "restart" {
            self = .restart
        } else if type == "switch_mode" {
            self = .switchMode(RoomMode(rawValue: json["data"].stringValue) ?? .chat)
        } else {
            fatal("wrong p2p message")
        }
    }
    
    var json: JSON {
        var data:JSON
        switch self {
        case .sdp(let sdp):
            data = ["type": "sdp", "data": sdp.json]
        case .candidate(let candidate):
            data = ["type": "ice", "data": candidate.json]
        case .videoState(let state):
            data = ["type": "video_state", "data": state.rawValue]
        case .restart:
            data = ["type": "restart"]
        case .switchMode(let mode):
            data = ["type": "switch_mode", "data": mode.rawValue]
        }
        return data
    }
    
}

