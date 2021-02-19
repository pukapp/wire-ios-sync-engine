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
            let message = ZMOTRMessage.createOrUpdate(from: event, in: moc, prefetchResult: nil)
            guard let msg = message else {return nil}
            builder = NSEMessageNotificationBuilder(message: msg)
            msg.markAsSent()
            
        case .conversationAppMessageAdd,
            .conversationMemberLeave,
            .conversationMemberJoin:
            guard let systemMessage = ZMSystemMessage.createOrUpdate(from: event, in: moc, prefetchResult: nil) else {
                return nil
            }
            // 和自己无关的加人删人消息 过滤
            if let sysMessage = systemMessage as? ZMSystemMessage,  (sysMessage.systemMessageType == .participantsAdded ||
                sysMessage.systemMessageType == .participantsRemoved) {
                let selfUser = ZMUser.selfUser(in: moc)
                
                if sysMessage.sender?.remoteIdentifier.transportString() == selfUser.remoteIdentifier.transportString() {
                    return nil
                }
                
                if !sysMessage.userIDs.contains(selfUser.remoteIdentifier.transportString()) {
                    return nil
                }
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
        
        //编辑的消息 不入库
        let genericMessage = ZMGenericMessage(from: event)
        if genericMessage == nil || !(genericMessage!.hasEdited()) {
            moc.saveOrRollback()
        }

        if let builder = builder {
            self.init(conversation: conversation, builder: builder)
        } else {
            return nil
        }
    }
    
}
