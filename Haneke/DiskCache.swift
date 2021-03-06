//
//  DiskCache.swift
//  Haneke
//
//  Created by Hermes Pique on 8/10/14.
//  Copyright (c) 2014 Haneke. All rights reserved.
//

import Foundation

public class DiskCache {
    
    public class func basePath() -> String {
        let cachesPath = NSSearchPathForDirectoriesInDomains(NSSearchPathDirectory.CachesDirectory, NSSearchPathDomainMask.UserDomainMask, true)[0] as String
        let hanekePathComponent = Haneke.Domain
        let basePath = cachesPath.stringByAppendingPathComponent(hanekePathComponent)
        // TODO: Do not recaculate basePath value
        return basePath
    }
    
    public let name : String

    public var size : UInt64 = 0

    public var capacity : UInt64 = 0 {
        didSet {
            dispatch_async(self.cacheQueue, {
                self.controlCapacity()
            })
        }
    }

    public lazy var cachePath : String = {
        let basePath = DiskCache.basePath()
        let cachePath = basePath.stringByAppendingPathComponent(self.name)
        var error : NSError? = nil
        let success = NSFileManager.defaultManager().createDirectoryAtPath(cachePath, withIntermediateDirectories: true, attributes: nil, error: &error)
        if (!success) {
            NSLog("Failed to create directory \(cachePath) with error \(error!)")
        }
        return cachePath
    }()

    public lazy var cacheQueue : dispatch_queue_t = {
        let queueName = Haneke.Domain + "." + self.name
        let cacheQueue = dispatch_queue_create(queueName, nil)
        return cacheQueue
    }()
    
    public init(name : String, capacity : UInt64 = UINT64_MAX) {
        self.name = name
        self.capacity = capacity
        dispatch_async(self.cacheQueue, {
            self.calculateSize()
            self.controlCapacity()
        })
    }
    
    public func setData(getData : @autoclosure () -> NSData?, key : String) {
        dispatch_async(cacheQueue, {
            self.setDataSync(getData, key: key)
        })
    }
    
    public func fetchData(key : String, failure fail : ((NSError?) -> ())? = nil, success succeed : (NSData) -> ()) {
        dispatch_async(cacheQueue, {
            let path = self.pathForKey(key)
            var error: NSError? = nil
            if let data = NSData.dataWithContentsOfFile(path, options: NSDataReadingOptions.allZeros, error: &error) {
                dispatch_async(dispatch_get_main_queue(), {
                   succeed(data)
                })
                self.updateDiskAccessDateAtPath(path)
            } else if let block = fail {
                dispatch_async(dispatch_get_main_queue(), {
                    block(error)
                })
            }
        })
    }

    public func removeData(key : String) {
        dispatch_async(cacheQueue, {
            let fileManager = NSFileManager.defaultManager()
            let path = self.pathForKey(key)
            let attributesOpt : NSDictionary? = fileManager.attributesOfItemAtPath(path, error: nil)
            var error: NSError? = nil
            let success = fileManager.removeItemAtPath(path, error:&error)
            if (success) {
                if let attributes = attributesOpt {
                    self.size -= attributes.fileSize()
                }
            } else {
                NSLog("Failed to remove key \(key) with error \(error!)")
            }
        })
    }
    
    public func removeAllData() {
        let fileManager = NSFileManager.defaultManager()
        let cachePath = self.cachePath
        dispatch_async(cacheQueue, {
            var error: NSError? = nil
            if let contents = fileManager.contentsOfDirectoryAtPath(cachePath, error: &error) as? [String] {
                for pathComponent in contents {
                    let path = cachePath.stringByAppendingPathComponent(pathComponent)
                    if !fileManager.removeItemAtPath(path, error: &error) {
                        NSLog("Failed to remove path \(path) with error \(error!)")
                    }
                }
                self.calculateSize()
            } else {
                NSLog("Failed to list directory with error \(error!)")
            }
        })
    }

    public func updateAccessDate(getData : @autoclosure () -> NSData?, key : String) {
        dispatch_async(cacheQueue, {
            let path = self.pathForKey(key)
            let fileManager = NSFileManager.defaultManager()
            if (!self.updateDiskAccessDateAtPath(path) && !fileManager.fileExistsAtPath(path)){
                let data = getData()
                self.setDataSync(data, key: key)
            }
        })
    }

    public func pathForKey(key : String) -> String {
        var escapedFilename = key.escapedFilename()
        let filename = countElements(escapedFilename) < Int(NAME_MAX) ? escapedFilename : key.MD5Filename()
        let path = self.cachePath.stringByAppendingPathComponent(filename)
        return path
    }
    
    // MARK: Private
    
    private func calculateSize() {
        let fileManager = NSFileManager.defaultManager()
        size = 0
        let cachePath = self.cachePath
        var error : NSError?
        if let contents = fileManager.contentsOfDirectoryAtPath(cachePath, error: &error) as? [String] {
            for pathComponent in contents {
                let path = cachePath.stringByAppendingPathComponent(pathComponent)
                if let attributes : NSDictionary = fileManager.attributesOfItemAtPath(path, error: &error) {
                    size += attributes.fileSize()
                } else {
                    NSLog("Failed to read file size of \(path) with error \(error!)")
                }
            }
        } else {
            NSLog("Failed to list directory with error \(error!)")
        }
    }
    
    private func controlCapacity() {
        if self.size <= self.capacity { return }
        
        let fileManager = NSFileManager.defaultManager()
        let cachePath = self.cachePath
        fileManager.enumerateContentsOfDirectoryAtPath(cachePath, orderedByProperty: NSURLContentModificationDateKey, ascending: true) { (URL : NSURL, _, inout stop : Bool) -> Void in
            
            if let path = URL.path {
                self.removeFileAtPath(path)

                stop = self.size <= self.capacity
            }
        }
    }
    
    private func setDataSync(getData : @autoclosure () -> NSData?, key : String) {
        let path = self.pathForKey(key)
        var error: NSError? = nil
        if let data = getData() {
            let fileManager = NSFileManager.defaultManager()
            let previousAttributes : NSDictionary? = fileManager.attributesOfItemAtPath(path, error: nil)
            let success = data.writeToFile(path, options: NSDataWritingOptions.AtomicWrite, error:&error)
            if (!success) {
                NSLog("Failed to write key \(key) with error \(error!)")
            }
            if let attributes = previousAttributes {
                self.size -= attributes.fileSize()
            }
            self.size += data.length
            self.controlCapacity()
        } else {
            NSLog("Failed to get data for key \(key)")
        }
    }
    
    private func updateDiskAccessDateAtPath(path : String) -> Bool {
        let fileManager = NSFileManager.defaultManager()
        let now = NSDate()
        var error : NSError?
        let success = fileManager.setAttributes([NSFileModificationDate : now], ofItemAtPath: path, error: &error)
        if !success {
            NSLog("Failed to update access date with error \(error!)")
        }
        return success;
    }
    
    private func removeFileAtPath(path:String) {
        var error : NSError?
        let fileManager = NSFileManager.defaultManager()
        if let attributes : NSDictionary = fileManager.attributesOfItemAtPath(path, error: &error) {
            let modificationDate = attributes.fileModificationDate()
            NSLog("%@", modificationDate!)
            let fileSize = attributes.fileSize()
            if fileManager.removeItemAtPath(path, error: &error) {
                self.size -= fileSize
            } else {
                NSLog("Failed to remove file with error \(error)")
            }
        } else {
            NSLog("Failed to remove file with error \(error)")
        }
    }
}
