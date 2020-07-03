// 
// Wire
// Copyright (C) 2016 Wire Swiss GmbH
// 
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
// 
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
// 
// You should have received a copy of the GNU General Public License
// along with this program. If not, see http://www.gnu.org/licenses/.
// 


@import Foundation;
@import CoreData;
@import WireRequestStrategy;

extern NSString * _Nullable const ConversationsPath;

extern NSString * _Nullable const ConversationServiceMessageAdd;
extern NSString * _Nullable const ConversationOtrMessageAdd;
extern NSString * _Nullable const ConversationUserConnection;

@protocol ZMObjectStrategyDirectory;

@class ZMAuthenticationStatus;
@class SyncStatus;

@interface ZMConversationTranscoder : ZMAbstractRequestStrategy <ZMObjectStrategy>

- (instancetype _Nonnull)initWithManagedObjectContext:(NSManagedObjectContext * _Nullable)moc applicationStatus:(id<ZMApplicationStatus> _Nullable)applicationStatus NS_UNAVAILABLE;

- (instancetype _Nullable)initWithManagedObjectContext:(NSManagedObjectContext * _Nullable)managedObjectContext
                           applicationStatus:(id<ZMApplicationStatus> _Nullable)applicationStatus
                 localNotificationDispatcher:(id<PushMessageHandler> _Nullable)localNotificationDispatcher
                                  syncStatus:(SyncStatus * _Nullable)syncStatus;

- (ZMConversation *_Nullable)createOneOnOneConversationFromTransportData:(NSDictionary *_Nullable)transportData
                                                           type:(ZMConversationType const)type
                                                         serverTimeStamp:(NSDate *_Nullable)serverTimeStamp;

@property (nonatomic) NSUInteger conversationPageSize;
@property (nonatomic, weak, readonly) id<PushMessageHandler> _Nullable localNotificationDispatcher;

@end
