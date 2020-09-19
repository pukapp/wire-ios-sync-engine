//
//  ZMLocalNotification+NSEMessages.swift
//  WireSyncEngine-ios
//
//  Created by 王杰 on 2020/9/18.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation

public class NSEMessageNotificationBuilder: MessageNotificationBuilder  {
    
    override func shouldCreateNotification() -> Bool {
        guard !message.isSilenced else {
            return false
        }
        return true;
    }
    
}
