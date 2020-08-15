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
             .conversationMemberJoinask,
             .conversationBgpMessageAdd:
            guard let message = ZMOTRMessage.createOrUpdate(from: event, in: moc, prefetchResult: nil) else { return nil}
            message.markAsSent()
            builder = MessageNotificationBuilder(message: message)
        
            
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

        let conversationTranscoder = ZMConversationTranscoder(managedObjectContext: moc, applicationStatus: nil, localNotificationDispatcher: nil, syncStatus: nil)
        let userPropertyStrategy = UserPropertyRequestStrategy(withManagedObjectContext: moc, applicationStatus: nil)
        let pushTokenStrategy = PushTokenStrategy(withManagedObjectContext: moc, applicationStatus: nil, analytics: nil)
        let labelDownstreamRequestStrategy = LabelDownstreamRequestStrategy(withManagedObjectContext: moc, applicationStatus: nil, syncStatus: nil)
        let transcoders = [conversationTranscoder, userPropertyStrategy, pushTokenStrategy, labelDownstreamRequestStrategy]
        transcoders.forEach { (ob) in
            if let o = ob as? ZMEventConsumer {
                o.processEvents([event], liveEvents: true, prefetchResult: nil)
            }
        }
        moc.enqueueDelayedSave()
        
        if let builder = builder {
            self.init(conversation: conversation, builder: builder)
        } else {
            return nil
        }
    }
    
}
