//
//  ZMLocalNotification+Notification.swift
//  WireSyncEngine-ios
//
//  Created by 王杰 on 2020/8/13.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import WireRequestStrategy

extension ZMLocalNotification {
    
    // for each supported event type, use the corresponding notification builder.
    //
    public convenience init?(noticationEvent event: ZMUpdateEvent, conversation: ZMConversation?, managedObjectContext moc: NSManagedObjectContext) {
        var builder: NotificationBuilder?
        
        switch event.type {
        case .conversationOtrMessageAdd,
             .conversationClientMessageAdd,
             .conversationOtrAssetAdd,
             .conversationServiceMessageAdd,
             .conversationJsonMessageAdd,
             .conversationBgpMessageAdd:
            let array = ZMOTRMessage.createNotificationMessage(from: event, in: moc)
            guard let message = array.firstObject as? ZMMessage,
                  let conversation = array.lastObject as? ZMConversation else { return nil }
            builder = NSEMessageNotificationBuilder(message: message, conversation: conversation)
            
        case .conversationAppMessageAdd:
            guard let systemMessage = ZMSystemMessage.createOrUpdate(from: event, in: moc, prefetchResult: nil) else {
                return nil
            }
            builder = NSEMessageNotificationBuilder(message: systemMessage)
            
        case .conversationCreate:
            builder = ConversationCreateEventNotificationBuilder(event: event, conversation: conversation, managedObjectContext: moc)
            
        case .conversationDelete:
            builder = ConversationDeleteEventNotificationBuilder(event: event, conversation: conversation, managedObjectContext: moc)
            
        case .userConnection:
            builder = UserConnectionEventNotificationBuilder(event: event, conversation: conversation, managedObjectContext: moc)
            
        case .userContactJoin:
            builder = NewUserEventNotificationBuilder(event: event, conversation: conversation, managedObjectContext: moc)
            
        default:
            builder = nil
        }
        
        if let builder = builder {
            self.init(conversation: conversation, builder: builder)
        } else {
            return nil
        }
    }
    
}
