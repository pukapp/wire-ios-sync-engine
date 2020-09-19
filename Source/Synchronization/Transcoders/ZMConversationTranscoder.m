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


@import WireSystem;
@import WireUtilities;
@import WireTransport;
@import WireDataModel;
@import WireRequestStrategy;

#import "ZMConversationTranscoder.h"
#import "ZMAuthenticationStatus.h"
#import <WireSyncEngine/WireSyncEngine-Swift.h>

static NSString* ZMLogTag ZM_UNUSED = @"Conversations";

NSString *const ConversationsPath = @"/conversations";

NSString *const V3Assetspath = @"/assets/v3";

NSString *const ConversationServiceMessageAdd = @"ConversationServiceMessageAdd";
NSString *const ConversationOtrMessageAdd = @"ConversationOtrMessageAdd";
NSString *const ConversationUserConnection = @"ConversationUserConnection";

static NSString *const ConversationIDsPath = @"/conversations/ids";

NSUInteger ZMConversationTranscoderListPageSize = 100;
const NSUInteger ZMConversationTranscoderDefaultConversationPageSize = 32;

static NSString *const UserInfoTypeKey = @"type";
static NSString *const UserInfoUserKey = @"user";
static NSString *const UserInfoAddedValueKey = @"added";
static NSString *const UserInfoRemovedValueKey = @"removed";


static NSString *const ConversationTeamKey = @"team";
static NSString *const ConversationAccessKey = @"access";
static NSString *const ConversationAccessRoleKey = @"access_role";
static NSString *const ConversationTeamIdKey = @"teamid";
static NSString *const ConversationTeamManagedKey = @"managed";

@interface ZMConversationTranscoder () <ZMSimpleListRequestPaginatorSync>

@property (nonatomic) ZMUpstreamModifiedObjectSync *modifiedSync;
@property (nonatomic) ZMUpstreamInsertedObjectSync *insertedSync;

@property (nonatomic) ZMDownstreamObjectSync *downstreamSync;
@property (nonatomic) ZMRemoteIdentifierObjectSync *remoteIDSync;
@property (nonatomic) ZMSimpleListRequestPaginator *listPaginator;

@property (nonatomic, weak) SyncStatus *syncStatus;
@property (nonatomic, weak) id<PushMessageHandler> localNotificationDispatcher;
@property (nonatomic) NSMutableOrderedSet<ZMConversation *> *lastSyncedActiveConversations;

@end


@interface ZMConversationTranscoder (DownstreamTranscoder) <ZMDownstreamTranscoder>
@end


@interface ZMConversationTranscoder (UpstreamTranscoder) <ZMUpstreamTranscoder>
@end


@interface ZMConversationTranscoder (PaginatedRequest) <ZMRemoteIdentifierObjectTranscoder>
@end


@implementation ZMConversationTranscoder

- (instancetype)initWithManagedObjectContext:(NSManagedObjectContext *)moc applicationStatus:(id<ZMApplicationStatus>)applicationStatus;
{
    Require(NO);
    self = [super initWithManagedObjectContext:moc applicationStatus:applicationStatus];
    NOT_USED(self);
    self = nil;
    return self;
}

- (instancetype)initWithManagedObjectContext:(NSManagedObjectContext *)managedObjectContext
                           applicationStatus:(id<ZMApplicationStatus>)applicationStatus
                 localNotificationDispatcher:(id<PushMessageHandler>)localNotificationDispatcher
                                  syncStatus:(SyncStatus *)syncStatus;
{
    self = [super initWithManagedObjectContext:managedObjectContext applicationStatus:applicationStatus];
    if (self) {
        self.localNotificationDispatcher = localNotificationDispatcher;
        self.syncStatus = syncStatus;
        self.lastSyncedActiveConversations = [[NSMutableOrderedSet alloc] init];
        self.modifiedSync = [[ZMUpstreamModifiedObjectSync alloc] initWithTranscoder:self entityName:ZMConversation.entityName updatePredicate:nil filter:nil keysToSync:self.keysToSync managedObjectContext:self.managedObjectContext];
        self.insertedSync = [[ZMUpstreamInsertedObjectSync alloc] initWithTranscoder:self entityName:ZMConversation.entityName managedObjectContext:self.managedObjectContext];
        NSPredicate *conversationPredicate =
        [NSPredicate predicateWithFormat:@"%K != %@ AND (connection == nil OR (connection.status != %d AND connection.status != %d) ) AND needsToBeUpdatedFromBackend == YES",
         [ZMConversation remoteIdentifierDataKey], nil,
         ZMConnectionStatusPending,  ZMConnectionStatusIgnored
         ];
         
        self.downstreamSync = [[ZMDownstreamObjectSync alloc] initWithTranscoder:self entityName:ZMConversation.entityName predicateForObjectsToDownload:conversationPredicate managedObjectContext:self.managedObjectContext];
        self.listPaginator = [[ZMSimpleListRequestPaginator alloc] initWithBasePath:ConversationIDsPath
                                                                           startKey:@"start"
                                                                           pageSize:ZMConversationTranscoderListPageSize
                                                               managedObjectContext:self.managedObjectContext
                                                                    includeClientID:NO
                                                                         transcoder:self];
        self.conversationPageSize = ZMConversationTranscoderDefaultConversationPageSize;
        self.remoteIDSync = [[ZMRemoteIdentifierObjectSync alloc] initWithTranscoder:self managedObjectContext:self.managedObjectContext];
    }
    return self;
}

- (ZMStrategyConfigurationOption)configuration
{
    return ZMStrategyConfigurationOptionAllowsRequestsDuringSync
         | ZMStrategyConfigurationOptionAllowsRequestsDuringEventProcessing;
}

// 只有加入key才能发送请求
- (NSArray<NSString *> *)keysToSync
{
    NSArray *keysWithRef = @[
             ZMConversationArchivedChangedTimeStampKey,
             ZMConversationSilencedChangedTimeStampKey,
             ];
    NSArray *allKeys = [keysWithRef arrayByAddingObjectsFromArray:self.keysToSyncWithoutRef];
    return allKeys;
}
// 只有加入key才能发送请求
- (NSArray<NSString *>*)keysToSyncWithoutRef
{
    // Some keys don't have or are a time reference
    // These keys will always be over written when updating from the backend
    // They might be overwritten in a way that they don't create requests anymore whereas they previously did
    // To avoid crashes or unneccessary syncs, we should reset those when refetching the conversation from the backend
    // 新增了自动回复
    return @[ZMConversationUserDefinedNameKey,
             ZMConversationAutoReplyKey,
             ZMConversationSelfRemarkKey,
             ZMConversationIsOpenCreatorInviteVerifyKey,
             ZMConversationIsOpenMemberInviteVerifyKey,
             ZMConversationOnlyCreatorInviteKey,
             ZMConversationOpenUrlJoinKey,
             ZMConversationAllowViewMembersKey,
             CreatorKey,
             ZMConversationTopWebAppsKey,
             ZMConversationIsVisibleForMemberChangeKey,
             ZMConversationIsAllowMemberAddEachOtherKey,
             ZMConversationIsDisableSendMsgKey,
             ZMConversationInfoOratorKey,
             ZMConversationManagerAddKey,
             ZMConversationManagerDelKey,
             ZMConversationIsPlacedTopKey,
             ZMConversationIsVisitorsVisibleKey,
             ZMConversationIsMessageVisibleOnlyManagerAndCreatorKey,
             ZMConversationAnnouncementKey,
             ZMConversationPreviewAvatarKey,
             ZMConversationCompleteAvatarKey,
             ShowMemsumKey,
             EnabledEditMsgKey
             ];
}

- (NSUUID *)nextUUIDFromResponse:(ZMTransportResponse *)response forListPaginator:(ZMSimpleListRequestPaginator *)paginator
{
    NOT_USED(paginator);
    
    NSDictionary *payload = [response.payload asDictionary];
    NSArray *conversationIDStrings = [payload arrayForKey:@"conversations"];
    NSArray *conversationUUIDs = [conversationIDStrings mapWithBlock:^id(NSString *obj) {
        return [obj UUID];
    }];
    NSSet *conversationUUIDSet = [NSSet setWithArray:conversationUUIDs];
    [self.remoteIDSync addRemoteIdentifiersThatNeedDownload:conversationUUIDSet];
    
    
    if (response.result == ZMTransportResponseStatusPermanentError && self.isSyncing) {
        [self.syncStatus failCurrentSyncPhaseWithPhase:self.expectedSyncPhase];
    }
    
    [self finishSyncIfCompleted];
    
    return conversationUUIDs.lastObject;
}

- (void)finishSyncIfCompleted
{
    if (!self.listPaginator.hasMoreToFetch && self.remoteIDSync.isDone && self.isSyncing) {
        [self updateInactiveConversations:self.lastSyncedActiveConversations];
        [self.lastSyncedActiveConversations removeAllObjects];
        [self.syncStatus finishCurrentSyncPhaseWithPhase:self.expectedSyncPhase];
    }
}

- (void)updateInactiveConversations:(NSOrderedSet<ZMConversation *> *)activeConversations
{
    NSMutableOrderedSet *inactiveConversations = [NSMutableOrderedSet orderedSetWithArray:[self.managedObjectContext executeFetchRequestOrAssert:[ZMConversation sortedFetchRequest]]];
    [inactiveConversations minusOrderedSet:activeConversations];
    
    for (ZMConversation *inactiveConversation in inactiveConversations) {
        if (inactiveConversation.conversationType == ZMConversationTypeGroup) {
            inactiveConversation.needsToBeUpdatedFromBackend = YES;
        }
    }
}

