import SwiftUI
import OpenIslandCore
import Observation

#if canImport(Darwin)
import Darwin
#endif

private func debugLog(_ message: String) {
    let logMessage = "[\(Date())] \(message)\n"
    if let data = logMessage.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: "/tmp/openisland.log") {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? logMessage.write(toFile: "/tmp/openisland.log", atomically: true, encoding: .utf8)
        }
    }
}

// 定义私有 C 方法的函数原型
private typealias MRMediaRemoteGetNowPlayingInfoType = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
private typealias MRMediaRemoteSendCommandType = @convention(c) (Int32, CFDictionary?) -> Bool

/// 动态加载 MediaRemote 私有库以避免编译链接错误
private class MediaRemoteLoader: @unchecked Sendable {
    static let shared = MediaRemoteLoader()
    
    var getNowPlayingInfo: MRMediaRemoteGetNowPlayingInfoType?
    var sendCommand: MRMediaRemoteSendCommandType?
    
    private init() {
        debugLog("MediaRemoteLoader init starting...")
        // 动态载入 System PrivateFrameworks 下的 MediaRemote
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        if let handle = dlopen(path, RTLD_NOW) {
            debugLog("MediaRemoteLoader: dlopen success")
            if let getSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
                debugLog("MediaRemoteLoader: found MRMediaRemoteGetNowPlayingInfo")
                getNowPlayingInfo = unsafeBitCast(getSymbol, to: MRMediaRemoteGetNowPlayingInfoType.self)
            } else {
                debugLog("MediaRemoteLoader: dlsym failed for MRMediaRemoteGetNowPlayingInfo")
            }
            if let sendSymbol = dlsym(handle, "MRMediaRemoteSendCommand") {
                debugLog("MediaRemoteLoader: found MRMediaRemoteSendCommand")
                sendCommand = unsafeBitCast(sendSymbol, to: MRMediaRemoteSendCommandType.self)
            } else {
                debugLog("MediaRemoteLoader: dlsym failed for MRMediaRemoteSendCommand")
            }
        } else {
            debugLog("MediaRemoteLoader: dlopen failed")
        }
    }
}

@MainActor
@Observable
class MediaControlModule: IslandModule {
    let id = "media_control"
    
    // 媒体播放模块动态计算优先级
    var priority: IslandModulePriority {
        let hasValidTrack = !title.isEmpty && title != "Not Playing" && title != "No active track"
        return (isPlaying && hasValidTrack) ? .medium : .low
    }
    
    var title: String = ""
    var artist: String = ""
    var isPlaying: Bool = false
    var artwork: NSImage? = nil
    
    var onStatusChanged: (() -> Void)? = nil
    
    private var isActive = false
    private let changeNotification = Notification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification")
    private var timer: Timer? = nil
    
    init() {
        debugLog("MediaControlModule init starting, registering global observer...")
        
        // 自动在本地 /tmp/ 目录下生成获取 NowPlaying 数据的特权脚本
        let scriptContent = """
        import Foundation
        typealias MRMediaRemoteGetNowPlayingInfoType = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_NOW),
              let getSymbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") else {
            print("{}")
            exit(0)
        }
        let getNowPlayingInfo = unsafeBitCast(getSymbol, to: MRMediaRemoteGetNowPlayingInfoType.self)
        let sem = DispatchSemaphore(value: 0)
        getNowPlayingInfo(DispatchQueue.global()) { info in
            guard let info = info as? [String: Any] else {
                print("{}")
                sem.signal()
                return
            }
            let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
            let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
            let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0.0
            var artworkBase64 = ""
            if let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                artworkBase64 = artworkData.base64EncodedString()
            }
            let result: [String: Any] = [
                "title": title,
                "artist": artist,
                "playbackRate": rate,
                "artwork": artworkBase64
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: result, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            } else {
                print("{}")
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2.0)
        exit(0)
        """
        try? scriptContent.write(toFile: "/tmp/openisland_nowplaying.swift", atomically: true, encoding: .utf8)
        debugLog("MediaControlModule: wrote script to /tmp/openisland_nowplaying.swift")

        // 全局注册系统媒体改变的通知监听，而不管是不是 activeModule
        NotificationCenter.default.addObserver(
            forName: changeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            debugLog("MediaControlModule received notification kMRMediaRemoteNowPlayingInfoDidChangeNotification")
            Task { @MainActor [weak self] in
                self?.fetchNowPlayingInfo()
            }
        }
        
        // 延迟 2.0s 再主动拉取一次，防止 XPC 还没建立好
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            debugLog("MediaControlModule init delayed fetch execution")
            Task { @MainActor [weak self] in
                self?.fetchNowPlayingInfo()
            }
        }
        
