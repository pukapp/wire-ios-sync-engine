//
//  BGPMemberImageStrategy.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2019/11/29.
//  Copyright © 2019 Zeta Project Gmbh. All rights reserved.
//

import UIKit


let NSManagedObjectContextBGPMemberAssetCacheKey = "BGPMemberAssetCache"
extension NSManagedObjectContext
{
    @objc
    public var zm_BGPMemberAssetCache: NSCache<NSUUID, NSData>? {
        get {
            guard zm_isUserInterfaceContext else { return nil }
            return self.userInfo[NSManagedObjectContextBGPMemberAssetCacheKey] as? NSCache
        }
        
        set {
            guard zm_isUserInterfaceContext else { return }
            self.userInfo[NSManagedObjectContextBGPMemberAssetCacheKey] = newValue
        }
    }
}

public extension Notification.Name {
    static let bgpMemberDidRequestPreviewAsset = Notification.Name("bgpMemberDidRequestPreviewAsset")
    static let requestBGPMemberPreviewAssetSuccess = Notification.Name("requestBGPMemberPreviewAssetSuccess")
}

public class BGPMemberImageStrategy : AbstractRequestStrategy {
    fileprivate unowned var uiContext: NSManagedObjectContext
    fileprivate unowned var syncContext: NSManagedObjectContext
    
    fileprivate var requestedPreviewAssets: [UUID : SearchUserAssetKeys?] = [:]
    fileprivate var requestedPreviewAssetsInProgress: Set<UUID> = Set()
    
    fileprivate var observers: [Any] = []
    
    @available (*, unavailable)
    public override init(withManagedObjectContext moc: NSManagedObjectContext, applicationStatus: ApplicationStatus) {
        fatalError()
    }
    
    public init(applicationStatus: ApplicationStatus, managedObjectContext: NSManagedObjectContext) {
        
        self.syncContext = managedObjectContext
        self.uiContext = managedObjectContext.zm_userInterface
        
        super.init(withManagedObjectContext: managedObjectContext, applicationStatus: applicationStatus)
        
        observers.append(NotificationInContext.addObserver(
            name: .bgpMemberDidRequestPreviewAsset,
            context: managedObjectContext.notificationContext,
            using: { [weak self] in
                self?.requestBgpMemberAsset(with: $0)
        })
        )
    }
    
    private func requestBgpMemberAsset(with note: NotificationInContext) {
        guard let smallProfileImageCacheKey = note.object as? String,
            let userId = smallProfileImageCacheKey.components(separatedBy: "&&").first,
            let assetKey = smallProfileImageCacheKey.components(separatedBy: "&&").last,
            let uuid = UUID(uuidString: userId),
            !requestedPreviewAssets.contains(where: { (key, _) -> Bool in
                return key == uuid
            })
            else { return }
        requestedPreviewAssets[uuid] = SearchUserAssetKeys(previewKey: assetKey, completeKey: nil)
        RequestAvailableNotification.notifyNewRequestsAvailable(nil)
    }
    
    public override func nextRequestIfAllowed() -> ZMTransportRequest? {
        let request = fetchAssetRequest()
        request?.setDebugInformationTranscoder(self)
        return request
    }
    
    func fetchAssetRequest() -> ZMTransportRequest? {
        let previewAssetRequestA = requestedPreviewAssets.lazy.filter({ !self.requestedPreviewAssetsInProgress.contains($0.key) && $0.value != nil }).first
        
        if let previewAssetRequest = previewAssetRequestA, let assetKeys = previewAssetRequest.value, let request = request(for: assetKeys, size: .preview, user: previewAssetRequest.key) {
            requestedPreviewAssetsInProgress.insert(previewAssetRequest.key)
            
            request.add(ZMCompletionHandler(on: syncContext, block: { [weak self] (response) in
                self?.processAsset(response: response, for: previewAssetRequest.key, size: .preview)
            }))
            
            return request
        }
        
        return nil
    }
    
    func request(for assetKeys: SearchUserAssetKeys, size: ProfileImageSize, user: UUID) -> ZMTransportRequest? {
        if let key = size == .preview ? assetKeys.preview : assetKeys.complete {
            return ZMTransportRequest(getFromPath: "/assets/v3/\(key)")
        }
        return nil
    }
    
    func processAsset(response: ZMTransportResponse, for user: UUID, size: ProfileImageSize) {
        let tryAgain = response.result != .permanentError && response.result != .success
        
        switch size {
        case .preview:
            if !tryAgain {
                requestedPreviewAssets.removeValue(forKey: user)
            }
            requestedPreviewAssetsInProgress.remove(user)
        default: break
        }
        
        uiContext.performGroupedBlock {
            if response.result == .success {
                if let imageData = response.imageData ?? response.rawData {
                    self.uiContext.zm_BGPMemberAssetCache?.setObject(imageData as NSData, forKey: user as NSUUID)
                    NotificationCenter.default.post(name: .requestBGPMemberPreviewAssetSuccess, object: nil, userInfo: ["userID": user])
                }
            }
        }
    }
}

