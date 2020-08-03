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
struct CallingSignalRequest {
    let request: Bool
    let method: String
    let id: Int
    let data: JSON
    
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

struct CallingSignalResponse {
    let response: Bool
    let ok: Bool
    let id: Int
    let data: JSON?
    
    init(response: Bool, ok: Bool, id: Int, data: JSON?) {
        self.response = response
        self.ok = ok
        self.id = id
        self.data = data
    }
    
    init(json: JSON) {
        self.response = json["response"].boolValue
        self.ok = json["ok"].boolValue
        self.data = json["data"]
        self.id = json["id"].intValue
    }
    
    func jsonString() -> String {
        let json: JSON = ["response": response,
                          "ok": ok,
                          "id": id,
                          "data": ""]
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
