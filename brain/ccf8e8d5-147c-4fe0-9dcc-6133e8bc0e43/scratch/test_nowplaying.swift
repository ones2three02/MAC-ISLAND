import Foundation

typealias MRMediaRemoteGetNowPlayingInfoType = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void

let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
guard let handle = dlopen(path, RTLD_NOW) else {
    print("Error: dlopen failed for MediaRemote framework")
    exit(1)
}

guard let getSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
    print("Error: dlsym failed for MRMediaRemoteGetNowPlayingInfo")
    exit(1)
}

let getNowPlayingInfo = unsafeBitCast(getSymbol, to: MRMediaRemoteGetNowPlayingInfoType.self)

print("Starting fetch from MediaRemote...")

getNowPlayingInfo(DispatchQueue.main) { info in
    if let info = info as? [String: Any] {
        print("Fetched Success:")
        for (key, value) in info {
            if key == "kMRMediaRemoteNowPlayingInfoArtworkData" {
                print("  \(key): <Data of size \((value as! Data).count) bytes>")
            } else {
                print("  \(key): \(value)")
            }
        }
    } else {
        print("Fetched empty or nil dictionary")
    }
    CFRunLoopStop(CFRunLoopGetCurrent())
}

// 启动 RunLoop 来让 main queue 执行回调
// 设置一个 2 秒超时，防止死锁
DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
    print("Timeout, stopping RunLoop...")
    CFRunLoopStop(CFRunLoopGetMain())
}

CFRunLoopRun()
print("Done.")
