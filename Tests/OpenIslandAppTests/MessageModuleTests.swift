import XCTest
import SwiftUI
@testable import OpenIslandApp
import OpenIslandCore

@MainActor
final class MessageModuleTests: XCTestCase {
    
    func testMessageModuleInitialState() {
        let module = MessageModule()
        
        // 初始时有2条引导消息
        XCTAssertEqual(module.messages.count, 2)
        XCTAssertTrue(module.messages[0].isUnread)
        XCTAssertTrue(module.messages[1].isUnread)
        
        // 由于存在未读消息，初始优先级应为 .medium
        XCTAssertEqual(module.priority, .medium)
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
        
        // 优先级依然是 .medium
        XCTAssertEqual(module.priority, .medium)
    }
    
    func testMarkAsRead() {
        let module = MessageModule()
        
        // 全部已读
        module.markAllAsRead()
        XCTAssertEqual(module.messages.filter(\.isUnread).count, 0)
        
        // 当没有未读消息时，优先级降为 .low
        XCTAssertEqual(module.priority, .low)
        
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
