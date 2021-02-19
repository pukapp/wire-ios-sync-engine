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
    
    @objc(processHugeUpdateEvents:ignoreBuffer:)
    public func processHuge(updateEvents: [ZMUpdateEvent], ignoreBuffer: Bool) {
        if ignoreBuffer || isReadyToProcessEvents {
            consumeHuge(updateEvents: updateEvents)
        } else {
            Logging.hugeEventProcessing.info("Huge Buffering \(updateEvents.count) event(s)")
            updateEvents.forEach(hugeEventsBuffer.addUpdateEvent)
        }
    }
    
    @objc(consumeHugeUpdateEvents:)
    public func consumeHuge(updateEvents: [ZMUpdateEvent]) {
        
        hugeEventDecoder.processEvents(updateEvents) { [weak self] (processUpdateEvents) in
            guard let `self` = self else { return }
            
            let date = Date()
            let fetchRequest = prefetchHugeRequest(updateEvents: updateEvents)
            let prefetchResult = syncMOC.executeFetchRequestBatchOrAssert(fetchRequest)
            
            Logging.hugeEventProcessing.info("Consuming: [\n\(updateEvents.map({ "\tevent: \(ZMUpdateEvent.eventTypeString(for: $0.type) ?? "Unknown")" }).joined(separator: "\n"))\n]")
            
            let selfClientIdentifier = ZMUser.selfUser(in: moc).selfClient()?.remoteIdentifier
            
            for event in updateEvents {
                let date1 = Date()
                if event.senderClientID() == selfClientIdentifier {
                    continue
                }
                //万人群websocket 不会重复给自己的设备推了 这段逻辑暂时注释
//                if self.isRepeatEvent(event) {
//                    continue
//                }
                for eventConsumer in self.eventConsumers {
                    eventConsumer.processEvents([event], liveEvents: true, prefetchResult: prefetchResult)
                }
                let time = -date1.timeIntervalSinceNow
                // 打印处理时间超过0.001的事件
                if time > 0.001 {
                    Logging.hugeEventProcessing.debug("Event processed in \(time): \(event.type.stringValue ?? ""))")
                }
                self.eventProcessingTracker?.registerEventProcessed()
                let time1 = -date1.timeIntervalSinceNow
                // 打印处理时间超过0.001的事件
                if time1 > 0.001 {
                    Logging.hugeEventProcessing.debug("Event processed and registerEvent in \(time): \(event.type.stringValue ?? ""))")
                }
            }
            
            Logging.hugeEventProcessing.debug("\(updateEvents.count) Events processed and registerEvent in \(-date.timeIntervalSinceNow)")
            
            let date1 = Date()
            localNotificationDispatcher?.processEvents(updateEvents, liveEvents: true, prefetchResult: nil)
            Logging.hugeEventProcessing.debug("localNotificationDispatcher?.processEvents in \(-date1.timeIntervalSinceNow)")
            
            syncMOC.saveOrRollback()
            Logging.hugeEventProcessing.debug("syncMOC.saveOrRollback()")
            
            Logging.hugeEventProcessing.debug("\(updateEvents.count) Events processed in \(-date.timeIntervalSinceNow): \(self.eventProcessingTracker?.debugDescription ?? "")")
            let time = -date.timeIntervalSinceNow
            // 打印处理时间超过10的一组事件
            if time > 10 {
                Logging.hugeEventProcessing.debug("\(updateEvents.count) Events processed over 10 in \(time)")
            }
            
        }

    }
    
//    func isRepeatEvent(_ event: ZMUpdateEvent) -> Bool {
//        guard let uuid = event.uuid?.transportString() else {return true}
//        let uuidnString = uuid as NSString
//        let TRUE = "true" as NSString
//        if self.evevdHugeIdCaches.object(forKey: uuidnString) == TRUE {
//            self.evevdHugeIdCaches.removeObject(forKey: uuidnString)
//            return true
//        }
//        self.evevdHugeIdCaches.setObject(TRUE, forKey: uuidnString)
//        return false
//    }
    
}

