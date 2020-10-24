//
//  SessionManager+saveNoMuteHugeConversations.swift
//  WireSyncEngine-ios
//
//  Created by 王杰 on 2020/10/24.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation

extension SessionManager {
    
    @objc func saveNoMuteHugeConversations() {
        if #available(iOS 13.3, *) {
            return
        }
        for (_, session) in backgroundUserSessions {
            if session.isAuthenticated() {
                session.saveHugeGroup()
            }
        }
    }
    
}
