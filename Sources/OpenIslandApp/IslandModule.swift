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

/// 灵动岛模块调度器，负责决策当前应该渲染哪个模块
@MainActor
@Observable
class IslandScheduler {
    var userLockedModuleId: String? = nil
    var isOpened: Bool = false
    var lastOpenedActiveModuleId: String = "agent_monitor"

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
                activeModule?.onActivate()
                onActiveModuleChanged?()
                
                if isOpened, let newId = activeModule?.id {
                    lastOpenedActiveModuleId = newId
                }
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
        if isOpened {
            // 展开状态下的活跃模块选择逻辑：
            // 优先选择 userLockedModuleId，如果为 nil，则选择 lastOpenedActiveModuleId 对应的模块
            let targetId = userLockedModuleId ?? lastOpenedActiveModuleId
            if let targetModule = modules.first(where: { $0.id == targetId }) {
                if targetModule.id != activeModule?.id {
                    activeModule = targetModule
                }
            } else {
                let candidate = modules
                    .filter { $0.priority > .low || (activeModule == nil && $0.priority == .low) || $0.id == activeModule?.id }
                    .max(by: { $0.priority < $1.priority })
                let target = candidate ?? modules.first
                if target?.id != activeModule?.id {
                    activeModule = target
                }
            }
        } else {
            // 折叠状态下的活跃模块选择逻辑：
            // 如果有用户锁定的模块，直接使用它
            if let lockedId = userLockedModuleId,
               let lockedModule = modules.first(where: { $0.id == lockedId }) {
                if activeModule?.id != lockedId {
                    activeModule = lockedModule
                }
            } else {
                // 如果没有手动锁定，当在播歌且开启了歌词，自动切换至音乐模块
                let mediaModule = modules.first(where: { $0.id == "media_control" }) as? MediaControlModule
                let showLyrics = UserDefaults.standard.bool(forKey: "showLyricsOnClosedIsland")
                if let media = mediaModule, media.isPlaying, showLyrics {
                    if activeModule?.id != "media_control" {
                        activeModule = media
                    }
                } else {
                    let candidate = modules
                        .filter { $0.priority > .low || (activeModule == nil && $0.priority == .low) || $0.id == activeModule?.id }
                        .max(by: { $0.priority < $1.priority })
                    let target = candidate ?? modules.first
                    if target?.id != activeModule?.id {
                        activeModule = target
                    }
                }
            }
        }
    }
    
    /// 获取注册的所有模块
    func getModules() -> [any IslandModule] {
        return modules
    }
}
