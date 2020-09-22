//
//  MeetingClientManager.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/9/9.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import SwiftyJSON

extension MediasoupClientManager {
    
    func onReceiveMeetingNotification(with action: MeetingSignalAction.Notification, info: JSON) {
        switch action {
        case .openMute:
            break
        default:break
        }
    
    }
    
}
