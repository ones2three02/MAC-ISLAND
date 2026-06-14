import SwiftUI
import OpenIslandCore
import Observation

struct AppMessage: Identifiable, Equatable, Sendable {
    let id: UUID
    let sender: String
    let content: String
    let timestamp: Date
    let app: MessageAppType
    var isUnread: Bool

    enum MessageAppType: String, CaseIterable, Codable, Sendable {
        case wechat = "wechat"
        case lark = "lark"
        case slack = "slack"
        case system = "system"

        var displayName: String {
            switch self {
            case .wechat: return "微信"
            case .lark: return "飞书"
            case .slack: return "Slack"
            case .system: return "系统消息"
            }
        }

        var iconName: String {
            switch self {
            case .wechat: return "message.fill"
            case .lark: return "message.and.waveform.fill"
            case .slack: return "bubble.left.and.bubble.right.fill"
            case .system: return "bell.fill"
            }
        }

        var brandColor: Color {
            switch self {
            case .wechat: return Color(red: 9/255, green: 187/255, blue: 7/255) // 微信绿
            case .lark: return Color(red: 45/255, green: 120/255, blue: 255/255) // 飞书蓝
            case .slack: return Color(red: 74/255, green: 21/255, blue: 75/255) // Slack紫
            case .system: return Color.orange
            }
        }
    }
}

@MainActor
@Observable
final class MessageModule: IslandModule {
    let id = "message_center"

    var messages: [AppMessage] = []
    private var systemNotificationObserver: SystemNotificationObserver?
    
    // 跟踪系统的辅助功能权限信任状态
    var isAccessibilityTrusted: Bool = AXIsProcessTrusted()

    init() {
        // 提供初始的示例消息，展示排版效果与 Vibe 质感
        let isChinese = Locale.current.identifier.hasPrefix("zh")
        messages = [
            AppMessage(
                id: UUID(),
                sender: isChinese ? "产品经理" : "Product Manager",
                content: isChinese ? "刚才发在飞书的方案，看下是否有问题？" : "Please review the PR and specification doc.",
                timestamp: Date().addingTimeInterval(-120),
                app: .lark,
                isUnread: true
            ),
            AppMessage(
                id: UUID(),
                sender: isChinese ? "微信好友" : "WeChat Friend",
                content: isChinese ? "晚上一起干饭不？" : "Do you want to grab dinner tonight?",
                timestamp: Date().addingTimeInterval(-60),
                app: .wechat,
                isUnread: true
            )
        ]
        
        // 初始化时立刻启动系统通知的 Accessibility 监听器
        startSystemNotificationObserver()
    }

    var priority: IslandModulePriority {
        let unreadCount = messages.filter(\.isUnread).count
        if unreadCount > 0 {
            return .medium
        } else {
            return .low
        }
    }

    func leftPillView() -> AnyView {
        let unreads = messages.filter(\.isUnread)
        guard let firstUnread = unreads.first else {
            return AnyView(
                Image(systemName: "message")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.white.opacity(0.6))
            )
        }
        return AnyView(
            Image(systemName: firstUnread.app.iconName)
                .font(.system(size: 9))
                .foregroundStyle(firstUnread.app.brandColor)
        )
    }

    func rightPillView() -> AnyView {
        let unreadCount = messages.filter(\.isUnread).count
        if unreadCount > 0 {
            return AnyView(
                HStack(spacing: 2) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 4, height: 4)
                    Text("\(unreadCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.red)
                }
            )
        } else {
            return AnyView(EmptyView())
        }
    }

    func expandedView() -> AnyView {
        AnyView(
            MessageExpandedView(module: self)
        )
    }

    func onActivate() {
        // 展开面板时刷新一次辅助功能权限状态
        isAccessibilityTrusted = AXIsProcessTrusted()
    }

    func onDeactivate() {
        // 保留消息和后台监听，使用户不会漏掉消息
    }

    func addMessage(sender: String, content: String, app: AppMessage.MessageAppType) {
        let newMessage = AppMessage(
            id: UUID(),
            sender: sender,
            content: content,
            timestamp: Date(),
            app: app,
            isUnread: true
        )
        messages.insert(newMessage, at: 0)
        
        // 触发声音及全局灵动岛调度更新
        NSSound.beep()
    }

    func markAsRead(id: UUID) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].isUnread = false
        }
    }

    func markAllAsRead() {
        for index in messages.indices {
            messages[index].isUnread = false
        }
    }

    func deleteMessage(id: UUID) {
        messages.removeAll(where: { $0.id == id })
    }

    func clearAllMessages() {
        messages.removeAll()
    }
    
    private func startSystemNotificationObserver() {
        guard systemNotificationObserver == nil else { return }
        let observer = SystemNotificationObserver { [weak self] sender, content, app in
            Task { @MainActor in
                self?.addMessage(sender: sender, content: content, app: app)
            }
        }
        observer.start()
        self.systemNotificationObserver = observer
    }
    
    func stopSystemNotificationObserver() {
        systemNotificationObserver?.stop()
        systemNotificationObserver = nil
    }
}
