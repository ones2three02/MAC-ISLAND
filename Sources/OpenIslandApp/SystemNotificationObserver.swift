import Cocoa
import ApplicationServices
import OpenIslandCore

@MainActor
final class SystemNotificationObserver {
    private var observer: AXObserver?
    private var runLoopSource: CFRunLoopSource?
    private let onMessageCaptured: @MainActor (String, String, AppMessage.MessageAppType) -> Void
    
    // 用来对通知进行短期去重，防止系统横幅在更新/动画时触发重复的捕获
    private var lastCapturedMessage: String = ""
    private var lastCapturedTime: Date = Date.distantPast
    
    init(onMessageCaptured: @escaping @MainActor (String, String, AppMessage.MessageAppType) -> Void) {
        self.onMessageCaptured = onMessageCaptured
    }
    
    func start() {
        stop()
        
        // 1. 检查辅助功能权限，只有在有权限时才能成功创建监听
        guard AXIsProcessTrusted() else {
            print("SystemNotificationObserver: Accessibility permissions not trusted.")
            return
        }
        
        // 2. 查找系统的通知中心 UI 进程
        let apps = NSWorkspace.shared.runningApplications
        guard let notificationCenterApp = apps.first(where: { $0.bundleIdentifier == "com.apple.notificationcenterui" }) else {
            print("SystemNotificationObserver: com.apple.notificationcenterui is not running.")
            return
        }
        
        let pid = notificationCenterApp.processIdentifier
        
        // 3. 创建 AXObserver 监听通知中心
        var obs: AXObserver?
        let status = AXObserverCreate(pid, { (observer, element, notification, refcon) in
            guard let refcon = refcon else { return }
            let this = Unmanaged<SystemNotificationObserver>.fromOpaque(refcon).takeUnretainedValue()
            let elem = element
            let notif = notification
            Task { @MainActor in
                this.handleAXNotification(element: elem, notification: notif)
            }
        }, &obs)
        
        guard status == .success, let observer = obs else {
            print("SystemNotificationObserver: Failed to create observer: \(status.rawValue)")
            return
        }
        
        self.observer = observer
        
        // 4. 监听新通知窗口被创建（当微信/飞书等横幅弹出时，通知中心会创建一个新窗口）
        let appRef = AXUIElementCreateApplication(pid)
        let addStatus = AXObserverAddNotification(
            observer,
            appRef,
            kAXWindowCreatedNotification as CFString,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
        
        guard addStatus == .success else {
            print("SystemNotificationObserver: Failed to add notification listener: \(addStatus.rawValue)")
            return
        }
        
        // 5. 绑定到 RunLoop 以接收系统通知事件
        let rlSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), rlSource, .defaultMode)
        self.runLoopSource = rlSource
        
        print("SystemNotificationObserver: Started monitoring system notifications successfully.")
    }
    
    func stop() {
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
            self.observer = nil
            self.runLoopSource = nil
        }
    }
    
    private func handleAXNotification(element: AXUIElement, notification: CFString) {
        guard (notification as String) == kAXWindowCreatedNotification else { return }
        
        // 异步微量延迟，确保通知横幅渲染完毕文本内容加载完成
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.parseNotificationElement(element)
        }
    }
    
    private func parseNotificationElement(_ element: AXUIElement) {
        var texts: [String] = []
        extractStaticTexts(from: element, into: &texts)
        
        guard !texts.isEmpty else { return }
        
        // 识别来源标识
        var appType: AppMessage.MessageAppType? = nil
        var appIndex: Int = -1
        
        for (index, text) in texts.enumerated() {
            let lower = text.lowercased()
            if lower.contains("微信") || lower.contains("wechat") {
                appType = .wechat
                appIndex = index
                break
            } else if lower.contains("飞书") || lower.contains("feishu") || lower.contains("lark") {
                appType = .lark
                appIndex = index
                break
            } else if lower.contains("slack") {
                appType = .slack
                appIndex = index
                break
            }
        }
        
        guard let detectedApp = appType else { return }
        
        // 剔除包含应用名本身的元素，提取发送者及消息主体
        var remainingTexts = texts
        remainingTexts.remove(at: appIndex)
        
        guard remainingTexts.count >= 2 else {
            if !remainingTexts.isEmpty {
                let content = remainingTexts[0]
                triggerCallback(sender: detectedApp.displayName, content: content, app: detectedApp)
            }
            return
        }
        
        let sender = remainingTexts[0]
        let content = remainingTexts[1]
        
        triggerCallback(sender: sender, content: content, app: detectedApp)
    }
    
    private func triggerCallback(sender: String, content: String, app: AppMessage.MessageAppType) {
        let uniqueKey = "\(app.rawValue):\(sender):\(content)"
        let now = Date()
        
        // 去重机制：如果 1.5 秒内收到完全相同的消息通知，直接丢弃
        if uniqueKey == lastCapturedMessage && now.timeIntervalSince(lastCapturedTime) < 1.5 {
            return
        }
        
        lastCapturedMessage = uniqueKey
        lastCapturedTime = now
        
        onMessageCaptured(sender, content, app)
    }
    
    private func extractStaticTexts(from element: AXUIElement, into texts: inout [String]) {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        
        if let roleStr = role as? String {
            if roleStr == kAXStaticTextRole {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
                if let valStr = value as? String {
                    let clean = valStr.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !clean.isEmpty {
                        texts.append(clean)
                    }
                }
            }
        }
        
        var children: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        if result == .success, let childrenArr = children as? [AXUIElement] {
            for child in childrenArr {
                extractStaticTexts(from: child, into: &texts)
            }
        }
    }
}