- (SyncPhase)expectedSyncPhase
{
    return SyncPhaseFetchingConversations;
}

- (BOOL)isSyncing
{
    return self.syncStatus.currentSyncPhase == self.expectedSyncPhase;
}

- (ZMTransportRequest *)nextRequestIfAllowed
{
    if (self.isSyncing && self.listPaginator.status != ZMSingleRequestInProgress && self.remoteIDSync.isDone) {
        [self.listPaginator resetFetching];
        [self.remoteIDSync setRemoteIdentifiersAsNeedingDownload:[NSSet set]];
    }
    
    return [self.requestGenerators nextRequest];
}

- (NSArray *)contextChangeTrackers
{
    return @[self.downstreamSync, self.insertedSync, self.modifiedSync];
}

- (NSArray *)requestGenerators;
{
    if (self.isSyncing) {
        return  @[self.listPaginator, self.remoteIDSync];
    } else {
        return  @[self.downstreamSync, self.insertedSync, self.modifiedSync];
    }
}

- (ZMConversation *)createConversationFromTransportData:(NSDictionary *)transportData
                                        serverTimeStamp:(NSDate *)serverTimeStamp
                                                 source:(ZMConversationSource)source
{
    // If the conversation is not a group conversation, we need to make sure that we check if there's any existing conversation without a remote identifier for that user.
    // If it is a group conversation, we don't need to.
    
    NSNumber *typeNumber = [transportData numberForKey:@"type"];
    VerifyReturnNil(typeNumber != nil);
    ZMConversationType const type = [ZMConversation conversationTypeFromTransportData:typeNumber];

    if (type == ZMConversationTypeGroup  ||
        type == ZMConversationTypeHugeGroup ||
        type == ZMConversationTypeSelf) {
        return [self createGroupOrSelfConversationFromTransportData:transportData serverTimeStamp:serverTimeStamp source: source];
    } else {
        return [self createOneOnOneConversationFromTransportData:transportData type:type serverTimeStamp:serverTimeStamp];
    }
}

- (ZMConversation *)createOneOnOneConversationFromTransportData:(NSDictionary *)transportData
                                                           type:(ZMConversationType const)type
                                                serverTimeStamp:(NSDate *)serverTimeStamp;
{
    NSUUID * const convRemoteID = [transportData uuidForKey:@"id"];
    if(convRemoteID == nil) {
        ZMLogError(@"Missing ID in conversation payload");
        return nil;
    }
    
    // Get the 'other' user:
    NSDictionary *members = [transportData dictionaryForKey:@"members"];
    
    NSArray *others = [members arrayForKey:@"others"];

    if ((type == ZMConversationTypeConnection) && (others.count == 0)) {
        // But be sure to update the conversation if it already exists:
        ZMConversation *conversation = [ZMConversation conversationWithRemoteID:convRemoteID createIfNeeded:NO inContext:self.managedObjectContext];
        if ((conversation.conversationType != ZMConversationTypeOneOnOne) &&
            (conversation.conversationType != ZMConversationTypeConnection))
        {
            conversation.conversationType = type;
        }
        
        // Ignore everything else since we can't find out which connection it belongs to.
        return conversation;
    }
    
    VerifyReturnNil(others.count != 0); // No other users? Self conversation?
    VerifyReturnNil(others.count < 2); // More than 1 other user in a conversation that's not a group conversation?
    
    NSUUID *otherUserRemoteID = [[others[0] asDictionary] uuidForKey:@"id"];
    VerifyReturnNil(otherUserRemoteID != nil); // No remote ID for other user?
    
    ZMUser *user = [ZMUser userWithRemoteID:otherUserRemoteID createIfNeeded:YES inContext:self.managedObjectContext];
    ZMConversation *conversation = user.connection.conversation;
    
    BOOL conversationCreated = NO;
    if (conversation == nil) {
        // if the conversation already exist, it will pick it up here and hook it up to the connection
        conversation = [ZMConversation conversationWithRemoteID:convRemoteID createIfNeeded:YES inContext:self.managedObjectContext created:&conversationCreated];
        RequireString(conversation.conversationType != ZMConversationTypeGroup && conversation.conversationType != ZMConversationTypeHugeGroup,
                      "Conversation for connection is a group conversation: %s",
                      convRemoteID.transportString.UTF8String);
        user.connection.conversation = conversation;
    } else {
        // check if a conversation already exists with that ID
        [conversation mergeWithExistingConversationWithRemoteID:convRemoteID];
        conversationCreated = YES;
    }
    
    conversation.remoteIdentifier = convRemoteID;
    [conversation updateWithTransportData:transportData serverTimeStamp:serverTimeStamp];
    return conversation;
}

/// 需要处理的更新事件
- (BOOL)shouldProcessUpdateEvent:(ZMUpdateEvent *)event
{
    switch (event.type) {
        case ZMUpdateEventTypeConversationMessageAdd:
        case ZMUpdateEventTypeConversationClientMessageAdd:
        case ZMUpdateEventTypeConversationOtrMessageAdd:
        case ZMUpdateEventTypeConversationOtrAssetAdd:
        case ZMUpdateEventTypeConversationKnock:
        case ZMUpdateEventTypeConversationAssetAdd:
        case ZMUpdateEventTypeConversationMemberJoin:
        case ZMUpdateEventTypeConversationMemberLeave:
        case ZMUpdateEventTypeConversationRename:
        case ZMUpdateEventTypeConversationMemberUpdate:
        case ZMUpdateEventTypeConversationCreate:
        case ZMUpdateEventTypeConversationDelete:
        case ZMUpdateEventTypeConversationConnectRequest:
        case ZMUpdateEventTypeConversationAccessModeUpdate:
        case ZMUpdateEventTypeConversationMessageTimerUpdate:
        case ZMUpdateEventTypeConversationUpdateAutoreply:
        case ZMUpdateEventTypeConversationChangeType:
        case ZMUpdateEventTypeConversationChangeCreater:
        case ZMUpdateEventTypeConversationUpdateAliasname:
        case ZMUpdateEventTypeConversationBgpMessageAdd:
        case ZMUpdateEventTypeConversationServiceMessageAdd:
        case ZMUpdateEventTypeConversationUpdate:
        case ZMUpdateEventTypeConversationUpdateBlockTime:
        case ZMUpdateEventTypeConversationAppMessageAdd:
        case ZMUpdateEventTypeConversationReceiptModeUpdate:
        case ZMUpdateEventTypeConversationJsonMessageAdd:
            return YES;
        default:
            return NO;
    }
}

- (ZMConversation *)conversationFromEventPayload:(ZMUpdateEvent *)event conversationMap:(ZMConversationMapping *)prefetchedMapping
{
    NSUUID * const conversationID = [event.payload optionalUuidForKey:@"conversation"];
    
    if (nil == conversationID) {
        return nil;
    }
    
    if (nil != prefetchedMapping[conversationID]) {
        return prefetchedMapping[conversationID];
    }
    
    ZMConversation *conversation = [ZMConversation conversationWithRemoteID:conversationID createIfNeeded:NO inContext:self.managedObjectContext];
    if (conversation == nil) {
        conversation = [ZMConversation conversationWithRemoteID:conversationID createIfNeeded:YES inContext:self.managedObjectContext];
        // if we did not have this conversation before, refetch it
        conversation.needsToBeUpdatedFromBackend = YES;
    }
    return conversation;
}

- (BOOL)isSelfConversationEvent:(ZMUpdateEvent *)event;
{
    NSUUID * const conversationID = event.conversationUUID;
    return [conversationID isSelfConversationRemoteIdentifierInContext:self.managedObjectContext];
}

- (void)createConversationFromEvent:(ZMUpdateEvent *)event {
    NSDictionary *payloadData = [event.payload dictionaryForKey:@"data"];
    if(payloadData == nil) {
        ZMLogError(@"Missing conversation payload in ZMUpdateEventConversationCreate");
        return;
    }
    NSDate *serverTimestamp = [event.payload dateFor:@"time"];
    [self createConversationFromTransportData:payloadData serverTimeStamp:serverTimestamp source:ZMConversationSourceUpdateEvent];
}

- (ZMConversation *)createConversationAndJoinMemberFromEvent:(ZMUpdateEvent *)event {
    NSDictionary *payloadData = event.payload;
    if(payloadData == nil) {
        ZMLogError(@"Missing conversation payload in ZMUpdateEventTypeConversationServiceMessageAdd");
        return nil;
    }
    NSDate *serverTimestamp = [event.payload dateFor:@"time"];
    NSUUID * const convRemoteID = [payloadData uuidForKey:@"conversation"];
    if(convRemoteID == nil) {
        ZMLogError(@"Missing ID in conversation payload");
        return nil;
    }
    NSUUID * const userId = [payloadData uuidForKey:@"from"];

    ZMConversation *conversation = [ZMConversation conversationWithRemoteID:convRemoteID
                                                             createIfNeeded:YES
                                                                  inContext:self.managedObjectContext];
    
    ZMConnection *connection = [ZMConnection connectionWithUserUUID:userId
                                                          inContext:self.managedObjectContext.zm_syncContext];
    
    conversation.conversationType = ZMConversationTypeOneOnOne;
    conversation.connection = connection;
    [conversation updateLastModified:serverTimestamp];
    [conversation updateServerModified:serverTimestamp];
    conversation.isServiceNotice = YES;
    return conversation;
}


