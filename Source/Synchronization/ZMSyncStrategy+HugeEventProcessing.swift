//
//  ZMSyncStrategy+HugeEventProcessing.swift
//  WireSyncEngine-ios
//
//  Created by 王杰 on 2020/11/6.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import WireUtilities

extension ZMSyncStrategy {
    
    static var evevdHugeIds = Set<String>()
    
    @objc(processHugeUpdateEvents:ignoreBuffer:)
    public func processHuge(updateEvents: [ZMUpdateEvent], ignoreBuffer: Bool) {
        if ignoreBuffer || isReadyToProcessEvents {
            consume(updateEvents: updateEvents)
        } else {
            Logging.eventProcessing.info("Huge Buffering \(updateEvents.count) event(s)")
            updateEvents.forEach(hugeEventsBuffer.addUpdateEvent)
        }
    }
    
    @objc(consumeHugeUpdateEvents:)
    public func consumeHuge(updateEvents: [ZMUpdateEvent]) {
        let date = Date()
        let fetchRequest = prefetchRequest(updateEvents: updateEvents)
        let prefetchResult = syncMOC.executeFetchRequestBatchOrAssert(fetchRequest)
        
        Logging.eventProcessing.info("Consuming: [\n\(updateEvents.map({ "\tevent: \(ZMUpdateEvent.eventTypeString(for: $0.type) ?? "Unknown")" }).joined(separator: "\n"))\n]")
        
        for event in updateEvents {
            let date1 = Date()
            guard let uuid = event.uuid?.transportString() else {continue}
            if ZMSyncStrategy.evevdHugeIds.contains(uuid) {
                ZMSyncStrategy.evevdHugeIds.remove(uuid)
                continue
            }
            if event.senderClientID() == ZMUser.selfUser(in: moc).selfClient()?.remoteIdentifier {
                continue
            }
            ZMSyncStrategy.evevdHugeIds.insert(uuid)
            for eventConsumer in self.eventConsumers {
                eventConsumer.processEvents([event], liveEvents: true, prefetchResult: prefetchResult)
            }
            let time = -date1.timeIntervalSinceNow
            // 打印处理时间超过0.001的事件
            if time > 0.001 {
                Logging.eventProcessing.debug("Event processed in \(time): \(event.type.stringValue ?? ""))")
            }
            self.eventProcessingTracker?.registerEventProcessed()
            let time1 = -date1.timeIntervalSinceNow
            // 打印处理时间超过0.001的事件
            if time1 > 0.001 {
                Logging.eventProcessing.debug("Event processed and registerEvent in \(time): \(event.type.stringValue ?? ""))")
            }
        }
        
        Logging.eventProcessing.debug("\(updateEvents.count) Events processed and registerEvent in \(-date.timeIntervalSinceNow)")
        
        let date1 = Date()
        localNotificationDispatcher?.processEvents(updateEvents, liveEvents: true, prefetchResult: nil)
        Logging.eventProcessing.debug("localNotificationDispatcher?.processEvents in \(-date1.timeIntervalSinceNow)")
        
        let date2 = Date()
        if let messages = fetchRequest.noncesToFetch as? Set<UUID>,
            messages.count > 0,
            let conversations = fetchRequest.remoteIdentifiersToFetch as? Set<UUID> {
            let confirmationMessages = ZMConversation.confirmDeliveredMessages(messages, in: conversations, with: syncMOC)
            for message in confirmationMessages {
                self.applicationStatusDirectory?.deliveryConfirmation.needsToConfirmMessage(message.nonce!)
            }
            Logging.eventProcessing.debug("ConfirmMessage:\(confirmationMessages.count) in \(-date2.timeIntervalSinceNow)")
        }
        
        syncMOC.saveOrRollback()
        Logging.eventProcessing.debug("syncMOC.saveOrRollback()")
        
        Logging.eventProcessing.debug("\(updateEvents.count) Events processed in \(-date.timeIntervalSinceNow): \(self.eventProcessingTracker?.debugDescription ?? "")")
        let time = -date.timeIntervalSinceNow
        // 打印处理时间超过10的一组事件
        if time > 10 {
            Logging.eventProcessing.debug("\(updateEvents.count) Events processed over 10 in \(time)")
        }
        
    }
    
}

