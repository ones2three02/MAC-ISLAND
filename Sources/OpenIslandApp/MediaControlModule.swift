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
    
    var elapsedTime: Double = 0.0
    var duration: Double = 0.0
    var playbackRate: Double = 0.0
    var lastUpdateTimestamp: Double = Date().timeIntervalSince1970
    
    var lyricLines: [LyricLine] = []
    var plainLyrics: String? = nil
    var currentLyricText: String = ""
    
    private var fetchedTitle: String = ""
    private var fetchedArtist: String = ""
    
    @ObservationIgnored
    private var fetchTask: Task<Void, Never>? = nil
    @ObservationIgnored
    private var lyricsTask: Task<Void, Never>? = nil
    
    var currentPosition: Double {
        guard isPlaying else { return elapsedTime }
        let elapsedSinceUpdate = Date().timeIntervalSince1970 - lastUpdateTimestamp
        return min(duration, elapsedTime + elapsedSinceUpdate * playbackRate)
    }
    
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
            let elapsedTime = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double ?? 0.0
            let duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double ?? 0.0
            let timestampDate = info["kMRMediaRemoteNowPlayingInfoTimestamp"] as? Date
            let timestamp = timestampDate?.timeIntervalSince1970 ?? Date().timeIntervalSince1970
            
            var artworkBase64 = ""
            if let artworkData = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data {
                artworkBase64 = artworkData.base64EncodedString()
            }
            let result: [String: Any] = [
                "title": title,
                "artist": artist,
                "playbackRate": rate,
                "elapsedTime": elapsedTime,
                "duration": duration,
                "timestamp": timestamp,
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
    
    var leftPillWidth: CGFloat {
        return 24
    }
    
    var rightPillWidth: CGFloat {
        let showLyrics = UserDefaults.standard.bool(forKey: "showLyricsOnClosedIsland")
        if isPlaying && showLyrics {
            let currentLyric = currentLyricText(at: currentPosition)
            if !currentLyric.isEmpty {
                // 使用固定的 160pt 宽度，避免灵动岛药丸因歌词长短不一而频繁抖动、缩放。
                // 只有在进入/退出播歌或歌词有无状态切换时，才会有平滑的伸缩动画。
                return 160
            }
        }
        return 24
    }
    
    func leftPillView() -> AnyView {
        AnyView(
            HStack(spacing: 4) {
                Image(systemName: "music.note")
                    .font(.system(size: 9))
                    .foregroundStyle(.pink)
                    .rotationEffect(.degrees(self.isPlaying ? 360 : 0))
                    .animation(self.isPlaying ? .linear(duration: 4).repeatForever(autoreverses: false) : .default, value: self.isPlaying)
            }
        )
    }
    
    func rightPillView() -> AnyView {
        AnyView(
            TimelineView(.animation(minimumInterval: 0.2)) { timeline in
                let currentLyric = self.currentLyricText(at: self.currentPosition)
                let showLyrics = UserDefaults.standard.bool(forKey: "showLyricsOnClosedIsland")
                
                HStack(spacing: 6) {
                    if self.isPlaying && showLyrics && !currentLyric.isEmpty {
                        ZStack(alignment: .trailing) {
                            ClosedIslandMarqueeText(text: currentLyric, containerWidth: self.rightPillWidth - 36)
                                .transition(.asymmetric(
                                    insertion: .push(from: .bottom).combined(with: .opacity),
                                    removal: .push(from: .top).combined(with: .opacity)
                                ))
                                .id(currentLyric)
                        }
                        .frame(maxWidth: self.rightPillWidth > 36 ? self.rightPillWidth - 36 : 0, alignment: .trailing)
                        .clipped()
                    }
                    
                    AudioWaveIndicator(isPlaying: self.isPlaying)
                        .frame(width: 24, alignment: .trailing)
                }
                .frame(width: self.rightPillWidth, alignment: .trailing)
                .animation(.spring(response: 0.35, dampingFraction: 0.85), value: currentLyric)
            }
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
        
        fetchTask?.cancel()
        fetchTask = Task {
            do {
                try await Task.sleep(for: .seconds(0.15))
            } catch {
                return
            }
            if Task.isCancelled { return }
            
            let resultDict = await performFetchSubprocess()
            if Task.isCancelled { return }
            
            updateState(with: resultDict)
        }
    }
    
    nonisolated private func performFetchSubprocess() async -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = ["/tmp/openisland_nowplaying.swift"]
        
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try process.run()
                        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        process.waitUntilExit()
                        
                        if let jsonString = String(data: data, encoding: .utf8),
                           !jsonString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           let jsonData = jsonString.data(using: .utf8),
                           let dict = try? JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                            continuation.resume(returning: dict)
                        } else {
                            continuation.resume(returning: nil)
                        }
                    } catch {
                        debugLog("MediaControlModule failed to run swift helper: \(error)")
                        continuation.resume(returning: nil)
                    }
                }
            }
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
        }
    }
    
    @MainActor
    private func updateState(with dict: [String: Any]?) {
        guard let dict = dict else { return }
        let oldTitle = self.title
        let oldArtist = self.artist
        let oldIsPlaying = self.isPlaying
        
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.title = dict["title"] as? String ?? ""
            self.artist = dict["artist"] as? String ?? ""
            self.elapsedTime = dict["elapsedTime"] as? Double ?? 0.0
            self.duration = dict["duration"] as? Double ?? 0.0
            self.playbackRate = dict["playbackRate"] as? Double ?? 0.0
            self.lastUpdateTimestamp = dict["timestamp"] as? Double ?? Date().timeIntervalSince1970
            let rate = self.playbackRate
            
            debugLog("MediaControlModule swift helper parsed details: title='\(self.title)', artist='\(self.artist)', rate=\(rate), elapsed=\(self.elapsedTime), duration=\(self.duration)")
            
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
                if oldTitle != self.title || oldArtist != self.artist {
                    self.checkAndFetchLyrics()
                }
                self.onStatusChanged?()
            }
        }
    }
    
    // MARK: - Lyrics & Default Music App Functions
    
    func openDefaultMusicApp() {
        let bundleId = UserDefaults.standard.string(forKey: "defaultMusicAppBundleIdentifier") ?? "com.apple.Music"
        debugLog("MediaControlModule: Opening default music app: \(bundleId)")
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error = error {
                    debugLog("MediaControlModule: Failed to open default music app \(bundleId): \(error.localizedDescription)")
                }
            }
        } else {
            // Fallback for launchApplication
            NSWorkspace.shared.launchApplication(withBundleIdentifier: bundleId, options: [], additionalEventParamDescriptor: nil, launchIdentifier: nil)
        }
    }
    
    func checkAndFetchLyrics() {
        let currentTitle = self.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let currentArtist = self.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !currentTitle.isEmpty, currentTitle != "Not Playing", currentTitle != "No active track" else {
            self.lyricLines = []
            self.plainLyrics = nil
            self.currentLyricText = ""
            return
        }
        
        guard currentTitle != fetchedTitle || currentArtist != fetchedArtist else { return }
        fetchedTitle = currentTitle
        fetchedArtist = currentArtist
        
        self.lyricLines = []
        self.plainLyrics = nil
        self.currentLyricText = ""
        
        let artistName = currentArtist
        let trackName = currentTitle
        
        debugLog("MediaControlModule starting fetch lyrics for: \(artistName) - \(trackName)")
        
        lyricsTask?.cancel()
        lyricsTask = Task {
            if Task.isCancelled { return }
            
            // 1. Try get API
            var components = URLComponents(string: "https://lrclib.net/api/get")!
            components.queryItems = [
                URLQueryItem(name: "artist_name", value: artistName),
                URLQueryItem(name: "track_name", value: trackName)
            ]
            if self.duration > 0 {
                components.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(round(self.duration)))))
            }
            
            guard let url = components.url else { return }
            if Task.isCancelled { return }
            
            do {
                let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
                if Task.isCancelled { return }
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        if let synced = json["syncedLyrics"] as? String, !synced.isEmpty {
                            self.applyLyrics(synced: synced, plain: json["plainLyrics"] as? String)
                            return
                        }
                    }
                }
            } catch {
                debugLog("MediaControlModule get lyrics API error: \(error)")
            }
            
            if Task.isCancelled { return }
            
            // 2. Try search API
            var searchComponents = URLComponents(string: "https://lrclib.net/api/search")!
            searchComponents.queryItems = [
                URLQueryItem(name: "q", value: "\(artistName) \(trackName)")
            ]
            
            guard let searchUrl = searchComponents.url else { return }
            if Task.isCancelled { return }
            
            do {
                let (data, response) = try await URLSession.shared.data(for: URLRequest(url: searchUrl))
                if Task.isCancelled { return }
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                    if let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                        let syncedItems = array.filter { !($0["syncedLyrics"] as? String ?? "").isEmpty }
                        if !syncedItems.isEmpty {
                            let bestItem: [String: Any]
                            if self.duration > 0 {
                                bestItem = syncedItems.min(by: {
                                    let d1 = abs(($0["duration"] as? Double ?? 0.0) - self.duration)
                                    let d2 = abs(($1["duration"] as? Double ?? 0.0) - self.duration)
                                    return d1 < d2
                                }) ?? syncedItems[0]
                            } else {
                                bestItem = syncedItems[0]
                            }
                            
                            if Task.isCancelled { return }
                            if let synced = bestItem["syncedLyrics"] as? String {
                                self.applyLyrics(synced: synced, plain: bestItem["plainLyrics"] as? String)
                                return
                            }
                        }
                        
                        if Task.isCancelled { return }
                        if let firstItem = array.first, let plain = firstItem["plainLyrics"] as? String {
                            self.applyLyrics(synced: nil, plain: plain)
                            return
                        }
                    }
                }
            } catch {
                debugLog("MediaControlModule search lyrics API error: \(error)")
            }
            
            debugLog("MediaControlModule failed to find any lyrics for: \(artistName) - \(trackName)")
        }
    }
    
    private func applyLyrics(synced: String?, plain: String?) {
        var parsed: [LyricLine] = []
        if let synced = synced, !synced.isEmpty {
            parsed = self.parseLRC(synced)
        }
        
        self.lyricLines = parsed
        self.plainLyrics = plain
        
        debugLog("MediaControlModule lyrics loaded: syncedCount=\(parsed.count), hasPlain=\(plain != nil)")
        self.onStatusChanged?()
    }
    
    private func parseLRC(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        let rawLines = lrc.components(separatedBy: .newlines)
        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            
            var textIndex = trimmed.startIndex
            var timeStrings: [String] = []
            while textIndex < trimmed.endIndex, trimmed[textIndex] == "[" {
                if let closeBracketIndex = trimmed[textIndex...].firstIndex(of: "]") ?? trimmed[textIndex...].firstIndex(of: ")") {
                    let startIdx = trimmed.index(after: textIndex)
                    let timeStr = String(trimmed[startIdx..<closeBracketIndex])
                    timeStrings.append(timeStr)
                    textIndex = trimmed.index(after: closeBracketIndex)
                } else {
                    break
                }
            }
            let lyricsText = String(trimmed[textIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
            for timeStr in timeStrings {
                if let seconds = parseTime(timeStr) {
                    lines.append(LyricLine(time: seconds, text: lyricsText))
                }
            }
        }
        return lines.sorted(by: { $0.time < $1.time })
    }
    
    private func parseTime(_ timeStr: String) -> TimeInterval? {
        let components = timeStr.components(separatedBy: ":")
        guard components.count >= 2 else { return nil }
        guard let minutes = Double(components[0]) else { return nil }
        guard let seconds = Double(components[1]) else { return nil }
        return minutes * 60.0 + seconds
    }
    
    func currentLyricText(at time: Double) -> String {
        guard !lyricLines.isEmpty else { return "" }
        let matching = lyricLines.filter { $0.time <= time }
        return matching.last?.text ?? ""
    }
    
    func currentLyricLineIndex(at time: Double) -> Int? {
        guard !lyricLines.isEmpty else { return nil }
        let matching = lyricLines.filter { $0.time <= time }
        return matching.isEmpty ? nil : matching.count - 1
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
            // Header: NOW PLAYING & Open Player Button
            HStack {
                Text("NOW PLAYING")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.gray)
                
                Spacer()
                
                Button {
                    module.openDefaultMusicApp()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                .help("打开默认播放器")
            }
            
            let hasValidTrack = !module.title.isEmpty && module.title != "Not Playing" && module.title != "No active track"
            
            if !hasValidTrack {
                // Empty state to open default player
                VStack(spacing: 10) {
                    Text("未启动音乐软件")
                        .font(.system(size: 11))
                        .foregroundStyle(.gray)
                    
                    Button {
                        module.openDefaultMusicApp()
                    } label: {
                        Text("打开默认播放器")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.pink.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 0) {
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
                            Text(module.title)
                                .font(.system(size: 12, weight: .bold))
                                .lineLimit(1)
                                .foregroundStyle(.white)
                            
                            Text(module.artist.isEmpty ? "Unknown Artist" : module.artist)
                                .font(.system(size: 10))
                                .lineLimit(1)
                                .foregroundStyle(.gray)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        // Playback Controls
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
                    
                    // Real-time scrolling lyrics view (if available)
                    if !module.lyricLines.isEmpty || (module.plainLyrics != nil && !module.plainLyrics!.isEmpty) {
                        Divider()
                            .background(Color.white.opacity(0.06))
                            .padding(.horizontal, 10)
                        
                        ExpandedLyricsView(module: module)
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                            .padding(.bottom, 8)
                    }
                }
                .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.04), lineWidth: 0.5)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Expanded Lyrics View

struct ExpandedLyricsView: View {
    let module: MediaControlModule
    
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { timeline in
            let pos = module.currentPosition
            let lines = module.lyricLines
            
            if lines.isEmpty {
                if let plain = module.plainLyrics, !plain.isEmpty {
                    Text(plain.components(separatedBy: .newlines).first ?? "")
                        .font(.system(size: 11)).italic()
                        .foregroundStyle(.gray)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                } else {
                    EmptyView()
                }
            } else {
                let currentIndex = module.currentLyricLineIndex(at: pos) ?? -1
                
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 8) {
                            // Empty space at the top to center first lines
                            Spacer().frame(height: 16)
                            
                            ForEach(0..<lines.count, id: \.self) { index in
                                Text(lines[index].text)
                                    .font(.system(size: index == currentIndex ? 12 : 10, weight: index == currentIndex ? .bold : .medium))
                                    .foregroundStyle(index == currentIndex ? Color.pink : Color.white.opacity(0.35))
                                    .scaleEffect(index == currentIndex ? 1.04 : 1.0)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .multilineTextAlignment(.center)
                                    .id(index)
                                    .animation(.spring(response: 0.3, dampingFraction: 0.75), value: currentIndex)
                            }
                            
                            // Empty space at the bottom to center last lines
                            Spacer().frame(height: 16)
                        }
                    }
                    .frame(height: 60) // Fits around 3 lines nicely
                    .disabled(true) // Disable manual scroll to behave like a HUD display
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white, location: 0.25),
                                .init(color: .white, location: 0.75),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .onChange(of: currentIndex) { _, newIndex in
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(currentIndex, anchor: .center)
                    }
                }
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.02), lineWidth: 0.5)
                )
            }
        }
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

// MARK: - Lyric Line Struct

struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}

// MARK: - Closed Island Marquee Text View

struct ClosedIslandMarqueeText: View {
    let text: String
    let containerWidth: CGFloat
    
    @State private var offset: CGFloat = 0
    
    var body: some View {
        let textWidth = CGFloat(text.count) * 9.5 // 9.5pt per character at font size 9
        let isTooLong = textWidth > containerWidth
        let scrollDistance = textWidth - containerWidth + 8
        
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
            .offset(x: isTooLong ? offset : 0)
            .frame(width: isTooLong ? textWidth : nil, alignment: .trailing)
            .task(id: text) {
                offset = 0
                guard isTooLong else { return }
                
                // 停留 1.0 秒让用户看清开头
                do {
                    try await Task.sleep(for: .seconds(1.0))
                } catch {
                    return // 如果在此期间歌词变了，任务取消，直接返回
                }
                
                // 平滑滚动
                withAnimation(.linear(duration: Double(scrollDistance) / 18.0).repeatForever(autoreverses: true)) {
                    offset = -scrollDistance
                }
            }
    }
}