- (void)deleteConversationFromEvent:(ZMUpdateEvent *)event
{
    NSUUID *conversationId = event.conversationUUID;
    
    if (conversationId == nil) {
        ZMLogError(@"Missing conversation payload in ZMupdateEventConversatinDelete");
        return;
    }
    
    ZMConversation *conversation = [ZMConversation conversationWithRemoteID:conversationId createIfNeeded:NO inContext:self.managedObjectContext];
    
    if (conversation != nil) {
        [self.managedObjectContext deleteObject:conversation];
    }
}

- (void)processEvents:(NSArray<ZMUpdateEvent *> *)events
           liveEvents:(BOOL)liveEvents
       prefetchResult:(ZMFetchRequestBatchResult *)prefetchResult;
{
    for (ZMUpdateEvent *event in events) {

        if (event.type == ZMUpdateEventTypeConversationServiceMessageAdd) {
            [[NSNotificationCenter defaultCenter] postNotificationName:ConversationServiceMessageAdd object:nil userInfo:@{@"payload":event.payload, @"id":event.uuid.transportString}];
            [self createConversationAndJoinMemberFromEvent:event];
            continue;
        }
        
        if (event.type == ZMUpdateEventTypeConversationCreate) {
            [self createConversationFromEvent:event];
            continue;
        }
        
        if (event.type == ZMUpdateEventTypeConversationDelete) {
            [self deleteConversationFromEvent:event];
            continue;
        }
        
        if ([self isSelfConversationEvent:event]) {
            continue;
        }
        
        if (event.type == ZMUpdateEventTypeUserConnection) {
            [[NSNotificationCenter defaultCenter] postNotificationName:ConversationUserConnection object:nil userInfo:nil];
        }
        
        
        if (![self shouldProcessUpdateEvent:event]) {
            continue;
        }
        
        ZMConversation *conversation = [self conversationFromEventPayload:event
                                                          conversationMap:prefetchResult.conversationsByRemoteIdentifier];
        if (conversation == nil) {
            continue;
        }
        [self markConversationForDownloadIfNeeded:conversation afterEvent:event];
        
        
        NSDate * const currentLastTimestamp = conversation.lastServerTimeStamp;
        [conversation updateWithUpdateEvent:event];
        
        if (event.type == ZMUpdateEventTypeConversationOtrMessageAdd ||
            event.type == ZMUpdateEventTypeConversationOtrAssetAdd ||
            event.type == ZMUpdateEventTypeConversationBgpMessageAdd ||
            event.type == ZMUpdateEventTypeConversationJsonMessageAdd ) {
            [[NSNotificationCenter defaultCenter] postNotificationName:ConversationOtrMessageAdd object:nil userInfo:nil];
        }
        
        
        
        if (liveEvents) {
            [self processUpdateEvent:event forConversation:conversation previousLastServerTimestamp:currentLastTimestamp];
        }
    }
}

- (NSSet<NSUUID *> *)conversationRemoteIdentifiersToPrefetchToProcessEvents:(NSArray<ZMUpdateEvent *> *)events
{
    return [NSSet setWithArray:[events mapWithBlock:^NSUUID *(ZMUpdateEvent *event) {
        return [event.payload optionalUuidForKey:@"conversation"];
    }]];
}


- (void)markConversationForDownloadIfNeeded:(ZMConversation *)conversation afterEvent:(ZMUpdateEvent *)event {
    
    if (event.type == ZMUpdateEventTypeConversationMemberLeave) {
        NSDictionary *data = [event.payload dictionaryForKey:@"data"];
        NSArray *leavingUserIds = [data optionalArrayForKey:@"user_ids"];
        ZMUser *selfUser = [ZMUser selfUserInContext:self.managedObjectContext];
        if ([leavingUserIds containsObject:selfUser.remoteIdentifier.transportString]) {
            return;
        }
    }
    
    // 可能需要添加，暂时不知道干嘛用，后续再看
    switch(event.type) {
        case ZMUpdateEventTypeConversationOtrAssetAdd:
        case ZMUpdateEventTypeConversationOtrMessageAdd:
        case ZMUpdateEventTypeConversationRename:
        case ZMUpdateEventTypeConversationMemberLeave:
        case ZMUpdateEventTypeConversationKnock:
        case ZMUpdateEventTypeConversationMessageAdd:
        case ZMUpdateEventTypeConversationTyping:
        case ZMUpdateEventTypeConversationAssetAdd:
        case ZMUpdateEventTypeConversationClientMessageAdd:
            break;
        default:
            return;
    }
    
    BOOL isConnection = conversation.connection.status == ZMConnectionStatusPending
        || conversation.connection.status == ZMConnectionStatusSent
        || conversation.conversationType == ZMConversationTypeConnection; // the last OR should be covered by the
                                                                      // previous cases already, but just in case..
    if (isConnection || conversation.conversationType == ZMConversationTypeInvalid) {
        conversation.needsToBeUpdatedFromBackend = YES;
        conversation.connection.needsToBeUpdatedFromBackend = YES;
    }
}

- (void)processUpdateEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation previousLastServerTimestamp:(NSDate *)previousLastServerTimestamp
{
    switch (event.type) {
        case ZMUpdateEventTypeConversationRename:
            [self processConversationRenameEvent:event forConversation:conversation];
            break;
        case ZMUpdateEventTypeConversationMemberJoin:
            if (conversation.conversationType == ZMConversationTypeHugeGroup) {
                [self processMemberJoinEvent:event forHugeConversation:conversation];
            } else {
                [self processMemberJoinEvent:event forConversation:conversation];
            }
            break;
        case ZMUpdateEventTypeConversationMemberLeave:
            if (conversation.conversationType == ZMConversationTypeHugeGroup) {
                [self processMemberLeaveEvent:event forHugeConversation:conversation];
            } else {
                [self processMemberLeaveEvent:event forConversation:conversation];
            }
            [self shouldDeleteConversation:conversation ifSelfUserLeftWithEvent:event];
            break;
        case ZMUpdateEventTypeConversationMemberUpdate:
            [self processMemberUpdateEvent:event forConversation:conversation previousLastServerTimeStamp:previousLastServerTimestamp];
            break;
        case ZMUpdateEventTypeConversationConnectRequest:
            [self appendSystemMessageForUpdateEvent:event inConversation:conversation];
            break;
        case ZMUpdateEventTypeConversationAccessModeUpdate:
            [self processAccessModeUpdateEvent:event inConversation:conversation];
            break;       
        case ZMUpdateEventTypeConversationMessageTimerUpdate:
            [self processDestructionTimerUpdateEvent:event inConversation:conversation];
            break;
        case ZMUpdateEventTypeConversationUpdateAutoreply:
            [self processConversationAutoReplyEvent:event forConversation:conversation];
            break;
        case ZMUpdateEventTypeConversationChangeType:
            [self processConversationChangeTypeEvent:event forConversation:conversation];
            break;
        case ZMUpdateEventTypeConversationChangeCreater:
            [self processConversationChangecreatorEvent:event forConversation:conversation];
            break;
        case ZMUpdateEventTypeConversationUpdateAliasname:
            [self processConversationUpdateAliasnameEvent:event forConversation:conversation];
            break;
        case ZMUpdateEventTypeConversationUpdate:
        {
            [self processUpdateEvent:event forConversation:conversation];
            break;
        }
        case ZMUpdateEventTypeConversationAppMessageAdd:
            [self processConversationAppMessageAddEvent:event forConversation:conversation];
            break;
        case ZMUpdateEventTypeConversationReceiptModeUpdate:
            [self processReceiptModeUpdate:event inConversation:conversation lastServerTimestamp:previousLastServerTimestamp];
        default:
            break;
    }
}

// 将群升级为万人群
- (void)processConversationChangeTypeEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation
{
    NSDictionary *data = [event.payload dictionaryForKey:@"data"];
    NSNumber *type = data[@"type"];
    if ([type isEqualToNumber: [NSNumber numberWithInt:5]]) {
        conversation.conversationType = ZMConversationTypeHugeGroup;
        conversation.localMessageDestructionTimeout = 0;
        conversation.syncedMessageDestructionTimeout = 0;
    }
}

// 将群主更改
- (void)processConversationChangecreatorEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation {
    NSDictionary *data = [event.payload dictionaryForKey:@"data"];
    //    NSString *type = data[@"creator"];
    NSUUID *creatorId = [data uuidForKey:@"creator"];
    if(creatorId != nil) {
        conversation.creator = [ZMUser userWithRemoteID:creatorId createIfNeeded:YES inConversation:conversation inContext:self.managedObjectContext];
    }
}

// 群应用通知
- (void)processConversationAppMessageAddEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation {
    NSString *userid = [event.payload optionalStringForKey:@"from"];
    if (userid && userid.length > 0 && [userid.lowercaseString isEqualToString:[ZMUser selfUserInContext:self.managedObjectContext].remoteIdentifier.transportString]) {
        return;
    }
    
    [self appendSystemMessageForUpdateEvent:event inConversation:conversation];
}


