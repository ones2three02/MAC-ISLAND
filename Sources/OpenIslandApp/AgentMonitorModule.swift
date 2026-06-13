import SwiftUI
import OpenIslandCore

@MainActor
class AgentMonitorModule: IslandModule {
    let id = "agent_monitor"
    
    private let model: AppModel
    
    init(model: AppModel) {
        self.model = model
    }
    
    var priority: IslandModulePriority {
        let sessions = model.sessions
        if sessions.isEmpty {
            return .low
        }
        
        // 检查是否有需要用户干预的会话（等待审批或回答，或者 CPU 占用过高）
        let needsApproval = sessions.contains { session in
            let isWaiting = session.phase == SessionPhase.waitingForApproval || session.phase == SessionPhase.waitingForAnswer
            let isCpuSpike = (session.cpuUsage ?? 0.0) >= 90.0
            return isWaiting || isCpuSpike
        }
        if needsApproval {
            return .critical
        }
        
        // 检查是否有正在运行的会话
        let isRunning = sessions.contains { $0.phase == SessionPhase.running }
        if isRunning {
            return .high
        }
        
        return .low
    }
    
    func leftPillView() -> AnyView {
        AnyView(
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 90/255, green: 154/255, blue: 255/255), // 智能深蓝/浅蓝
                            Color(red: 255/255, green: 180/255, blue: 100/255)  // 暖橙/星光色
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 24, height: 24)
        )
    }
    
    func rightPillView() -> AnyView {
        // 获取原有的右侧插槽内容并进行渲染
        if let content = model.islandClosedRightSlotContent() {
            return AnyView(
                V6RightSlotView(content: content)
            )
        } else {
            return AnyView(EmptyView())
        }
    }
    
    func expandedView() -> AnyView {
        // 这里只是为了满足接口，后续我们直接在 IslandPanelView 中调用原本的视图树
        // 或者是把原本的 Session 列表视图包装过来
        AnyView(
            V8IslandSessionListView(model: model)
        )
    }
    
    func onActivate() {
        // 激活时可以做一些逻辑
    }
    
    func onDeactivate() {
        // 停用时可以做一些逻辑
    }
}

/// 包装原有的 V8 Session 列表视图
struct V8IslandSessionListView: View {
    var model: AppModel
    
    var body: some View {
        // 这里可以直接把原 IslandPanelView 里渲染 SessionList 的部分拿过来
        // 目前为了解耦，我们将让 IslandPanelView 中如果 activeModule 是 AgentMonitorModule 时就展示原有的视图。
        // 为了方便，我们在 IslandPanelView 里直接写视图。
        Text("Agent Session List")
            .foregroundStyle(.white)
    }
}
