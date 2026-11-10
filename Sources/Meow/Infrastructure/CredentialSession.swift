import Foundation

/// 同一次运行共享一次凭据读取；失败也缓存，只有明确重试才再次请求授权。
@MainActor
final class CredentialSession<Value: Equatable> {
    private let read: () throws -> Value
    private let write: (Value) throws -> Void
    private var cached: Result<Value, Error>?
    private var isReading = false

    enum AccessError: LocalizedError {
        case awaitingAuthorization
        var errorDescription: String? { "正在等待钥匙串授权，请先完成已有的授权对话框。" }
    }

    init(read: @escaping () throws -> Value, write: @escaping (Value) throws -> Void) {
        self.read = read; self.write = write
    }

    func load(retry: Bool = false) throws -> Value {
        guard !isReading else { throw AccessError.awaitingAuthorization }
        if retry { cached = nil }
        if let cached { return try cached.get() }
        isReading = true
        defer { isReading = false }
        let result = Result { try read() }
        cached = result
        return try result.get()
    }

    func save(_ value: Value) throws {
        guard !isReading else { throw AccessError.awaitingAuthorization }
        if case .success(let previous)? = cached, previous == value { return }
        try write(value)
        cached = .success(value)
    }
}