// 修改自动回复状态（机器人类型）
- (void)processConversationAutoReplyEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation
{
    NSDictionary *data = [event.payload dictionaryForKey:@"data"];
    short newAutoReply = [[data numberForKey:@"auto_reply"] shortValue];
//    NSDate *date = [data dateForKey:@"auto_reply_ref"];
    // 后续添加系统消息
    //    if (conversation.autoReply != newAutoReply || [conversation.modifiedKeys containsObject:ZMConversationAutoReplyKey]) {
    //        [self appendSystemMessageForUpdateEvent:event inConversation:conversation];
    //    }
    // 判断推送来源,自己/别人
    BOOL senderIsSelfUser = ([event.senderUUID isEqual:[ZMUser selfUserInContext:self.managedObjectContext].remoteIdentifier]);
    if (senderIsSelfUser) {
        conversation.autoReply = newAutoReply;
//        conversation.autoReplyChangedTimestamp = date;
    }else{
        conversation.autoReplyFromOther = newAutoReply;
//        conversation.autoReplyFromOtherChangedTimestamp = date;
    }
    
}

- (void)processConversationUpdateAliasnameEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation
{
    NSString *fromId = [event.payload optionalStringForKey:@"from"];
    NSDictionary *data = [event.payload dictionaryForKey:@"data"];
    NSString *aliname = [data optionalStringForKey:@"alias_name_ref"];
    [UserAliasname updateFromAliasName:aliname remoteIdentifier:[fromId lowercaseString] managedObjectContext:self.managedObjectContext inConversation:conversation];
}

- (void)processConversationRenameEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation
{
    NSDictionary *data = [event.payload dictionaryForKey:@"data"];
    NSString *newName = [data stringForKey:@"name"];
    
    if (![conversation.userDefinedName isEqualToString:newName] || [conversation.modifiedKeys containsObject:ZMConversationUserDefinedNameKey]) {
        [self appendSystemMessageForUpdateEvent:event inConversation:conversation];
    }
    
    conversation.userDefinedName = newName;
}

//万人群加人时，只生成谁+谁这条系统消息，不在把加的人生成user入库
- (void)processMemberJoinEvent:(ZMUpdateEvent *)event forHugeConversation:(ZMConversation *)hugeConversation
{
    if (!hugeConversation.remoteIdentifier.transportString) {
        return;
    }
//    [self appendSystemMessageForUpdateEvent:event inConversation:hugeConversation];
    
    [self assignMembersCountWithEvent:event forConversation:hugeConversation];
}
    
- (void)processMemberJoinEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation
{
    NSSet *users = [event usersFromUserIDsInManagedObjectContext:self.managedObjectContext createIfNeeded:YES];
    
    ZMUser *selfUser = [ZMUser selfUserInContext:self.managedObjectContext];
    
    if (![users isSubsetOfSet:conversation.activeParticipants] || (selfUser && [users intersectsSet:[NSSet setWithObject:selfUser]])) {
        [self appendSystemMessageForUpdateEvent:event inConversation:conversation];
    }
    
    for (ZMUser *user in users) {
        [conversation internalAddParticipants:@[user]];
    }
    
    [self assignMembersCountWithEvent:event forConversation:conversation];
}

//万人群删人时，只生成谁-谁这条系统消息，如果本地有这个用户则删除
- (void)processMemberLeaveEvent:(ZMUpdateEvent *)event forHugeConversation:(ZMConversation *)hugeConversation
{
//    [self appendSystemMessageForUpdateEvent:event inConversation:hugeConversation];
    /// 受到成员移除消息时，暂时不去解除成员关系
//    NSUUID *senderUUID = event.senderUUID;
//    ZMUser *sender = [ZMUser userWithRemoteID:senderUUID createIfNeeded:YES inConversation:hugeConversation inContext:self.managedObjectContext];
//    NSSet *users = [event usersFromUserIDsInManagedObjectContext:self.managedObjectContext createIfNeeded:NO];
//    for (ZMUser *user in users) {
//        [hugeConversation internalRemoveParticipants:@[user] sender:sender];
//    }
    
    [self assignMembersCountWithEvent:event forConversation:hugeConversation];
}

- (void)processMemberLeaveEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation
{
    NSUUID *senderUUID = event.senderUUID;
    ZMUser *sender = [ZMUser userWithRemoteID:senderUUID createIfNeeded:YES inConversation:conversation inContext:self.managedObjectContext];
    NSSet *users = [event usersFromUserIDsInManagedObjectContext:self.managedObjectContext createIfNeeded:YES];
    
    if (!conversation.remoteIdentifier.transportString || users.count == 0) {///没有此群，或者没有此用户
        return;
    }
    ZMLogDebug(@"processMemberLeaveEvent (%@) leaving users.count = %lu", conversation.remoteIdentifier.transportString, (unsigned long)users.count);
    
    if ([users intersectsSet:conversation.activeParticipants]) {
        [self appendSystemMessageForUpdateEvent:event inConversation:conversation];
    }

    for (ZMUser *user in users) {
        [conversation internalRemoveParticipants:@[user] sender:sender];
    }
    
    [self assignMembersCountWithEvent:event forConversation:conversation];
}
    
// 计算群成员数量--普通群的成员数量为activeParticipants的集合count，万人群的成员数量则为服务端返回的值
- (void)assignMembersCountWithEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation {
    if (conversation.conversationType == ZMConversationTypeHugeGroup) {
        NSDictionary *data = [event.payload dictionaryForKey:@"data"];
        NSNumber *membersCountNumber = [data optionalNumberForKey:@"memsum"];
        if (membersCountNumber != nil) {
            conversation.membersCount = membersCountNumber.integerValue;
        }
    } else {
        conversation.membersCount = (NSInteger)conversation.activeParticipants.count;
    }
}

- (void)shouldDeleteConversation: (ZMConversation *)conversation ifSelfUserLeftWithEvent: (ZMUpdateEvent *)event {
    NSDictionary *data = [event.payload dictionaryForKey:@"data"];
    NSArray *leavingUserIds = [data optionalArrayForKey:@"user_ids"];
    ZMUser *selfUser = [ZMUser selfUserInContext:self.managedObjectContext];
    if ([leavingUserIds containsObject:selfUser.remoteIdentifier.transportString]) {
        [conversation deleteConversation];
    }
}

