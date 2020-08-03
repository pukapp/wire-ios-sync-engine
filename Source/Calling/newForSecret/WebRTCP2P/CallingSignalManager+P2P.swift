//
//  CallingSignalManager+P2P.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/7/25.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

enum WebRTCP2PSignalAction {
    
    enum sendRequest: String {
        case getP2PInfo = "getP2PInfo"
        case forward = "forward"
    }
    
    enum ReceiveRequest: String {
        case forward = "forward"
    }
    
    enum Notification: String {
        case peerOpen = "peerOpen"
    }
    
}

///p2p + sendMessage
extension CallingSignalManager {

    func forwardP2PMessage(_ message: WebRTCP2PMessage) {
        //self.sendSocketRequest(with: "forward", data: message.json)
        
        NotificationCenter.default.post(name: NSNotification.Name("qwer"), object: nil, userInfo: [
                                                                                                   "sdpChange": message])
    }
    
    func requestToGetP2PInfo() -> String? {
        guard let info = sendAckSocketRequest(with: "getP2PInfo", data: nil)  else {
            return nil
        }
        if let ice_server = info["data"].dictionary?["ice_server"]?.string {
            return ice_server
        } else {
            return nil
        }
    }
    

}
