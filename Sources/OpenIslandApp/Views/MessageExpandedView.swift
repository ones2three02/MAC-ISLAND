import SwiftUI
import OpenIslandCore

struct MessageExpandedView: View {
    let module: MessageModule
    
    @State private var selectedFilter: FilterType = .all
    @State private var hoverMessageId: UUID? = nil
    
    enum FilterType: String, CaseIterable {
        case all = "全部"
        case wechat = "微信"
        case lark = "飞书"
        case other = "其他"
        
        var displayName: String {
            return self.rawValue
        }
    }
    
    var filteredMessages: [AppMessage] {
        switch selectedFilter {
        case .all:
            return module.messages
        case .wechat:
            return module.messages.filter { $0.app == .wechat }
        case .lark:
            return module.messages.filter { $0.app == .lark }
        case .other:
            return module.messages.filter { $0.app == .slack || $0.app == .system }
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Header
            HStack {
                Text("MESSAGE CENTER")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.4))
                
                Spacer()
                
                let unreadCount = module.messages.filter(\.isUnread).count
                if unreadCount > 0 {
                    Button {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                            module.markAllAsRead()
                        }
                    } label: {
                        Text("全部已读")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    
                    Text("•")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.2))
                }
                
                if !module.messages.isEmpty {
                    Button {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                            module.clearAllMessages()
                        }
                    } label: {
                        Text("清除")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            
            // Filter Tabs
            HStack(spacing: 6) {
                ForEach(FilterType.allCases, id: \.self) { filter in
                    let isSelected = selectedFilter == filter
                    let count = countForFilter(filter)
                    
                    Button {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.8)) {
                            selectedFilter = filter
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter.displayName)
                            if count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 0.5)
                                    .background(isSelected ? Color.white.opacity(0.2) : Color.white.opacity(0.1), in: Capsule())
                            }
                        }
                        .font(.system(size: 9, weight: isSelected ? .bold : .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(isSelected ? .white : .white.opacity(0.45))
                        .background(isSelected ? Color.white.opacity(0.08) : Color.clear, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? Color.white.opacity(0.12) : Color.clear, lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 2)
            
            if !module.isAccessibilityTrusted {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("未授权辅助功能。系统微信/飞书消息将无法在此显示。")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    
                    Spacer(minLength: 0)
                    
                    Button {
                        openAccessibilitySettings()
                    } label: {
                        Text("去授权")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.25), lineWidth: 0.5))
                .padding(.horizontal, 2)
                .padding(.bottom, 2)
            }
            
            // Messages List
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    if filteredMessages.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "message.badge.filled.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white.opacity(0.15))
                            Text("暂无消息通知")
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.25))
                        }
                        .frame(height: 100)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.02))
                        )
                    } else {
                        ForEach(filteredMessages) { msg in
                            MessageRowView(
                                msg: msg,
                                isHovered: hoverMessageId == msg.id,
                                onRead: {
                                    withAnimation {
                                        module.markAsRead(id: msg.id)
                                    }
                                },
                                onDelete: {
                                    withAnimation {
                                        module.deleteMessage(id: msg.id)
                                    }
                                },
                                onOpenApp: {
                                    openTargetApp(for: msg.app)
                                }
                            )
                            .onHover { isHovering in
                                hoverMessageId = isHovering ? msg.id : nil
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 160)
            .scrollBounceBehavior(.basedOnSize)
            .scrollIndicators(.hidden)
            
            Divider()
                .background(Color.white.opacity(0.08))
                .padding(.vertical, 4)
            
            // Webhook Info & Simulator Actions
            VStack(spacing: 6) {
                HStack {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.3))
                    Text("本地 Webhook: http://localhost:5012/api/message")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                    
                    Spacer()
                    
                    Button {
                        copyCurlToClipboard()
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 7))
                            Text("复制 curl")
                        }
                        .font(.system(size: 8))
                        .foregroundStyle(Color.accentColor.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                
                HStack(spacing: 6) {
                    Button {
                        module.addMessage(
                            sender: "微信好友",
                            content: randomWeChatMessage(),
                            app: .wechat
                        )
                    } label: {
                        Label("模拟微信", systemImage: "plus")
                            .font(.system(size: 9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4.5)
                            .background(Color(red: 9/255, green: 187/255, blue: 7/255).opacity(0.15), in: Capsule())
                            .overlay(Capsule().stroke(Color(red: 9/255, green: 187/255, blue: 7/255).opacity(0.3), lineWidth: 0.5))
                            .foregroundStyle(Color(red: 9/255, green: 187/255, blue: 7/255))
                    }
                    .buttonStyle(.plain)
                    
                    Button {
                        module.addMessage(
                            sender: "飞书同事",
                            content: randomLarkMessage(),
                            app: .lark
                        )
                    } label: {
                        Label("模拟飞书", systemImage: "plus")
                            .font(.system(size: 9))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4.5)
                            .background(Color(red: 45/255, green: 120/255, blue: 255/255).opacity(0.15), in: Capsule())
                            .overlay(Capsule().stroke(Color(red: 45/255, green: 120/255, blue: 255/255).opacity(0.3), lineWidth: 0.5))
                            .foregroundStyle(Color(red: 45/255, green: 120/255, blue: 255/255))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
            .padding(.horizontal, 4)
        }
    }
    
    private func countForFilter(_ filter: FilterType) -> Int {
        switch filter {
        case .all:
            return module.messages.filter(\.isUnread).count
        case .wechat:
            return module.messages.filter { $0.app == .wechat && $0.isUnread }.count
        case .lark:
            return module.messages.filter { $0.app == .lark && $0.isUnread }.count
        case .other:
            return module.messages.filter { ($0.app == .slack || $0.app == .system) && $0.isUnread }.count
        }
    }
    
    private func randomWeChatMessage() -> String {
        let msgs = [
            "晚上吃火锅还是烤肉？🥘",
            "记得把刚才的代码提交一下哦~",
            "OK，收到啦，明天见！",
            "那个 Bug 我定位到了，等下发给你。"
        ]
        return msgs.randomElement() ?? "Hello!"
    }
    
    private func randomLarkMessage() -> String {
        let msgs = [
            "针对今天下午的 PR，我在飞书发了具体的修改意见，查收下。",
            "大家收到请回复下，多谢！",
            "下周一的产品迭代评审会议时间定在下午2点。",
            "麻烦帮我 review 一下刚才的提交："
        ]
        return msgs.randomElement() ?? "Lark message"
    }
    
    private func copyCurlToClipboard() {
        let curlCommand = """
        curl -X POST -H "Content-Type: application/json" -d '{"sender":"王经理","content":"下午3点准时开会","source":"lark"}' http://localhost:5012/api/message
        """
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(curlCommand, forType: .string)
    }
    
    private func openTargetApp(for app: AppMessage.MessageAppType) {
        let bundleID: String
        switch app {
        case .wechat:
            bundleID = "com.tencent.xinWeChat"
        case .lark:
            bundleID = "com.bytedance.feishu" // 尝试国内飞书
        case .slack:
            bundleID = "com.tinyspeck.slackmacgap"
        default:
            return
        }
        
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        } else if app == .lark {
            // 如果是飞书，尝试打开国际版 Lark
            if let larkURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.bytedance.lark") {
                NSWorkspace.shared.openApplication(at: larkURL, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }
    
    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Message Row View

struct MessageRowView: View {
    let msg: AppMessage
    let isHovered: Bool
    let onRead: () -> Void
    let onDelete: () -> Void
    let onOpenApp: () -> Void
    
    var body: some View {
        HStack(spacing: 8) {
            // Unread Indicator line
            if msg.isUnread {
                RoundedRectangle(cornerRadius: 1)
                    .fill(msg.app.brandColor)
                    .frame(width: 3, height: 26)
                    .padding(.leading, -4)
            } else {
                Spacer()
                    .frame(width: 0)
            }
            
            // App Icon Circle
            ZStack {
                Circle()
                    .fill(msg.app.brandColor.opacity(0.12))
                    .frame(width: 26, height: 26)
                
                Image(systemName: msg.app.iconName)
                    .font(.system(size: 11))
                    .foregroundStyle(msg.app.brandColor)
            }
            
            // Text Column
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text(msg.sender)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                    
                    Text(msg.app.displayName)
                        .font(.system(size: 7, weight: .semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 0.5)
                        .background(msg.app.brandColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(msg.app.brandColor)
                    
                    Spacer()
                    
                    Text(formatDate(msg.timestamp))
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.3))
                }
                
                Text(msg.content)
                    .font(.system(size: 9))
                    .foregroundStyle(msg.isUnread ? .white.opacity(0.8) : .white.opacity(0.45))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            
            // Actions Overlay
            if isHovered {
                HStack(spacing: 4) {
                    if msg.isUnread {
                        Button(action: onRead) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.green.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .help("标记已读")
                    }
                    
                    Button(action: onOpenApp) {
                        Image(systemName: "arrow.up.forward.app.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("打开应用回复")
                    
                    Button(action: onDelete) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("删除")
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(msg.isUnread ? Color.white.opacity(0.04) : Color.white.opacity(0.01))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isHovered ? Color.white.opacity(0.1) : Color.white.opacity(0.03), lineWidth: 0.5)
                )
        )
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.8), value: isHovered)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