- (void)processUpdateEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation
{
    NSDictionary *dataPayload = [event.payload.asDictionary dictionaryForKey:@"data"];
    if(dataPayload == NULL) {
        return;
    }
    /// 是否允许编辑和删除消息
    if ([dataPayload.allKeys containsObject:ZMConversationEnabledEditMsgKey] && dataPayload[ZMConversationEnabledEditMsgKey] != nil) {
        conversation.enabledEditMsg = [dataPayload[ZMConversationEnabledEditMsgKey] boolValue];
    }
    /// 是否显示群成员数量
    if ([dataPayload.allKeys containsObject:ZMConversationShowMemsumKey] && dataPayload[ZMConversationShowMemsumKey] != nil) {
        conversation.showMemsum = [dataPayload[ZMConversationShowMemsumKey] boolValue];
    }
    /// 允许查看群成员
    if ([dataPayload.allKeys containsObject:@"viewmem"] && dataPayload[@"viewmem"] != nil) {
        conversation.isAllowViewMembers = [dataPayload[@"viewmem"] boolValue];
    }
    ///开启url链接加入
    if ([dataPayload.allKeys containsObject:@"url_invite"] && dataPayload[@"url_invite"] != nil) {
        conversation.isOpenUrlJoin = [dataPayload[@"url_invite"] boolValue];
    }
    /// 群聊邀请-群主确认
    if ([dataPayload.allKeys containsObject:@"confirm"] && dataPayload[@"confirm"] != nil) {
        conversation.isOpenCreatorInviteVerify = [dataPayload[@"confirm"] boolValue];
    }
    /// 群聊邀请-被邀请人确认
    if ([dataPayload.allKeys containsObject:ZMConversationInfoMemberInviteVerfyKey] && dataPayload[ZMConversationInfoMemberInviteVerfyKey] != nil) {
        conversation.isOpenMemberInviteVerify = [dataPayload[ZMConversationInfoMemberInviteVerfyKey] boolValue];
    }
    /// 仅限群主拉人
    if ([dataPayload.allKeys containsObject:@"addright"] && dataPayload[@"addright"] != nil) {
        conversation.isOnlyCreatorInvite = [dataPayload[@"addright"] boolValue];
    }
    /// 群主更换
    if ([dataPayload.allKeys containsObject:@"new_creator"] && dataPayload[@"new_creator"] != nil) {
        
        ZMUser *user = [ZMUser userWithRemoteID:[NSUUID uuidWithTransportString:dataPayload[@"new_creator"]] createIfNeeded:YES inContext:self.managedObjectContext];
        conversation.creator = user;
        conversation.creatorChangeTimestamp = [NSDate date];
        [self appendSystemMessageForUpdateEvent:event inConversation:conversation];
    }
    
    // 邀请人列表是否可见 更新
    if ([dataPayload.allKeys containsObject:ZMConversationInfoIsVisitorsVisibleKey]) {
        conversation.isVisitorsVisible = [dataPayload[ZMConversationInfoIsVisitorsVisibleKey] boolValue];
    }
    
    // 消息可见性 更新
    if ([dataPayload.allKeys containsObject:ZMConversationInfoIsMessageVisibleOnlyManagerAndCreatorKey]) {
        conversation.isMessageVisibleOnlyManagerAndCreator = [dataPayload[ZMConversationInfoIsMessageVisibleOnlyManagerAndCreatorKey] boolValue];
        [self appendSystemMessageForUpdateEvent:event inConversation:conversation];
    }
    
    // 群公告更新
    if ([dataPayload.allKeys containsObject:ZMConversationInfoAnnouncementKey]) {
        conversation.announcement = [dataPayload optionalStringForKey:ZMConversationInfoAnnouncementKey];
        conversation.isReadAnnouncement = NO;
    }
    
    /// 群头像更新
    if ([dataPayload.allKeys containsObject:@"assets"] && dataPayload[@"assets"] != nil) {
        NSArray *asstes = dataPayload[@"assets"];
        for (NSDictionary *imgDic in asstes) {
            if ([imgDic[@"size"] isEqualToString:@"complete"]) {
                conversation.groupImageMediumKey = imgDic[@"key"];
            }
            if ([imgDic[@"size"] isEqualToString:@"preview"]) {
                conversation.groupImageSmallKey = imgDic[@"key"];
            }
        }
    }
    
    //群应用更新
    if ([dataPayload.allKeys containsObject:ZMConversationInfoAppsKey]) {
        NSArray *apps = [dataPayload optionalArrayForKey:ZMConversationInfoAppsKey];
        NSString *appsString = [apps componentsJoinedByString:@","];
        if (![appsString isEqualToString:conversation.apps]) {
            conversation.apps = appsString;
        }
    }
    if ([dataPayload.allKeys containsObject:ZMConversationInfoTopAppsKey]) {
        NSArray *apps = [dataPayload optionalArrayForKey:ZMConversationInfoTopAppsKey];
        NSString *appsString = [apps componentsJoinedByString:@","];
        if (![appsString isEqualToString:conversation.topApps]) {
            conversation.topApps = appsString;
        }
    }
    if ([dataPayload.allKeys containsObject:ZMConversationInfoTopWebAppsKey]) {
        NSArray *topApps = [dataPayload optionalArrayForKey:ZMConversationInfoTopWebAppsKey];
        NSMutableOrderedSet<ZMWebApp *> *topWebApps = [NSMutableOrderedSet orderedSet];
        
        for (NSDictionary *appDict in [topApps asDictionaries]) {
            
            NSString *userId = [appDict stringForKey:@"app_id"];
            if (userId == nil) {
                continue;
            }
            [topWebApps addObject:[ZMWebApp createOrUpdateWebApp:appDict context:self.managedObjectContext]];
        }
        conversation.topWebApps = topWebApps;
    }
    ///群绑定的社区id
    if ([dataPayload.allKeys containsObject:@"forumid"]) {
        /// 会话绑定的社区id
        NSNumber *forumIdNumber = [dataPayload optionalNumberForKey:@"forumid"];
        if (forumIdNumber != nil) {
            // Backend is sending the miliseconds, we need to convert to seconds.
            conversation.communityID = [forumIdNumber stringValue];
        }
    }
    
    // 成员是否可以互相添加好友
    if ([dataPayload.allKeys containsObject:ZMConversationInfoIsAllowMemberAddEachOtherKey]) {
        conversation.isAllowMemberAddEachOther = [dataPayload[ZMConversationInfoIsAllowMemberAddEachOtherKey] boolValue];
        [self appendSystemMessageForUpdateEvent:event inConversation:conversation];
    }
    
    // 成员变动其他群成员是否可见
    if ([dataPayload.allKeys containsObject:ZMConversationInfoIsVisibleForMemberChangeKey]) {
        conversation.isVisibleForMemberChange = [dataPayload[ZMConversationInfoIsVisibleForMemberChangeKey] boolValue];
    }
    
    //群禁言设置
    if([dataPayload.allKeys containsObject:ZMConversationInfoBlockTimeKey]) {
        conversation.isDisableSendMsg = !([dataPayload[ZMConversationInfoBlockTimeKey] integerValue] == 0);
        [self appendSystemMessageForUpdateEvent:event inConversation:conversation];
    }
    
    //群封禁状态
    if([dataPayload.allKeys containsObject:ZMConversationBlockedKey]) {
        conversation.blocked = !([dataPayload[ZMConversationBlockedKey] integerValue] == 0);
    }
    
    //更新群助手
    if([dataPayload.allKeys containsObject:ZMConversationAssistantBotKey] && [dataPayload.allKeys containsObject:ZMConversationAssistantBotOptKey]) {
        if([dataPayload optionalNumberForKey:ZMConversationAssistantBotOptKey].integerValue == 0) {// 删除
            conversation.assistantBot = nil;
        } else if ([dataPayload optionalNumberForKey:ZMConversationAssistantBotOptKey].integerValue == 1) {// 添加
            NSString *bid = [dataPayload optionalStringForKey:ZMConversationAssistantBotKey];
            ZMUser *botUser = [ZMUser userWithRemoteID:[NSUUID uuidWithTransportString:bid] createIfNeeded:false inContext:self.managedObjectContext];
            botUser.needsToBeUpdatedFromBackend = true;
            conversation.assistantBot = bid;
        }
    }
    
    //演讲者
    if ([dataPayload.allKeys containsObject:ZMConversationInfoOratorKey]) {
        NSArray *orator = [dataPayload optionalArrayForKey:ZMConversationInfoOratorKey];
        if (!orator) {/// orator个数为0 则说明演讲者被全部删除了
            return;
        }
        for (NSString* obj in orator) {
            ZMUser *user = [ZMUser userWithRemoteID:[NSUUID uuidWithTransportString:obj] createIfNeeded:YES inContext:self.managedObjectContext];
            user.needsToBeUpdatedFromBackend = YES;
        }
        conversation.orator = orator.set;
    }
    //管理员
    if ([dataPayload.allKeys containsObject:ZMConversationInfoManagerKey]) {
        NSArray *manager = [dataPayload optionalArrayForKey:ZMConversationInfoManagerKey];
        conversation.manager = manager.set;
        ///清空请求触发条件，防止下次设置相同值不发请求
        conversation.managerAdd = [[NSSet alloc] init];
        conversation.managerDel = [[NSSet alloc] init];
        NSArray *addUsers = [dataPayload optionalArrayForKey:ZMConversationInfoManagerAddKey];
        NSArray *delUsers = [dataPayload optionalArrayForKey:ZMConversationInfoManagerDelKey];
        
        NSString *selfUserUUIDString = [ZMUser selfUserInContext:self.managedObjectContext].remoteIdentifier.transportString;
        for (NSDictionary *userDict in [addUsers asDictionaries]) {
            NSString *userId = [userDict stringForKey:@"id"];
            if (userId == nil) {
                continue;
            }
            NSString * name = [userDict stringForKey:@"name"];
            if ([userId isEqualToString:selfUserUUIDString]) {
                [self appendManagerSystemMessageForUpdateEvent:event inConversation:conversation withManagerType:ZMSystemManagerMessageTypeMeBecameManager name:name];
            } else {
                if (!name) {
                    name = [userDict stringForKey:@"handle"];
                }
                [self appendManagerSystemMessageForUpdateEvent:event inConversation:conversation withManagerType:ZMSystemManagerMessageTypeOtherBecameManager name:name];
            }
        }
        for (NSDictionary *userDict in [delUsers asDictionaries]) {
            NSString *userId = [userDict stringForKey:@"id"];
            if (userId == nil) {
                continue;
            }
            NSString * name = [userDict stringForKey:@"name"];
            if ([userId isEqualToString:selfUserUUIDString]) {
                [self appendManagerSystemMessageForUpdateEvent:event inConversation:conversation withManagerType:ZMSystemManagerMessageTypeMeDropManager name:name];
            } else {
                if (!name) {
                    name = [userDict stringForKey:@"handle"];
                }
                [self appendManagerSystemMessageForUpdateEvent:event inConversation:conversation withManagerType:ZMSystemManagerMessageTypeOtherDropManager name:name];
            }
        }
    }
    
}

- (void)fetchImageData:(NSString *)key complete:(void(^)(NSData *)) complete {
    NSString *path = [NSString pathWithComponents:@[V3Assetspath, key]];
    ZMTransportRequest *request = [[ZMTransportRequest alloc]initWithPath:path method:ZMMethodGET payload:nil authentication:ZMTransportRequestAuthNeedsAccess];
    [request addCompletionHandler:[ZMCompletionHandler handlerOnGroupQueue:self.managedObjectContext block:^(ZMTransportResponse * response) {
        complete(response.rawData);
    }]];
    [((SessionManager *)[(NSObject *)UIApplication.sharedApplication.delegate valueForKeyPath:@"rootViewController.sessionManager"]).activeUserSession.transportSession enqueueOneTimeRequest:request];
}

- (void)processMemberUpdateEvent:(ZMUpdateEvent *)event forConversation:(ZMConversation *)conversation previousLastServerTimeStamp:(NSDate *)previousLastServerTimestamp
{
    NSDictionary *dataPayload = [event.payload.asDictionary dictionaryForKey:@"data"];
 
    if(dataPayload) {
        [conversation updateSelfStatusFromDictionary:dataPayload
                                           timeStamp:event.timeStamp
                         previousLastServerTimeStamp:previousLastServerTimestamp];
    }
}

