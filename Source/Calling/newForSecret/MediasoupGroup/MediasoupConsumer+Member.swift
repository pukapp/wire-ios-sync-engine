//
//  MediasoupConsumer+Member.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/7/24.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import Mediasoupclient

class MediasoupPeerConsumer {
    
    let peerId: UUID
    private var consumers: [Consumer] = []
    private var consumerListeners: [MediasoupConsumerListener] = []
    
    init(peerId: UUID) {
        self.peerId = peerId
    }
    
    func addConsumer(_ consumer: Consumer, listener: MediasoupConsumerListener) {
        self.consumers.append(consumer)
        self.consumerListeners.append(listener)
    }
    
    func removeConsumer(_ id: String) {
        self.consumers = self.consumers.filter({ return $0.getId() != id })
        self.consumerListeners = self.consumerListeners.filter({ return $0.consumerId != id })
    }
    
    func clear() {
        self.consumers.forEach({ $0.close() })
        self.consumers.removeAll()
        self.consumerListeners.removeAll()
    }
    
    func consumer(with id: String) -> Consumer? {
        return self.consumers.first(where: { return $0.getId() == id })
    }
    
}
