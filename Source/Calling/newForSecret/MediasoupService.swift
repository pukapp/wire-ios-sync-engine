//
//  MediasoupService.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/6/2.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

struct MediasoupRoom {
    let roomUrl:        String
    let roomHost:       String
    let roomId:         String
    let roomCreaterId:  String
    
    init(json: JSON) {
        self.roomUrl = json["roomUrl"].stringValue
        self.roomHost = json["roomHost"].stringValue
        self.roomId = json["roomId"].stringValue
        self.roomCreaterId = json["roomCreaterId"].stringValue
    }
}

///https服务
class MediasoupService {
    
    static let MediasoupServiceURL: String = "192.168.3.66"
    
    ///每次打电话时需要获取下房间信息
    static func requestRoomInfo(with cid: String, uid: String, completionHandler: @escaping (MediasoupRoom?) -> Void) {
        var request = URLRequest.init(url: URL(string: MediasoupServiceURL)!)
        request.httpMethod = "POST"
        let accessKey = ""
        let param = "useId=\(uid)&groupId=\(cid)&appId=secret.im&accessKey=\(accessKey)"
        request.httpBody = param.data(using: .utf8)
        
        let session = URLSession.shared
        let dataTask = session.dataTask(with: request) { (data, respons, error) in
            
            if let data = data,
                let json = try? JSON(data: data),
                let code = json["code"].int,
                code == 200 {
                let room = MediasoupRoom(json: json["data"])
                completionHandler(room)
                return
            }
            
            completionHandler(nil)
        }
        dataTask.resume()
    }
    
}
