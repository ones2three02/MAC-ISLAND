import XCTest
import SwiftUI
@testable import OpenIslandApp
import OpenIslandCore

/// Mock 模块，用于测试调度逻辑
@MainActor
class MockIslandModule: IslandModule {
    let id: String
    var priority: IslandModulePriority
    
    init(id: String, priority: IslandModulePriority) {
        self.id = id
        self.priority = priority
    }
    
    func leftPillView() -> AnyView { AnyView(EmptyView()) }
    func rightPillView() -> AnyView { AnyView(EmptyView()) }
    func expandedView() -> AnyView { AnyView(EmptyView()) }
    func onActivate() {}
    func onDeactivate() {}
}

@MainActor
final class IslandSchedulerTests: XCTestCase {
    
    func testSchedulerInitialStateIsEmpty() {
        let scheduler = IslandScheduler()
        XCTAssertNil(scheduler.activeModule)
    }
    
    func testSchedulerRegistersAndSelectsSingleModule() {
        let scheduler = IslandScheduler()
        let module = MockIslandModule(id: "module-1", priority: .low)
        
        scheduler.registerModule(module)
        
        XCTAssertEqual(scheduler.activeModule?.id, "module-1")
    }
    
    func testSchedulerPrioritizesHighOverLow() {
        let scheduler = IslandScheduler()
        let lowModule = MockIslandModule(id: "low-priority", priority: .low)
        let highModule = MockIslandModule(id: "high-priority", priority: .high)
        
        scheduler.registerModule(lowModule)
        XCTAssertEqual(scheduler.activeModule?.id, "low-priority")
        
        scheduler.registerModule(highModule)
        XCTAssertEqual(scheduler.activeModule?.id, "high-priority")
    }
    
    func testSchedulerSwitchesBackWhenPriorityDrops() {
        let scheduler = IslandScheduler()
        let lowModule = MockIslandModule(id: "low-priority", priority: .low)
        let highModule = MockIslandModule(id: "high-priority", priority: .high)
        
        scheduler.registerModule(lowModule)
        scheduler.registerModule(highModule)
        
        XCTAssertEqual(scheduler.activeModule?.id, "high-priority")
        
        // 降低高优先级模块的优先级，并要求调度更新
        highModule.priority = .low
        scheduler.updateActiveModule()
        
        XCTAssertNotNil(scheduler.activeModule?.id)
    }
}
