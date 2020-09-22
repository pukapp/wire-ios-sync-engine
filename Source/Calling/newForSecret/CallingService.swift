//
//  MediasoupService.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/6/2.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

let MediasoupServiceURL = "https://143.92.53.170:4000/api/getConfigInfo"

struct CallingConfigure {
    struct Gateway {
        let ip: String
        let port: UInt
        var vaild: Bool
        
        var webSocketUrlString: String {
            return "wss://\(ip):\(port)"
        }
    }
    
    // ip:port
    let gateways: [Gateway]
    /*
     [{
         "username" : "",
         "urls" : [
           "turn:stun.stunprotocol.org:3478"
         ],
         "credential" : ""
       }]
     */
    let iceServers: [JSON]
    
    init?(json: JSON) {
        guard let gateways = json["gateways"].array else {
            return nil
        }
        self.gateways = gateways.compactMap({
            if let ip = $0["ip"].string, let port = $0["port"].uInt {
                return Gateway(ip: ip, port: port, vaild: true)
            } else {
                return nil
            }
        })
        
        guard let ice_servers = json["p2p"].dictionary?["ice_servers"]?.array else {
            return nil
        }
        self.iceServers = ice_servers
    }
    
    ///返回有效的webSocket地址
    var vaildGateway: String? {
        return self.gateways.first(where: { return ($0.ip.contains("143")) })?.webSocketUrlString
    }
}

///https服务
class CallingService: NSObject {
    
    static let shared = CallingService()
    
    ///获取mediasoup所需的gatewap服务器，以及p2p所需要的stun服务器
    static func getConfigInfo(completionHandler: @escaping (CallingConfigure?) -> Void) {
        var request = URLRequest.init(url: URL(string: MediasoupServiceURL)!)
        request.httpMethod = "POST"
        let conf = URLSessionConfiguration.default
        let session = URLSession.init(configuration: conf, delegate: CallingService.shared, delegateQueue: nil)
        let dataTask = session.dataTask(with: request) { (data, respons, error) in
            if let data = data,
                let json = try? JSON(data: data),
                let code = json["code"].int,
                code == 200 {
                print("[calling] CallingService getConfigInfo : \(json)")
                let room = CallingConfigure(json: json["data"])
                completionHandler(room)
                return
            }
            completionHandler(nil)
        }
        dataTask.resume()
    }
    
    
}

extension CallingService: URLSessionDelegate {
    
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        //这里检查质询的验证方式是否是服务器端证书验证
        if challenge.protectionSpace.authenticationMethod  == "NSURLAuthenticationMethodServerTrust" {
            let trustRef = challenge.protectionSpace.serverTrust
            let trustCredential = URLCredential.init(trust: trustRef!)
            completionHandler(URLSession.AuthChallengeDisposition.useCredential, trustCredential)
        } else {
            completionHandler(URLSession.AuthChallengeDisposition.performDefaultHandling, nil)
        }
    }
    
}