- (void)appendManagerSystemMessageForUpdateEvent:(ZMUpdateEvent *)event inConversation:(ZMConversation *)conversation withManagerType:(ZMSystemManagerMessageType)type name:(NSString *)name
{
    ZMSystemMessage *systemMessage = [ZMSystemMessage createOrUpdateMessageFromUpdateEvent:event inManagedObjectContext:self.managedObjectContext];
    systemMessage.managerType = type;
    systemMessage.text = name;
    
    if (systemMessage != nil) {
        [self.localNotificationDispatcher processMessage:systemMessage];
    }
}


- (void)appendSystemMessageForUpdateEvent:(ZMUpdateEvent *)event inConversation:(ZMConversation * ZM_UNUSED)conversation
{
    ZMSystemMessage *systemMessage = [ZMSystemMessage createOrUpdateMessageFromUpdateEvent:event inManagedObjectContext:self.managedObjectContext];
    
    if (systemMessage != nil) {
        [self.localNotificationDispatcher processMessage:systemMessage];
    }
}

@end



@implementation ZMConversationTranscoder (UpstreamTranscoder)

- (BOOL)shouldProcessUpdatesBeforeInserts;
{
    return NO;
}

- (ZMUpstreamRequest *)requestForUpdatingObject:(ZMConversation *)updatedConversation forKeys:(NSSet *)keys;
{
    ZMUpstreamRequest *request = nil;
    if([keys containsObject:ZMConversationUserDefinedNameKey]) {
        request = [self requestForUpdatingUserDefinedNameInConversation:updatedConversation];
    }
    if([keys containsObject:ZMConversationAutoReplyKey]) {
        request = [self requestForUpdatingAutoReplyInConversation:updatedConversation];
    }
    if([keys containsObject:ZMConversationSelfRemarkKey]) {
        request = [self requestForUpdatingSelfRemarkInConversation:updatedConversation];
    }
    if([keys containsObject:ZMConversationIsOpenCreatorInviteVerifyKey]) {
        request = [self requestForUpdatingIsOpenCreatorInviteVerifyInConversation:updatedConversation];
    }
    if([keys containsObject:ZMConversationIsOpenMemberInviteVerifyKey]) {
        request = [self requestForUpdatingIsOpenMemberInviteVerifyInConversation:updatedConversation];
    }
    if([keys containsObject:ZMConversationOnlyCreatorInviteKey]) {
        request = [self requestForUpdatingOnlyCreatorInviteInConversation:updatedConversation];
    }
    if([keys containsObject:ZMConversationOpenUrlJoinKey]) {
        request = [self requestForUpdatingOpenUrlJoinInConversation:updatedConversation];
    }
    if([keys containsObject:ZMConversationAllowViewMembersKey]) {
        request = [self requestForUpdatingAllowViewMembersInConversation:updatedConversation];
    }
    if([keys containsObject:CreatorKey]) {
        request = [self requestForUpdatingCreatorInConversation:updatedConversation];
    }
    if([keys containsObject:ZMConversationTopWebAppsKey]) {
        request = [self requestForUpdatingTopWebAppsInConversation:updatedConversation];
    }
    if([keys containsObject:ZMConversationIsDisableSendMsgKey]) {
        request = [self requestForUpdatingDisableSendMsgInConversation:updatedConversation];
    }
    if([keys containsObject:ZMConversationIsAllowMemberAddEachOtherKey]) {
        request = [self requestForUpdatingMemberAddInConversation:updatedConversation];
    }
    if([keys containsObject:ZMConversationIsVisibleForMemberChangeKey]) {
        request = [self requestForUpdatingVisibleForMemberChangeInConversation:updatedConversation];
    }
    if ([keys containsObject:ZMConversationInfoOratorKey]) {
        request = [self requestForUpdatingOratorInConversation:updatedConversation];
    }
    if ([keys containsObject:ZMConversationManagerAddKey]) {
        request = [self requestForAddManagerInConversation:updatedConversation];
    }
    if ([keys containsObject:ZMConversationManagerDelKey]) {
        request = [self requestForDelManagerInConversation:updatedConversation];
    }
    if ([keys containsObject:ZMConversationIsVisitorsVisibleKey]) {
        request = [self requestForUpdatingIsVisitorsVisibleInConversation:updatedConversation];
    }
    if ([keys containsObject:ZMConversationIsMessageVisibleOnlyManagerAndCreatorKey]) {
        request = [self requestForUpdatingIsMessageVisibleOnlyManagerAndCreatorInConversation:updatedConversation];
    }
    if ([keys containsObject:ZMConversationAnnouncementKey]) {
        request = [self requestForUpdatingAnnouncementInConversation:updatedConversation];
    }
    if ([keys containsObject:ZMConversationPreviewAvatarKey] && [keys containsObject:ZMConversationCompleteAvatarKey]) {
        request = [self requestForBindAvatarKeyInConversation:updatedConversation];
    }
    if ([keys containsObject:ShowMemsumKey]) {
        request = [self requestForUpdatingShowMemsumInConversation:updatedConversation];
    }
    if ([keys containsObject:EnabledEditMsgKey]) {
        request = [self requestForUpdatingEnabledEditMsgInConversation:updatedConversation];
    }
    if (request == nil && (   [keys containsObject:ZMConversationArchivedChangedTimeStampKey]
                           || [keys containsObject:ZMConversationSilencedChangedTimeStampKey]
                           || [keys containsObject:ZMConversationIsPlacedTopKey])) {
        request = [updatedConversation requestForUpdatingSelfInfo];
    }
    if (request == nil) {
        ZMTrapUnableToGenerateRequest(keys, self);
    }
    return request;
}

- (ZMUpstreamRequest *)requestForUpdatingUserDefinedNameInConversation:(ZMConversation *)conversation
{
    NSDictionary *payload = @{ @"name" : conversation.userDefinedName };
    NSString *lastComponent = conversation.remoteIdentifier.transportString;
    Require(lastComponent != nil);
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, lastComponent]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];

    [request expireAfterInterval:ZMTransportRequestDefaultExpirationInterval];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationUserDefinedNameKey] transportRequest:request userInfo:nil];
}

- (ZMUpstreamRequest *)requestForUpdatingAutoReplyInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = @{ @"auto_reply" : @(conversation.autoReply)}.mutableCopy;
    NSString *lastComponent = conversation.remoteIdentifier.transportString;
    Require(lastComponent != nil);
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, lastComponent, @"autoreply"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    
    [request expireAfterInterval:ZMTransportRequestDefaultExpirationInterval];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationAutoReplyKey] transportRequest:request userInfo:nil];
}

- (ZMUpstreamRequest *)requestForUpdatingSelfRemarkInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];
    payload[ZMConversationInfoOTRSelfRemarkReferenceKey] = conversation.selfRemark;
    payload[ZMConversationInfoOTRSelfRemarkBoolKey] = @(YES);
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"selfalias"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationSelfRemarkKey] transportRequest:request userInfo:nil];
}

- (ZMUpstreamRequest *)requestForUpdatingIsOpenCreatorInviteVerifyInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];
    payload[ZMConversationInfoOTRSelfVerifyKey] = @(conversation.isOpenCreatorInviteVerify);
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationIsOpenCreatorInviteVerifyKey] transportRequest:request userInfo:nil];
}
    
- (ZMUpstreamRequest *)requestForUpdatingIsOpenMemberInviteVerifyInConversation:(ZMConversation *)conversation
    {
        NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];
        payload[ZMConversationInfoMemberInviteVerfyKey] = @(conversation.isOpenMemberInviteVerify);
        NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"update"]];
        ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
        return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationIsOpenMemberInviteVerifyKey] transportRequest:request userInfo:nil];
    }

- (ZMUpstreamRequest *)requestForUpdatingOnlyCreatorInviteInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];
    payload[ZMConversationInfoOTRCanAddKey] = @(conversation.isOnlyCreatorInvite);
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationOnlyCreatorInviteKey] transportRequest:request userInfo:nil];
}

- (ZMUpstreamRequest *)requestForUpdatingOpenUrlJoinInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];
    payload[ZMCOnversationInfoOTROpenUrlJoinKey] = @(conversation.isOpenUrlJoin);
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationOpenUrlJoinKey] transportRequest:request userInfo:nil];
}

- (ZMUpstreamRequest *)requestForUpdatingAllowViewMembersInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];
    payload[ZMCOnversationInfoOTRAllowViewMembersKey] = @(conversation.isAllowViewMembers);
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationAllowViewMembersKey] transportRequest:request userInfo:nil];
}

- (ZMUpstreamRequest *)requestForUpdatingCreatorInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];
    payload[ZMConversationInfoOTRCreatorChangeKey] = conversation.creator.remoteIdentifier.transportString;
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:CreatorKey] transportRequest:request userInfo:nil];
}

- (ZMUpstreamRequest *)requestForUpdatingDisableSendMsgInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];
    payload[ZMConversationInfoBlockTimeKey] = @(conversation.isDisableSendMsg ? -1 : 0);
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationIsDisableSendMsgKey] transportRequest:request userInfo:nil];
}

- (ZMUpstreamRequest *)requestForUpdatingTopWebAppsInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];
    NSArray *appIds = [conversation.topWebApps.array mapWithBlock:^id(ZMWebApp *webApp) {
        return webApp.appId;
    }];
    payload[@"top_apps"] = appIds;
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationTopWebAppsKey] transportRequest:request userInfo:nil];
}

- (ZMUpstreamRequest *)requestForUpdatingMemberAddInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];

    payload[ZMConversationInfoIsAllowMemberAddEachOtherKey] = @(conversation.isAllowMemberAddEachOther);
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationIsAllowMemberAddEachOtherKey] transportRequest:request userInfo:nil];
}

