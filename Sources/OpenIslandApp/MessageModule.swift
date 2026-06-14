import SwiftUI
import OpenIslandCore
import Observation

public struct AppMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sender: String
    public let content: String
    public let timestamp: Date
    public let app: MessageAppType
    public var isUnread: Bool

    public enum MessageAppType: String, CaseIterable, Codable, Sendable {
        case wechat = "wechat"
        case lark = "lark"
        case slack = "slack"
        case system = "system"

        public var displayName: String {
            switch self {
            case .wechat: return "微信"
            case .lark: return "飞书"
            case .slack: return "Slack"
            case .system: return "系统消息"
            }
        }

        public var iconName: String {
            switch self {
            case .wechat: return "message.fill"
            case .lark: return "message.and.waveform.fill"
            case .slack: return "bubble.left.and.bubble.right.fill"
            case .system: return "bell.fill"
            }
        }

        public var brandColor: Color {
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
public final class MessageModule: IslandModule {
    public let id = "message_center"

    public var messages: [AppMessage] = []
    private var webhookServer: MessageWebhookServer?

    public init() {
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
    }

    public var priority: IslandModulePriority {
        let unreadCount = messages.filter(\.isUnread).count
        if unreadCount > 0 {
            return .medium
        } else {
            return .low
        }
    }

    public func leftPillView() -> AnyView {
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

    public func rightPillView() -> AnyView {
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

    public func expandedView() -> AnyView {
        AnyView(
            MessageExpandedView(module: self)
        )
    }

    public func onActivate() {
        startWebhookServer()
    }

    public func onDeactivate() {
        // 保留消息，以便用户随时查看
    }

    public func addMessage(sender: String, content: String, app: AppMessage.MessageAppType) {
        let newMessage = AppMessage(
            id: UUID(),
            sender: sender,
            content: content,
            timestamp: Date(),
            app: app,
            isUnread: true
        )
        messages.insert(newMessage, at: 0)
    }

    public func markAsRead(id: UUID) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].isUnread = false
        }
    }

    public func markAllAsRead() {
        for index in messages.indices {
            messages[index].isUnread = false
        }
    }

    public func deleteMessage(id: UUID) {
        messages.removeAll(where: { $0.id == id })
    }

    public func clearAllMessages() {
        messages.removeAll()
    }

    private func startWebhookServer() {
        guard webhookServer == nil else { return }
        let server = MessageWebhookServer(port: 5012) { [weak self] sender, content, app in
            Task { @MainActor in
                self?.addMessage(sender: sender, content: content, app: app)
            }
        }
        do {
            try server.start()
            self.webhookServer = server
        } catch {
            print("Failed to start Message Webhook Server: \(error)")
        }
    }

    public func stopWebhookServer() {
        webhookServer?.stop()
        webhookServer = nil
    }
}