        // 启动每 5 秒的轻量级轮询定时器作为 fallback，确保状态绝对同步
        self.timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                debugLog("MediaControlModule timer poll fetch")
                self?.fetchNowPlayingInfo()
            }
        }
        
        // 加载当前媒体信息
        fetchNowPlayingInfo()
    }
    
    func leftPillView() -> AnyView {
        AnyView(
            HStack(spacing: 4) {
                Image(systemName: "music.note")
                    .font(.system(size: 9))
                    .foregroundStyle(.pink)
                    .rotationEffect(.degrees(isPlaying ? 360 : 0))
                    .animation(isPlaying ? .linear(duration: 4).repeatForever(autoreverses: false) : .default, value: isPlaying)
            }
        )
    }
    
    func rightPillView() -> AnyView {
        AnyView(
            AudioWaveIndicator(isPlaying: isPlaying)
        )
    }
    
    func expandedView() -> AnyView {
        AnyView(
            MediaControlExpandedView(module: self)
        )
    }
    
    func onActivate() {
        debugLog("MediaControlModule onActivate called. isActive = \(isActive)")
        isActive = true
        fetchNowPlayingInfo()
    }
    
    func onDeactivate() {
        debugLog("MediaControlModule onDeactivate called")
        isActive = false
    }
    
    func togglePlayPause() {
        debugLog("MediaControlModule: togglePlayPause requested")
        // 命令 2 表示 TogglePlayPause
        MediaRemoteLoader.shared.sendCommand?(2, nil)
        
        // 针对网易云这类没有正常返回 rate 状态的软件，我们优先在本地快速切换 isPlaying
        // 这能在用户点击时带来即时 UI 响应，然后再做系统 fetch
        let hasValidTrack = !title.isEmpty && title != "Not Playing" && title != "No active track"
        if hasValidTrack {
            self.isPlaying.toggle()
            debugLog("MediaControlModule: optimistic toggle isPlaying to \(self.isPlaying)")
            self.onStatusChanged?()
        }
        
        // 稍等刷新状态
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.fetchNowPlayingInfo()
        }
    }
    
    func nextTrack() {
        debugLog("MediaControlModule: nextTrack requested")
        // 命令 4 表示 NextTrack
        MediaRemoteLoader.shared.sendCommand?(4, nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.fetchNowPlayingInfo()
        }
    }
    
    func previousTrack() {
        debugLog("MediaControlModule: previousTrack requested")
        // 命令 5 表示 PreviousTrack
        MediaRemoteLoader.shared.sendCommand?(5, nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.fetchNowPlayingInfo()
        }
    }
    
    private func fetchNowPlayingInfo() {
        debugLog("MediaControlModule fetchNowPlayingInfo started")
        
        // 异步在后台线程启动 Process，防止卡顿 App 主线程
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
            process.arguments = ["/tmp/openisland_nowplaying.swift"]
            
            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            
            do {
                try process.run()
                
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                
                if let jsonString = String(data: data, encoding: .utf8), !jsonString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let jsonData = jsonString.data(using: .utf8),
                       let dict = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                        
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            let oldTitle = self.title
                            let oldArtist = self.artist
                            let oldIsPlaying = self.isPlaying
                            
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                self.title = dict["title"] as? String ?? ""
                                self.artist = dict["artist"] as? String ?? ""
                                let rate = dict["playbackRate"] as? Double ?? 0.0
                                
                                debugLog("MediaControlModule swift helper parsed details: title='\(self.title)', artist='\(self.artist)', rate=\(rate)")
                                
                                if let artBase64 = dict["artwork"] as? String, !artBase64.isEmpty,
                                   let artData = Data(base64Encoded: artBase64) {
                                    self.artwork = NSImage(data: artData)
                                } else {
                                    self.artwork = nil
                                }
                                
                                let hasValidTrack = !self.title.isEmpty && self.title != "Not Playing" && self.title != "No active track"
                                if rate > 0.0 {
                                    self.isPlaying = true
                                } else if hasValidTrack {
                                    self.isPlaying = true
                                } else {
                                    self.isPlaying = false
                                }
                                
                                if oldTitle != self.title || oldArtist != self.artist || oldIsPlaying != self.isPlaying {
                                    debugLog("MediaControlModule state changed via swift helper, notifying status change callback")
                                    self.onStatusChanged?()
                                }
                            }
                        }
                    }
                }
            } catch {
                debugLog("MediaControlModule failed to run swift helper: \(error)")
            }
        }
    }
}

