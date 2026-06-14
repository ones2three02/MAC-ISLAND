import SwiftUI
import OpenIslandCore
import Observation

/// 灵动岛模块的显示优先级
enum IslandModulePriority: Int, Comparable, CaseIterable {
    /// 默认底色，媒体播放、系统资源监控等
    case low = 0
    /// 计时器、番茄钟、日常通知
    case medium = 1
    /// 活跃的 AI Agent 任务
    case high = 2
    /// AI 权限审批、严重警告（如 CPU 熔断报警）
    case critical = 3
    
    static func < (lhs: IslandModulePriority, rhs: IslandModulePriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 灵动岛模块化协议
@MainActor
protocol IslandModule: AnyObject {
    /// 模块的唯一 ID
    var id: String { get }
    
    /// 模块的当前显示优先级
    var priority: IslandModulePriority { get }
    
    /// 折叠状态下在 Notch 左侧展示的视图
    func leftPillView() -> AnyView
    
    /// 折叠状态下在 Notch 左侧展示的视图宽度，默认为 24
    var leftPillWidth: CGFloat { get }
    
    /// 折叠状态下在 Notch 右侧展示的视图
    func rightPillView() -> AnyView
    
    /// 折叠状态下在 Notch 右侧展示的视图宽度，默认为 0
    var rightPillWidth: CGFloat { get }
    
    /// 展开状态下展示的完整内容卡片
    func expandedView() -> AnyView
    
    /// 模块被激活时调用
    func onActivate()
    
    /// 模块失去焦点或隐藏时调用
    func onDeactivate()
}

extension IslandModule {
    var leftPillWidth: CGFloat { 24 }
    var rightPillWidth: CGFloat { 0 }
}

private func debugLog(_ message: String) {
    let callStack = Thread.callStackSymbols.prefix(12).joined(separator: "\n    ")
    let logMessage = "[\(Date())] [Scheduler] \(message)\n  CallStack:\n    \(callStack)\n"
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

/// 灵动岛模块调度器，负责决策当前应该渲染哪个模块
@MainActor
@Observable
class IslandScheduler {
    var userLockedModuleId: String? = nil {
        didSet {
            debugLog("userLockedModuleId changed from \(String(describing: oldValue)) to \(String(describing: userLockedModuleId))")
        }
    }

    @ObservationIgnored
    var onActiveModuleChanged: (() -> Void)? = nil

    var activeModule: (any IslandModule)? = nil {
        willSet {
            if activeModule?.id != newValue?.id {
                activeModule?.onDeactivate()
            }
        }
        didSet {
            if activeModule?.id != oldValue?.id {
                debugLog("activeModule changed from \(oldValue?.id ?? "nil") to \(activeModule?.id ?? "nil")")
                activeModule?.onActivate()
                onActiveModuleChanged?()
            }
        }
    }
    
    @ObservationIgnored private var modules: [any IslandModule] = []
    
    init() {}
    
    /// 注册一个灵动岛模块
    func registerModule(_ module: any IslandModule) {
        if !modules.contains(where: { $0.id == module.id }) {
            modules.append(module)
            updateActiveModule()
        }
    }
    
    /// 注销一个模块
    func unregisterModule(id: String) {
        modules.removeAll(where: { $0.id == id })
        updateActiveModule()
    }
    
    /// 手动请求更新当前活跃的模块
    func updateActiveModule() {
        // 寻找优先级最高，且非零激活状态的模块
        let candidate = modules
            .filter { $0.priority > .low || (activeModule == nil && $0.priority == .low) || $0.id == activeModule?.id }
            .max(by: { $0.priority < $1.priority })
        
        var target = candidate ?? modules.first
        let targetBeforeLock = target?.id
        
        // 如果当前有用户锁定的模块，且最高候选模块的优先级尚未达到 .high (日常普通状态)
        if let lockedId = userLockedModuleId,
           let lockedModule = modules.first(where: { $0.id == lockedId }),
           let highestPriority = target?.priority,
           highestPriority < .high {
            target = lockedModule
        }
        
        debugLog("updateActiveModule: modules=\(modules.map { "\($0.id)(\($0.priority.rawValue))" }.joined(separator: ", ")), candidate=\(candidate?.id ?? "nil"), userLockedModuleId=\(userLockedModuleId ?? "nil"), targetBeforeLock=\(targetBeforeLock ?? "nil"), finalTarget=\(target?.id ?? "nil")")
        
        if target?.id != activeModule?.id {
            activeModule = target
        }
    }
    
    /// 获取注册的所有模块
    func getModules() -> [any IslandModule] {
        return modules
    }
}
