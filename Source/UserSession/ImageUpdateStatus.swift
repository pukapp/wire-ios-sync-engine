//
// Wire
// Copyright (C) 2017 Wire Swiss GmbH
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


import Foundation
import WireDataModel

enum ImageUploadError:Error {
    case preprocessError
    case uploadError
}

public final class ImageUpdateStatus: NSObject {
    
    fileprivate var log = ZMSLog(tag: "UserProfileImageUpdateStatus")
    public var previewData:Data?
    public var completeData:Data?
    public var previewId:String?
    public var completeId:String?
    public var requestedPreview:Bool = false
    public var requestedComplete:Bool = false
    public var currentCallBack:((String,String) -> Void)?
    public var errorCallBack:((Error) -> Void)?
    fileprivate let syncMOC: NSManagedObjectContext
    fileprivate let uiMOC: NSManagedObjectContext
    internal let queue: OperationQueue
    
    internal var preprocessor: ZMAssetsPreprocessorProtocol?

    internal fileprivate(set) var assetsToDelete = Set<String>()
    
    public init(managedObjectContext: NSManagedObjectContext) {
        log.debug("Created")
        self.syncMOC = managedObjectContext
        self.uiMOC = managedObjectContext.zm_userInterface
        self.queue = ZMImagePreprocessor.createSuitableImagePreprocessingQueue()
        super.init()
        
        // Check if we should re-upload an existing v2 in case we never uploaded a v3 asset.
        self.preprocessor = ZMAssetsPreprocessor(delegate: self)
    }
    
    internal func resetImageState(size:ProfileImageSize) {
        if .preview == size {
            self.previewData = nil
        }
        if .complete == size  {
            self.completeData = nil
        }
        
        
    }
    
    func callback() {
        guard let previewid = self.previewId,let completeid = self.completeId else {return}
        self.currentCallBack?(previewid,completeid)
    }
    
    deinit {
        log.debug("Deallocated")
    }
}

// Called from the UI to update a v3 image
extension ImageUpdateStatus: ImageUpdateProtocol {
    
    /// Starts the process of updating profile picture. 
    ///
    /// - Important: Expected to be run from UI thread
    ///
    /// - Parameter imageData: image data of the new profile picture
    
    public func updateImage(imageData: Data,assetIdCallback:((String,String) -> Void)?,errorCallback:((Error) -> Void)?) {
        self.currentCallBack = assetIdCallback
        self.errorCallBack = errorCallback
        self.previewId = nil
        self.completeId = nil
        reuploadExisingImageIfNeeded(data:imageData)
    }
}

// Called internally with existing image data to reupload to v3 (no preprocessing needed)
extension ImageUpdateStatus : ZMContextChangeTracker {

    public func objectsDidChange(_ object: Set<NSManagedObject>) {
        return
    }

    public func fetchRequestForTrackedObjects() -> NSFetchRequest<NSFetchRequestResult>? {
        return nil
    }

    public func addTrackedObjects(_ objects: Set<NSManagedObject>) {
        // no-op
    }

    internal func reuploadExisingImageIfNeeded(data:Data) {
        let imageOwner = UserProfileImageOwner(imageData: data)
        guard let operations = preprocessor?.operations(forPreprocessingImageOwner: imageOwner), !operations.isEmpty else {
            print("预处理错误")
            return
        }
        queue.addOperations(operations, waitUntilFinished: false)
    }
}

extension ImageUpdateStatus: ZMAssetsPreprocessorDelegate {
    
    public func completedDownsampleOperation(_ operation: ZMImageDownsampleOperationProtocol, imageOwner: ZMImageOwner) {
        if operation.format == .profile {
            self.previewData = operation.downsampleImageData
        }
        if operation.format == .medium {
            self.completeData = operation.downsampleImageData
        }
        if self.completeData != nil && self.previewData != nil {
            DispatchQueue.main.async {
                RequestAvailableNotification.notifyNewRequestsAvailable(self)
            }
        }
    }
    
    public func failedPreprocessingImageOwner(_ imageOwner: ZMImageOwner) {
        self.errorCallBack?(ImageUploadError.preprocessError)
    }
    
    public func didCompleteProcessingImageOwner(_ imageOwner: ZMImageOwner) {
        
    }
    
    public func preprocessingCompleteOperation(for imageOwner: ZMImageOwner) -> Operation? {
        let dispatchGroup = syncMOC.dispatchGroup
        dispatchGroup?.enter()
        return BlockOperation() {
            dispatchGroup?.leave()
        }
    }
}

extension ImageUpdateStatus: ImageUploadStatusProtocol {
    
    
    func previewImageData() -> Data? {
        return self.previewData
    }
    
    func completeImageData() -> Data? {
        return self.completeData
    }
    
    /// Checks if there is an image to upload
    ///
    /// - Important: should be called from sync thread
    /// - Parameter size: which image size to check
    /// - Returns: true if there is an image of this size ready for upload
    internal func hasImageToUpload() -> Bool {
        return self.previewData != nil || self.completeData != nil
    }
    
    /// Marks the image as uploaded successfully
    ///
    /// - Parameters:
    ///   - imageSize: size of the image
    ///   - assetId: resulting asset identifier after uploading it to the store
    internal func uploadingDone(size: ProfileImageSize,assetId: String) {
        if size == .preview {
            self.previewId = assetId
        }
        if size == .complete {
            self.completeId = assetId
        }
        self.callback()
        self.resetImageState(size:size)
    }
    
    /// Marks the image as failed to upload
    ///
    /// - Parameters:
    ///   - imageSize: size of the image
    ///   - error: transport error
    internal func uploadingFailed(size: ProfileImageSize,error: Error) {
        self.errorCallBack?(ImageUploadError.uploadError)
        self.resetImageState(size:size)
    }
}
