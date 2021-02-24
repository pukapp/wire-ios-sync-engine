//
//  CallType.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2021/2/24.
//  Copyright © 2021 Zeta Project Gmbh. All rights reserved.
//

import Foundation

/**
 * Possible types of conversation in which calls can be initiated.
 */

public enum CallRoomType: Int32 {
    case oneToOne = 0
    case group = 1
    case conference = 2
}
