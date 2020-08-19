//
//  CallingSignalModel.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/7/22.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

/*
 * Request和Response一一对应，服务器端发送了request，则客户端需回应response，否则会报错
 * Notification则只需要接收，无需任何响应
 */
class CallingSignalRequest {
    let request: Bool
    let method: String
    let id: Int
    let data: JSON
    
    var peerId: String?
    var roomId: String?
    
    init(method: String, data: JSON?) {
        self.request = true
        self.method = method
        self.data = data ?? ""
        self.id = Int(arc4random())
    }
    
    init(json: JSON) {
        self.request = json["request"].boolValue
        self.method = json["method"].stringValue
        self.data = json["data"]
        self.id = json["id"].intValue
        
        self.peerId = json["peerId"].string
        self.roomId = json["roomId"].string
    }
    
    func jsonString() -> String {
        let json: JSON = ["request": request,
                          "method": method,
                          "id": id,
                          "data": data
        ]
        return json.description
    }
    
}

class CallingSignalForwardMessage: CallingSignalRequest {
    var toId: String?
    
    init(toId: String, method: String, data: JSON?) {
        self.toId = toId
        super.init(method: method, data: data)
    }
    
    override func jsonString() -> String {
        let json: JSON = ["request": request,
                          "method": method,
                          "id": id,
                          "data": data,
                          "toId": toId!
        ]
        return json.description
    }
}

struct CallingSignalResponse {
    let response: Bool
    let ok: Bool
    let id: Int
    let data: JSON?
    
    var method: String?
    var roomId: String?
    var peerId: String?
    
    init(response: Bool, ok: Bool, id: Int, data: JSON?, method: String? = nil, roomId: String? = nil, peerId: String? = nil) {
        self.response = response
        self.ok = ok
        self.id = id
        self.data = data
        
        self.roomId = roomId
        self.method = method
        self.peerId = peerId
    }
    
    init(json: JSON) {
        self.response = json["response"].boolValue
        self.ok = json["ok"].boolValue
        self.data = json["data"]
        self.id = json["id"].intValue
        
        self.method = json["method"].string
        self.roomId = json["roomId"].string
        self.peerId = json["peerId"].string
    }
    
    func jsonString() -> String {
        let json: JSON = ["response": response,
                          "ok": ok,
                          "id": id,
                          "data": "",
                          "method": method ?? "",
                          "roomId": roomId ?? "",
                          "peerId": peerId ?? ""]
        return json.description
    }
}

struct CallingSignalNotification {
    
    let notification: Bool
    let method: String
    let data: JSON
    
    init(json: JSON) {
        self.notification = json["notification"].boolValue
        self.method = json["method"].stringValue
        self.data = json["data"]
    }
    
    func jsonString() -> String {
        let json: JSON = ["notification": notification,
                          "method": method,
                          "data": data
        ]
        return json.description
    }
    
}
