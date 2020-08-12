//
//  test.swift
//  WireSyncEngine-ios
//
//  Created by 老西瓜 on 2020/8/7.
//  Copyright © 2020 Zeta Project Gmbh. All rights reserved.
//

import Foundation

private let zmLog = ZMSLog(tag: "calling")

public struct CVPixelBufferConvertDataHelper {
    
    private static var pixelBufferPool: CVPixelBufferPool?
    
    var pixelBuffer: CVPixelBuffer?
    
    var pixelFormatType: OSType
    var width: Int
    var height: Int
    var yBytesPerRow: Int
    var cbcrBytesPerRow: Int
    ///存储的时间戳
    var timeStampNs: Int64
    var yLength: Int {
        get {
           return yBytesPerRow * height
        }
    }
    
    public var aaadescription: String {
        return "CVPixelBufferConvertData -- description \(pixelFormatType), \(width), \(height), \(yBytesPerRow), \(cbcrBytesPerRow)"
    }
    
    public init(with pixelBuffer: CVPixelBuffer, timeStampNs: Int64) {
        self.pixelBuffer = pixelBuffer
        
        self.pixelFormatType = CVPixelBufferGetPixelFormatType(pixelBuffer)
        self.width = CVPixelBufferGetWidth(pixelBuffer)
        self.height = CVPixelBufferGetHeight(pixelBuffer)
        self.yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        self.cbcrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        self.timeStampNs = timeStampNs
        
        //zmLog.info("CVPixelBufferConvertData -- init(with pixelBuffer) \(pixelFormatType), \(width), \(height), \(yBytesPerRow), \(cbcrBytesPerRow)")
    }
    
    func getPixelBufferData() -> Data {
        guard let pixelBuffer = pixelBuffer else { fatal("getPixelBufferData error") }
        //TODO:可以通过CVPixelBufferGetPlaneCount判断一下pixelBuffer是否有两个Plane
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        var data = Data()
        let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        data.append(Data(bytes: yBaseAddress!, count: Int(yLength)))

        let cbcrBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        let cbcrLength = cbcrBytesPerRow * height / 2
        data.append(Data(bytes: cbcrBaseAddress!, count: Int(cbcrLength)))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        
        return data
    }

    static func configPixelBufferPool(with pixelFormatType: OSType, width: Int, height: Int, yBytesPerRow: Int) -> Bool {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormatType,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferBytesPerRowAlignmentKey: yBytesPerRow
        ]
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &CVPixelBufferConvertDataHelper.pixelBufferPool)
        return status == kCVReturnSuccess
    }

    func getPixelBuffer(from data: UnsafeRawPointer, offset: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
        
        var _pixelBuffer: CVPixelBuffer?
        //用CVPixelBufferPoolCreatePixelBuffer创建CVPixelBuffer会更快一些
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &_pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer = _pixelBuffer else {
            print("无法生成PixelBuffer CVPixelBufferPoolCreatePixelBuffer error")
            return nil
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))
        let yBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        memcpy(yBaseAddress, data.advanced(by: offset), yLength)
        let cbcrBaseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        let cbcrLength = cbcrBytesPerRow * height / 2
        memcpy(cbcrBaseAddress, data.advanced(by: offset + yLength), cbcrLength)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, CVPixelBufferLockFlags(rawValue: 0))

        return pixelBuffer
    }

}


public extension CVPixelBufferConvertDataHelper {
    
    func getSocketSendData() -> Data {
        var data = Data()

        data.append(pixelFormatType.asData)
        data.append(width.asData)
        data.append(height.asData)
        data.append(yBytesPerRow.asData)
        data.append(cbcrBytesPerRow.asData)
        data.append(timeStampNs.asData)
        let pixelBufferData = self.getPixelBufferData()
        data.append(pixelBufferData)
        
        return data
    }
    
    init?(data: Data) {
        //预先初始化，否则无法在closure中被赋值
        self.pixelFormatType = 0
        self.width = 0
        self.height = 0
        self.yBytesPerRow = 0
        self.cbcrBytesPerRow = 0
        self.timeStampNs = 0
        
        let osTypeSize = MemoryLayout<OSType>.size
        let intSize = MemoryLayout<Int>.size
        var offset: Int = 0
        //把data转换为指针，用指针进行memcpy操作，比用subdata快上百倍
        //把data转换为指针，用指针进行memcpy操作，比用subdata快上百倍
        data.withUnsafeBytes { dataBytes in
            var pixelF: OSType = 0
            memcpy(&pixelF, dataBytes.baseAddress!, osTypeSize)
            self.pixelFormatType = pixelF
            offset += osTypeSize
            
            var width: Int = 0
            memcpy(&width, dataBytes.baseAddress!.advanced(by: offset), intSize)
            self.width = width
            offset += intSize
            
            var height: Int = 0
            memcpy(&height, dataBytes.baseAddress!.advanced(by: offset), intSize)
            self.height = height
            offset += intSize
            
            var yBytesPerRow: Int = 0
            memcpy(&yBytesPerRow, dataBytes.baseAddress!.advanced(by: offset), intSize)
            self.yBytesPerRow = yBytesPerRow
            offset += intSize
            
            var cbcrBytesPerRow: Int = 0
            memcpy(&cbcrBytesPerRow, dataBytes.baseAddress!.advanced(by: offset), intSize)
            self.cbcrBytesPerRow = cbcrBytesPerRow
            offset += intSize
            
            var timeStampNs: Int64 = 0
            let int64TypeSize = MemoryLayout<Int64>.size
            memcpy(&timeStampNs, dataBytes.baseAddress!.advanced(by: offset), int64TypeSize)
            self.timeStampNs = timeStampNs
            offset += int64TypeSize
            
            print("init?(with data) \(pixelF),  \(width),  \(height),  \(yBytesPerRow),  \(cbcrBytesPerRow)")
            if CVPixelBufferConvertDataHelper.pixelBufferPool == nil,
                !CVPixelBufferConvertDataHelper.configPixelBufferPool(with: pixelFormatType, width: width, height: height, yBytesPerRow: yBytesPerRow) {
                fatalError()
            }
            
            //pixelBuffer 的 Data 数据不正确
            guard cbcrBytesPerRow * height / 2 + yLength == data.count - offset,
                 let pixelBuffer = self.getPixelBuffer(from: dataBytes.baseAddress!, offset: offset, pool: CVPixelBufferConvertDataHelper.pixelBufferPool!) else {
                    fatalError()
            }
            self.pixelBuffer = pixelBuffer
        }
    }

}

fileprivate extension Int {
    
    var asData: Data {
        return withUnsafePointer(to: self) {
            Data(bytes: $0, count: MemoryLayout.size(ofValue: self))
        }
    }
    
}

fileprivate extension Int64 {
    
    var asData: Data {
        return withUnsafePointer(to: self) {
            Data(bytes: $0, count: MemoryLayout.size(ofValue: self))
        }
    }
    
}

fileprivate extension OSType {
    
    var asData: Data {
        return withUnsafePointer(to: self) {
            Data(bytes: $0, count: MemoryLayout.size(ofValue: self))
        }
    }
    
}
