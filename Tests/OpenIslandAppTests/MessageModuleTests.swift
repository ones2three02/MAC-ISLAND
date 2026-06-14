import XCTest
import SwiftUI
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
final class MessageModuleTests: XCTestCase {
    
    func testMessageModuleInitialState() {
        let module = MessageModule()
        
        // 初始时无消息
        XCTAssertEqual(module.messages.count, 0)
        
        // 由于没有未读消息，初始优先级应为 .low
        XCTAssertEqual(module.priority, .low)
    }
    
    func testAddMessage() {
        let module = MessageModule()
        let initialCount = module.messages.count
        
        module.addMessage(sender: "测试人员", content: "这是一条测试消息", app: .slack)
        
        XCTAssertEqual(module.messages.count, initialCount + 1)
        XCTAssertEqual(module.messages.first?.sender, "测试人员")
        XCTAssertEqual(module.messages.first?.content, "这是一条测试消息")
        XCTAssertEqual(module.messages.first?.app, .slack)
        XCTAssertTrue(module.messages.first?.isUnread ?? false)
        
        // 优先级升级为 .medium
        XCTAssertEqual(module.priority, .medium)
    }
    
    func testMarkAsRead() {
        let module = MessageModule()
        
        // 添加一条未读消息
        module.addMessage(sender: "用户", content: "你好", app: .wechat)
        XCTAssertEqual(module.priority, .medium)
        
        guard let firstMsg = module.messages.first else {
            XCTFail("No messages found")
            return
        }
        
        // 标记该消息为已读
        module.markAsRead(id: firstMsg.id)
        XCTAssertFalse(module.messages.first?.isUnread ?? true)
        XCTAssertEqual(module.priority, .low)
    }
    
    func testDeleteMessage() {
        let module = MessageModule()
        module.clearAllMessages()
        XCTAssertEqual(module.messages.count, 0)
        XCTAssertEqual(module.priority, .low)
        
        module.addMessage(sender: "飞书", content: "开会", app: .lark)
        let msgId = module.messages[0].id
        XCTAssertEqual(module.messages.count, 1)
        
        module.deleteMessage(id: msgId)
        XCTAssertEqual(module.messages.count, 0)
        XCTAssertEqual(module.priority, .low)
    }
}
