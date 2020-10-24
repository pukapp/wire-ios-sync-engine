//
//  HugeConversation+Push.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2019/12/27.
//  Copyright © 2019 Zeta Project Gmbh. All rights reserved.
//

import Foundation

@objc
public class HugeConversationSetting: NSObject {
    
    static private let HugeConversationSaveID = "HugeConversationSaveID"
    
    @objc(saveWithConversationList:in:)
    public static func save(with conversationList: [ZMConversation], in userId: String) {
        let saveKey = HugeConversationSaveID + "-" + userId
        let noMuteConversations = conversationList.filter { (conversation) -> Bool in
            return conversation.mutedMessageTypes == .none
        }
        let idsSet = Array(Set(noMuteConversations.compactMap {$0.remoteIdentifier?.transportString()}))
        UserDefaults.standard.setValue(idsSet, forKey: saveKey)
    }
    
    ///在本地存储的万人群找出此万人群，并判断是否被静音
    static func muteHugeConversationInBackground(with cid: UUID, userId: String) -> Bool {
        let saveKey = HugeConversationSaveID + "-" + userId
        guard let ids = UserDefaults.standard.value(forKey: saveKey) as? [String] else { return false }
        return !Set(ids).contains(cid.transportString())
    }
    
}

@objc extension ZMUserSession {
    
    public func saveHugeGroup() {
        if let hugeGroups = ZMConversation.hugeGroupConversations(in: self.managedObjectContext) as? [ZMConversation] {
            guard let context = self.managedObjectContext else {return}
            let uid = ZMUser.selfUser(in: context).remoteIdentifier.transportString()
            HugeConversationSetting.save(with: hugeGroups, in: uid)
        }
    }
    
}