// MARK: - Audio Wave Indicator (Pill Right Slot)

struct AudioWaveIndicator: View {
    let isPlaying: Bool
    
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<4) { index in
                WaveBar(isPlaying: isPlaying, index: index)
            }
        }
        .frame(height: 10)
    }
}

struct WaveBar: View {
    let isPlaying: Bool
    let index: Int
    
    @State private var scale: CGFloat = 0.2
    
    private var baseDurations: [Double] { [0.5, 0.35, 0.45, 0.4] }
    private var maxHeights: [CGFloat] { [10, 8, 9, 7] }
    
    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.pink)
            .frame(width: 1.5, height: isPlaying ? maxHeights[index] * scale : 2)
            .onAppear {
                if isPlaying {
                    startAnimating()
                }
            }
            .onChange(of: isPlaying) { _, playing in
                if playing {
                    startAnimating()
                } else {
                    scale = 0.2
                }
            }
    }
    
    private func startAnimating() {
        withAnimation(
            .easeInOut(duration: baseDurations[index])
            .repeatForever(autoreverses: true)
        ) {
            scale = 1.0
        }
    }
}

// MARK: - Media Control Expanded View

struct MediaControlExpandedView: View {
    let module: MediaControlModule
    
    var body: some View {
        VStack(spacing: 12) {
            Text("NOW PLAYING")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
            
            HStack(spacing: 12) {
                // Album artwork
                if let art = module.artwork {
                    Image(nsImage: art)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 3, x: 0, y: 2)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [Color.pink.opacity(0.18), Color.purple.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "music.note")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.pink.opacity(0.85))
                    }
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                    )
                }
                
                // Track & Artist text
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.title.isEmpty ? "No active track" : module.title)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                    
                    Text(module.artist.isEmpty ? "Unknown Artist" : module.artist)
                        .font(.system(size: 10))
                        .lineLimit(1)
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Playback Controls with premium micro-interactions
                HStack(spacing: 8) {
                    MediaControlButton(systemName: "backward.fill") {
                        module.previousTrack()
                    }
                    
                    MediaControlButton(systemName: module.isPlaying ? "pause.fill" : "play.fill", isPrimary: true) {
                        module.togglePlayPause()
                    }
                    
                    MediaControlButton(systemName: "forward.fill") {
                        module.nextTrack()
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Premium Interactive Media Button

struct MediaControlButton: View {
    let systemName: String
    var isPrimary: Bool = false
    let action: () -> Void
    
    @State private var isHovered = false
    @State private var isPressed = false
    
    var body: some View {
        Button(action: {
            action()
        }) {
            Image(systemName: systemName)
                .font(.system(size: isPrimary ? 11 : 8, weight: .bold))
                .foregroundStyle(isPrimary ? .pink : (isHovered ? .white : .white.opacity(0.65)))
                .frame(width: isPrimary ? 28 : 22, height: isPrimary ? 28 : 22)
                .background(
                    Circle()
                        .fill(isPrimary 
                              ? (isPressed ? Color.pink.opacity(0.15) : Color.white.opacity(isHovered ? 0.12 : 0.06))
                              : Color.white.opacity(isPressed ? 0.12 : (isHovered ? 0.08 : 0.0))
                             )
                )
                .overlay(
                    Circle()
                        .stroke(isPrimary 
                                ? Color.pink.opacity(0.2) 
                                : Color.white.opacity(isHovered ? 0.08 : 0.0), 
                                lineWidth: 0.5)
                )
                .scaleEffect(isPressed ? 0.88 : (isHovered ? 1.06 : 1.0))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .onHover { hovering in
            withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) {
                isHovered = hovering
            }
        }
    }
}