- (ZMUpstreamRequest *)requestForUpdatingVisibleForMemberChangeInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];

    payload[ZMConversationInfoIsVisibleForMemberChangeKey] = @(conversation.isVisibleForMemberChange);
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationIsVisibleForMemberChangeKey] transportRequest:request userInfo:nil];
}

- (ZMUpstreamRequest *)requestForUpdatingOratorInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];
    
    payload[ZMConversationInfoOratorKey] = [conversation.orator allObjects];
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationInfoOratorKey] transportRequest:request userInfo:nil];
}

- (ZMUpstreamRequest *)requestForAddManagerInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];
    
    payload[ZMConversationInfoManagerAddKey] = [conversation.managerAdd allObjects];
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationManagerAddKey] transportRequest:request userInfo:nil];
}
- (ZMUpstreamRequest *)requestForDelManagerInConversation:(ZMConversation *)conversation
{
    NSMutableDictionary *payload = [[NSMutableDictionary alloc]init];
    
    payload[ZMConversationInfoManagerDelKey] = [conversation.managerDel allObjects];
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationManagerDelKey] transportRequest:request userInfo:nil];
}

/// 邀请人列表是否可见 请求
- (ZMUpstreamRequest *)requestForUpdatingIsVisitorsVisibleInConversation:(ZMConversation *)conversation
{
    NSString *remoteIdComponent = conversation.remoteIdentifier.transportString;
    Require(remoteIdComponent != nil);
    NSDictionary *payload = @{ ZMConversationInfoIsVisitorsVisibleKey : @(conversation.isVisitorsVisible) };
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, remoteIdComponent, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    [request expireAfterInterval:ZMTransportRequestDefaultExpirationInterval];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationIsVisitorsVisibleKey] transportRequest:request];
}

/// 消息可见性 请求
/// 管理员发消息所有人可见，群成员发消息只有管理和群主可见
- (ZMUpstreamRequest *)requestForUpdatingIsMessageVisibleOnlyManagerAndCreatorInConversation:(ZMConversation *)conversation
{
    NSString *remoteIdComponent = conversation.remoteIdentifier.transportString;
    Require(remoteIdComponent != nil);
    NSDictionary *payload = @{ ZMConversationInfoIsMessageVisibleOnlyManagerAndCreatorKey : @(conversation.isMessageVisibleOnlyManagerAndCreator) };
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, remoteIdComponent, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    [request expireAfterInterval:ZMTransportRequestDefaultExpirationInterval];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationIsMessageVisibleOnlyManagerAndCreatorKey] transportRequest:request];
}
    
/// 群公告 请求
- (ZMUpstreamRequest *)requestForUpdatingAnnouncementInConversation:(ZMConversation *)conversation
{
    NSString *remoteIdComponent = conversation.remoteIdentifier.transportString;
    Require(remoteIdComponent != nil);
    NSDictionary *payload = @{ ZMConversationInfoAnnouncementKey : conversation.announcement };
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, remoteIdComponent, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    [request expireAfterInterval:ZMTransportRequestDefaultExpirationInterval];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:ZMConversationAnnouncementKey] transportRequest:request];
}

/// 群头像上传之后的绑定
- (ZMUpstreamRequest *)requestForBindAvatarKeyInConversation:(ZMConversation *)conversation
{
    NSString *remoteIdComponent = conversation.remoteIdentifier.transportString;
    Require(remoteIdComponent != nil);
    
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"assets"] = [self avatarPictureAssetsPayloadForConversation:conversation];
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, remoteIdComponent, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    [request expireAfterInterval:ZMTransportRequestDefaultExpirationInterval];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObjects:ZMConversationPreviewAvatarKey, ZMConversationCompleteAvatarKey, nil] transportRequest:request];
}

/// 群显示人数的权限更新
- (ZMUpstreamRequest *)requestForUpdatingShowMemsumInConversation:(ZMConversation *)conversation
{
    NSString *remoteIdComponent = conversation.remoteIdentifier.transportString;
    Require(remoteIdComponent != nil);
    NSDictionary *payload = @{ ZMConversationShowMemsumKey : @(conversation.showMemsum) };
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, remoteIdComponent, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    [request expireAfterInterval:ZMTransportRequestDefaultExpirationInterval];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject: ShowMemsumKey] transportRequest:request];
}

/// 群成员是否可以删除编辑消息的权限更新
- (ZMUpstreamRequest *)requestForUpdatingEnabledEditMsgInConversation:(ZMConversation *)conversation
{
    NSString *remoteIdComponent = conversation.remoteIdentifier.transportString;
    Require(remoteIdComponent != nil);
    NSDictionary *payload = @{ ZMConversationEnabledEditMsgKey : @(conversation.enabledEditMsg) };
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, remoteIdComponent, @"update"]];
    ZMTransportRequest *request = [ZMTransportRequest requestWithPath:path method:ZMMethodPUT payload:payload];
    [request expireAfterInterval:ZMTransportRequestDefaultExpirationInterval];
    return [[ZMUpstreamRequest alloc] initWithKeys:[NSSet setWithObject:EnabledEditMsgKey] transportRequest:request];
}

- (NSArray *)avatarPictureAssetsPayloadForConversation:(ZMConversation *)conversation {
    return @[
             @{
                 @"size" : @"preview",
                 @"key"  : conversation.groupImageSmallKey,
                 @"type" : @"image"
                 },
             @{
                 @"size" : @"complete",
                 @"key"  : conversation.groupImageMediumKey,
                 @"type" : @"image"
                 },
             ];
}


- (ZMUpstreamRequest *)requestForInsertingObject:(ZMManagedObject *)managedObject forKeys:(NSSet *)keys;
{
    NOT_USED(keys);
    
    ZMTransportRequest *request = nil;
    ZMConversation *insertedConversation = (ZMConversation *) managedObject;
    
    NSArray *participantUUIDs = [[insertedConversation.lastServerSyncedActiveParticipants array] mapWithBlock:^id(ZMUser *user) {
        return [user.remoteIdentifier transportString];
    }];
    
    NSMutableDictionary *payload = [@{ @"users" : participantUUIDs } mutableCopy];
    if (insertedConversation.userDefinedName != nil) {
        payload[@"name"] = insertedConversation.userDefinedName;
    }
    ///新增应用参数
    NSMutableArray * topapps = [@[] mutableCopy];
    for (ZMWebApp * app in insertedConversation.topWebApps) {
        [topapps addObject:app.appId];
    }
    payload[@"top_apps"] = topapps;

    // 万人群type=5, 其他群不传type
    if (insertedConversation.conversationType == ZMConversationTypeHugeGroup) {
        payload[@"type"] = [NSNumber numberWithInteger: 5];
    }
    
    if (insertedConversation.hasReadReceiptsEnabled) {
        payload[@"receipt_mode"] = @(1);
    }

    if (insertedConversation.team.remoteIdentifier != nil) {
        payload[ConversationTeamKey] = @{
                             ConversationTeamIdKey: insertedConversation.team.remoteIdentifier.transportString,
                             ConversationTeamManagedKey: @NO // FIXME:
                             };
    }

    NSArray <NSString *> *accessPayload = insertedConversation.accessPayload;
    if (nil != accessPayload) {
        payload[ConversationAccessKey] = accessPayload;
    }

    NSString *accessRolePayload = insertedConversation.accessRolePayload;
    if (nil != accessRolePayload) {
        payload[ConversationAccessRoleKey] = accessRolePayload;
    }
    
    request = [ZMTransportRequest requestWithPath:ConversationsPath method:ZMMethodPOST payload:payload];
    return [[ZMUpstreamRequest alloc] initWithTransportRequest:request];
}


- (void)updateInsertedObject:(ZMManagedObject *)managedObject request:(ZMUpstreamRequest *__unused)upstreamRequest response:(ZMTransportResponse *)response
{
    ZMConversation *insertedConversation = (ZMConversation *)managedObject;
    NSUUID *remoteID = [response.payload.asDictionary uuidForKey:@"id"];
    
    // check if there is another with the same conversation ID
    if (remoteID != nil) {
        ZMConversation *existingConversation = [ZMConversation conversationWithRemoteID:remoteID createIfNeeded:NO inContext:self.managedObjectContext];
        
        if (existingConversation != nil) {
            [self.managedObjectContext deleteObject:existingConversation];
            insertedConversation.needsToBeUpdatedFromBackend = YES;
        }
    }
    insertedConversation.remoteIdentifier = remoteID;
    [insertedConversation updateWithTransportData:response.payload.asDictionary serverTimeStamp:nil];
}

- (ZMUpdateEvent *)conversationEventWithKeys:(NSSet *)keys responsePayload:(id<ZMTransportData>)payload;
{
    NSSet *keysThatGenerateEvents = [NSSet setWithObjects:ZMConversationUserDefinedNameKey,ZMConversationSelfRemarkKey, nil];
    
    if (! [keys intersectsSet:keysThatGenerateEvents]) {
        return nil;
        
    }

    ZMUpdateEvent *event = [ZMUpdateEvent eventFromEventStreamPayload:payload uuid:nil];
    return event;
}


