//
//  ConversationImageAssetUpdateStrategy.swift
//  WireSyncEngine-ios
//
//  Created by 王杰 on 2019/1/22.
//  Copyright © 2019年 Zeta Project Gmbh. All rights reserved.
//

import Foundation
import WireRequestStrategy

@objc public final class ImageAssetUpdateStrategy: AbstractRequestStrategy {
    
    internal let requestFactory = AssetRequestFactory()
    
    internal var preViewRequestSync: ZMSingleRequestSync?
    
    internal var completeRequestSync: ZMSingleRequestSync?

    internal let moc: NSManagedObjectContext
    
    fileprivate var observers: [Any] = []
    
    internal weak var imageUploadStatus: ImageUploadStatusProtocol?
    
    @objc public convenience init(managedObjectContext: NSManagedObjectContext, applicationStatusDirectory: ApplicationStatusDirectory) {
        self.init(managedObjectContext: managedObjectContext, applicationStatus: applicationStatusDirectory, imageUploadStatus: applicationStatusDirectory.imageUpdateStatus)
    }
    
    internal init(managedObjectContext: NSManagedObjectContext, applicationStatus: ApplicationStatus, imageUploadStatus: ImageUploadStatusProtocol) {
        self.moc = managedObjectContext
        self.imageUploadStatus = imageUploadStatus
        super.init(withManagedObjectContext: managedObjectContext, applicationStatus: applicationStatus)
        
        self.preViewRequestSync = ZMSingleRequestSync(singleRequestTranscoder: self, groupQueue: moc)
        self.completeRequestSync = ZMSingleRequestSync(singleRequestTranscoder: self, groupQueue: moc)
    }
    
    
    public override func nextRequestIfAllowed() -> ZMTransportRequest? {
        
        if let sync = self.preViewRequestSync,self.imageUploadStatus?.requestedPreview == false {
            sync.readyForNextRequestIfNotBusy()
            return sync.nextRequest()
        }
        if let sync = self.completeRequestSync, self.imageUploadStatus?.requestedComplete == false {
            sync.readyForNextRequestIfNotBusy()
            return sync.nextRequest()
        }
        return nil
    }
}

extension ImageAssetUpdateStrategy: ZMContextChangeTrackerSource {
    
    public var contextChangeTrackers: [ZMContextChangeTracker] {
        return []
    }
    
}

extension ImageAssetUpdateStrategy: ZMSingleRequestTranscoder {
    
    public func request(for sync: ZMSingleRequestSync) -> ZMTransportRequest? {
        if let previewSync = self.preViewRequestSync,previewSync == sync {
            if let image = imageUploadStatus?.previewImageData() {
                let request = requestFactory.upstreamRequestForAsset(withData: image, shareable: true, retention: .eternal)
                self.imageUploadStatus?.requestedPreview = true
                return request
            }
        }
        if let completeSync = self.completeRequestSync,completeSync == sync {
            if let image = imageUploadStatus?.completeImageData() {
                let request = requestFactory.upstreamRequestForAsset(withData: image, shareable: true, retention: .eternal)
                self.imageUploadStatus?.requestedComplete = true
                return request
            }
        }
        return nil
    }
    
    public func didReceive(_ response: ZMTransportResponse, forSingleRequest sync: ZMSingleRequestSync) {
        guard response.result == .success else {
            let error = AssetTransportError(response: response)
            if let previewSync = self.preViewRequestSync,previewSync == sync {
                self.imageUploadStatus?.requestedPreview = false
                imageUploadStatus?.uploadingFailed(size: .preview,error: error)
            }
            if let completeSync = self.completeRequestSync,completeSync == sync {
                self.imageUploadStatus?.requestedComplete = false
                imageUploadStatus?.uploadingFailed(size: .complete,error: error)
            }
            return
        }
        guard let payload = response.payload?.asDictionary(), let assetId = payload["key"] as? String else { fatal("No asset ID present in payload: \(String(describing: response.payload))") }
        if let previewSync = self.preViewRequestSync,previewSync == sync {
            self.imageUploadStatus?.requestedPreview = false
            imageUploadStatus?.uploadingDone(size: .preview,assetId: assetId)
        }
        if let completeSync = self.completeRequestSync,completeSync == sync {
            self.imageUploadStatus?.requestedComplete = false
            imageUploadStatus?.uploadingDone(size: .complete,assetId: assetId)
        }
    }
}
