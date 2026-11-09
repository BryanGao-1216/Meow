import Foundation

/// 对话工具只返回已经执行并校验的结果；角色回复由 Brain 统一生成。
@MainActor
protocol ConversationTool: AnyObject {
    func accepts(_ text: String) -> Bool
    func prepare(_ text: String) async -> String
    func resetConversation()
}

@MainActor
final class ConversationToolRouter {
    private let tools: [any ConversationTool]
    init(_ tools: [any ConversationTool]) { self.tools = tools }
    func matching(_ text: String) -> (any ConversationTool)? { tools.first { $0.accepts(text) } }
    func reset() { tools.forEach { $0.resetConversation() } }
}