- (BOOL)updateUpdatedObject:(ZMConversation *)conversation
            requestUserInfo:(NSDictionary *)userInfo
                   response:(ZMTransportResponse *)response
                keysToParse:(NSSet *)keysToParse
{
    NOT_USED(conversation);
    
    ZMUpdateEvent *event = [self conversationEventWithKeys:keysToParse responsePayload:response.payload];
    if (event != nil) {
        [self processEvents:@[event] liveEvents:YES prefetchResult:nil];
    }
        
    if ([keysToParse isEqualToSet:[NSSet setWithObject:ZMConversationUserDefinedNameKey]]) {
        return NO;
    }
    
    if( keysToParse == nil ||
       [keysToParse isEmpty] ||
       [keysToParse containsObject:ZMConversationSilencedChangedTimeStampKey] ||
       [keysToParse containsObject:ZMConversationArchivedChangedTimeStampKey])
    {
        return NO;
    }
    ZMLogError(@"Unknown changed keys in request. keys: %@  payload: %@  userInfo: %@", keysToParse, response.payload, userInfo);
    return NO;
}

- (ZMManagedObject *)objectToRefetchForFailedUpdateOfObject:(ZMManagedObject *)managedObject;
{
    if([managedObject isKindOfClass:ZMConversation.class]) {
        return managedObject;
    }
    return nil;
}

- (void)requestExpiredForObject:(ZMConversation *)conversation forKeys:(NSSet *)keys
{
    NOT_USED(keys);
    conversation.needsToBeUpdatedFromBackend = YES;
    [self resetModifiedKeysWithoutReferenceInConversation:conversation];
}

- (BOOL)shouldCreateRequestToSyncObject:(ZMManagedObject *)managedObject forKeys:(NSSet<NSString *> * __unused)keys  withSync:(id)sync;
{
    if (sync == self.downstreamSync || sync == self.insertedSync) {
        return YES;
    }
    // This is our chance to reset keys that should not be set - instead of crashing when we create a request.
    ZMConversation *conversation = (ZMConversation *)managedObject;
    NSMutableSet *remainingKeys = [NSMutableSet setWithSet:keys];
    
    if ([conversation hasLocalModificationsForKey:ZMConversationUserDefinedNameKey] && !conversation.userDefinedName) {
        [conversation resetLocallyModifiedKeys:[NSSet setWithObject:ZMConversationUserDefinedNameKey]];
        [remainingKeys removeObject:ZMConversationUserDefinedNameKey];
    }
    
    ///发送绑定头像的请求，只有当两个key都被改变，并且都不为nil时才能去发送
    BOOL previewAvatarKeyChanged = [conversation hasLocalModificationsForKey:ZMConversationPreviewAvatarKey];
    BOOL completeAvatarKeyChanged = [conversation hasLocalModificationsForKey:ZMConversationCompleteAvatarKey];
    ///两个头像key只有一个被改变
    if ((int)(previewAvatarKeyChanged) + (int)(completeAvatarKeyChanged) == 1) {
        ///reset被改变的key
        if (previewAvatarKeyChanged) {
            [conversation resetLocallyModifiedKeys:[NSSet setWithObject:ZMConversationPreviewAvatarKey]];
            [remainingKeys removeObject:ZMConversationPreviewAvatarKey];
        }
        if (completeAvatarKeyChanged) {
            [conversation resetLocallyModifiedKeys:[NSSet setWithObject:ZMConversationCompleteAvatarKey]];
            [remainingKeys removeObject:ZMConversationCompleteAvatarKey];
        }
    } else if (previewAvatarKeyChanged && completeAvatarKeyChanged && (!conversation.groupImageSmallKey || !conversation.groupImageMediumKey)) {
        ///两个头像key都被改变了,但是有key为nil，则也不能创建请求
        [conversation resetLocallyModifiedKeys:[NSSet setWithObjects:ZMConversationPreviewAvatarKey, ZMConversationCompleteAvatarKey, nil]];
        [remainingKeys removeObject:ZMConversationPreviewAvatarKey];
        [remainingKeys removeObject:ZMConversationCompleteAvatarKey];
    }

    if (remainingKeys.count < keys.count) {
        [(id<ZMContextChangeTracker>)sync objectsDidChange:[NSSet setWithObject:conversation]];
        [self.managedObjectContext enqueueDelayedSave];
    }
    return (remainingKeys.count > 0);
}

- (BOOL)shouldRetryToSyncAfterFailedToUpdateObject:(ZMConversation *)conversation request:(ZMUpstreamRequest *__unused)upstreamRequest response:(ZMTransportResponse *__unused)response keysToParse:(NSSet * __unused)keys
{
    if (conversation.remoteIdentifier) {
        conversation.needsToBeUpdatedFromBackend = YES;
        [self resetModifiedKeysWithoutReferenceInConversation:conversation];
        [self.downstreamSync objectsDidChange:[NSSet setWithObject:conversation]];
    }
    
    return NO;
}

/// Resets all keys that don't have a time reference and would possibly be changed with refetching of the conversation from the BE
- (void)resetModifiedKeysWithoutReferenceInConversation:(ZMConversation*)conversation
{
    [conversation resetLocallyModifiedKeys:[NSSet setWithArray:self.keysToSyncWithoutRef]];
    
    // since we reset all keys, we should make sure to remove the object from the modifiedSync
    // it might otherwise try to sync remaining keys
    [self.modifiedSync objectsDidChange:[NSSet setWithObject:conversation]];
}

@end



@implementation ZMConversationTranscoder (DownstreamTranscoder)

- (ZMTransportRequest *)requestForFetchingObject:(ZMConversation *)conversation downstreamSync:(id<ZMObjectSync>)downstreamSync;
{
    NOT_USED(downstreamSync);
    if (conversation.remoteIdentifier == nil) {
        return nil;
    }
    
    NSString *path = [NSString pathWithComponents:@[ConversationsPath, conversation.remoteIdentifier.transportString]];
    ZMTransportRequest *request = [[ZMTransportRequest alloc] initWithPath:path method:ZMMethodGET payload:nil];
    return request;
}

- (void)updateObject:(ZMConversation *)conversation withResponse:(ZMTransportResponse *)response downstreamSync:(id<ZMObjectSync>)downstreamSync;
{
    NOT_USED(downstreamSync);
    conversation.needsToBeUpdatedFromBackend = NO;
    [self resetModifiedKeysWithoutReferenceInConversation:conversation];
    
    NSDictionary *dictionaryPayload = [response.payload asDictionary];
    VerifyReturn(dictionaryPayload != nil);
    [conversation updateWithTransportData:dictionaryPayload serverTimeStamp:nil];
}

- (void)deleteObject:(ZMConversation *)conversation withResponse:(ZMTransportResponse *)response downstreamSync:(id<ZMObjectSync>)downstreamSync;
{
    // Self user has been removed from the group conversation but missed the conversation.member-leave event.
    if (response.HTTPStatus == 403 && conversation.conversationType == ZMConversationTypeGroup && conversation.isSelfAnActiveMember) {
        ZMUser *selfUser = [ZMUser selfUserInContext:self.managedObjectContext];
        [conversation internalRemoveParticipants:@[selfUser] sender:selfUser];
    }
    
    // Conversation has been permanently deleted
    if (response.HTTPStatus == 404 && conversation.conversationType == ZMConversationTypeGroup) {
        [self.managedObjectContext deleteObject:conversation];
    }
    
    if (response.isPermanentylUnavailableError) {
        conversation.needsToBeUpdatedFromBackend = NO;
    }
    
    NOT_USED(downstreamSync);
}

@end


@implementation ZMConversationTranscoder (PaginatedRequest)

- (NSUInteger)maximumRemoteIdentifiersPerRequestForObjectSync:(ZMRemoteIdentifierObjectSync *)sync;
{
    NOT_USED(sync);
    return self.conversationPageSize;
}


- (ZMTransportRequest *)requestForObjectSync:(ZMRemoteIdentifierObjectSync *)sync remoteIdentifiers:(NSSet *)identifiers;
{
    NOT_USED(sync);
    
    NSArray *currentBatchOfConversationIDs = [[identifiers allObjects] mapWithBlock:^id(NSUUID *obj) {
        return obj.transportString;
    }];
    NSString *path = [NSString stringWithFormat:@"%@?ids=%@", ConversationsPath, [currentBatchOfConversationIDs componentsJoinedByString:@","]];

    return [[ZMTransportRequest alloc] initWithPath:path method:ZMMethodGET payload:nil];
}


- (void)didReceiveResponse:(ZMTransportResponse *)response remoteIdentifierObjectSync:(ZMRemoteIdentifierObjectSync *)sync forRemoteIdentifiers:(NSSet *)remoteIdentifiers;
{
    NOT_USED(sync);
    NOT_USED(remoteIdentifiers);
    NSDictionary *payload = [response.payload asDictionary];
    NSArray *conversations = [payload arrayForKey:@"conversations"];
    
    for (NSDictionary *rawConversation in [conversations asDictionaries]) {
        ZMConversation *conversation = [self createConversationFromTransportData:rawConversation serverTimeStamp:[NSDate date] source:ZMConversationSourceSlowSync];
        conversation.needsToBeUpdatedFromBackend = NO;
        
        if (conversation != nil) {
            [self.lastSyncedActiveConversations addObject:conversation];
        }
    }
    
    if (response.result == ZMTransportResponseStatusPermanentError && self.isSyncing) {
        [self.syncStatus failCurrentSyncPhaseWithPhase:self.expectedSyncPhase];
    }
    
    [self finishSyncIfCompleted];
}

@end
