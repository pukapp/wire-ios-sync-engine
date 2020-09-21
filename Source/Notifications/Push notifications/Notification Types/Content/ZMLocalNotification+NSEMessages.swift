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
        let silenced = { [weak self] () -> Bool  in
            
            guard let self = self else {return true}
            
            guard let sender = self.message.sender, !sender.isSelfUser else {
                return true
            }
            
            if self.conversation.mutedMessageTypesIncludingAvailability == .none {
                return false
            }
            
            guard let textMessageData = self.message.textMessageData else {
                return true
            }
            
            if self.conversation.mutedMessageTypesIncludingAvailability == .regular && (textMessageData.isMentioningSelf || textMessageData.isQuotingSelf) {
                return false
            } else {
               return true
            }
        }
        
        return !silenced()
    }
    
}
