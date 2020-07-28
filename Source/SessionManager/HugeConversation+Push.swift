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
    
    ///cid和静音状态的连接符
    static private let separatedString = "&&"
    
    
    @objc(saveWithConversationList:in:)
    public static func save(with conversationList: [ZMConversation], in userId: String) {
        let saveKey = HugeConversationSaveID + "-" + userId
        
        let updateConversations: [String] = conversationList.compactMap { conv in
            guard let cid = conv.remoteIdentifier?.transportString() else {return nil}
                if conv.mutedMessageTypes == .regular || conv.mutedMessageTypes == .all {
                    return cid + separatedString + "1"
                } else {
                    return cid + separatedString + "0"
                }
        }
        
        UserDefaults.standard.setValue(updateConversations, forKey: saveKey)
    }
    
    ///在本地存储的万人群找出此万人群，并判断是否被静音
    static func muteHugeConversationInBackground(with cid: UUID, in account: Account) -> Bool {
        
        let saveKey = HugeConversationSaveID + "-" + account.userIdentifier.transportString()
        guard let hugeConversations = UserDefaults.standard.value(forKey: saveKey) as? [String] else { return false }
        
        if let str = hugeConversations.first(where: { return $0.contains(cid.uuidString) }) {
            return (str.components(separatedBy: separatedString).last! == "1")
        }
        
        ///当做没有找到万人群
        return true
    }
    
}

extension ZMUserSession {
    
    @objc(saveHugeGroup)
    public func saveHugeGroup() {
        if let hugeGroups = ZMConversation.hugeGroupConversations(in: self.managedObjectContext) as? [ZMConversation] {
            guard let context = self.managedObjectContext else {return}
            let uid = ZMUser.selfUser(in: context).remoteIdentifier.transportString()
            HugeConversationSetting.save(with: hugeGroups, in: uid)
        }
    }
    
}
