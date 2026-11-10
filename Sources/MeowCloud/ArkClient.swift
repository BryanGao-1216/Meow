import Foundation

/// The Agent Plan URL and credentials are distinct from the pay-as-you-go API.
public struct ArkConfiguration: Sendable {
    public static let agentPlanBaseURL = "https://ark.cn-beijing.volces.com/api/plan/v3"
    public static let defaultModel = "ark-code-latest"

    public let baseURL: String
    public let model: String
    public let apiKey: String

    public init(baseURL: String, model: String, apiKey: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func endpoint() throws -> URL {
        guard !apiKey.isEmpty else { throw ArkError.missingKey }
        guard !model.isEmpty else { throw ArkError.missingModel }
        guard let url = URL(string: baseURL), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { throw ArkError.invalidURL }
        if url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).hasSuffix("chat/completions") {
            return url
        }
        return url.appendingPathComponent("chat/completions")
    }
}

public struct ArkMessage: Codable, Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

public enum ArkError: LocalizedError {
    case missingKey, missingModel, invalidURL, invalidResponse, emptyResponse, interruptedStream
    case service(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "请填写 API Key。"
        case .missingModel: return "请填写模型名称。"
        case .invalidURL: return "请填写 HTTPS 接口地址，不要包含查询参数或片段标记。"
        case .invalidResponse: return "服务端返回了无法识别的对话响应。"
        case .emptyResponse: return "模型没有返回正文，请检查模型名称和深度思考设置。"
        case .interruptedStream: return "连接在回复完成前中断了，请重试。"
        case .service(let status, let message): return "HTTP \(status): \(message)"
        }
    }
}

/// An SSE chunk may contain role/usage/reasoning only. Only `content` is speech.
struct ArkChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String? }
        let delta: Delta?
        let message: Delta?
        let finish_reason: String?
    }
    struct ServiceError: Decodable { let message: String?; let code: String? }
    let choices: [Choice]?
    let error: ServiceError?
}

public struct ArkClient: Sendable {
    private let configuration: ArkConfiguration
    private let session: URLSession?

    public init(configuration: ArkConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.session = session
    }

    func request(messages: [ArkMessage], thinking: Bool, maxTokens: Int) throws -> URLRequest {
        var request = URLRequest(url: try configuration.endpoint())
        request.httpMethod = "POST"
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Leave sampling parameters to the selected model: some Plan models only
        // accept their default temperature. No local ChatML/assistant prefill here.
        let body: [String: Any] = [
            "model": configuration.model,
            "messages": try messages.map { message -> [String: String] in
                guard ["system", "user", "assistant"].contains(message.role) else {
                    throw ArkError.invalidResponse
                }
                return ["role": message.role, "content": message.content]
            },
            "stream": true,
            "max_tokens": maxTokens,
            "thinking": ["type": thinking ? "enabled" : "disabled"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Returns accumulated answer text, with reasoning fields ignored. Each
    /// callback gets the accumulated answer so UI consumers can replace a retry.
    public func generate(
        messages: [ArkMessage], thinking: Bool, maxTokens: Int,
        maxCharacters: Int = 560,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        let request = try request(messages: messages, thinking: thinking, maxTokens: maxTokens)
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 60
        settings.timeoutIntervalForResource = 180
        let connection = session ?? URLSession(configuration: settings)
        // Also closes the HTTP stream when the pet-sized answer limit is reached.
        defer { if session == nil { connection.invalidateAndCancel() } }
        let (bytes, response) = try await connection.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw ArkError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 8192 { break }
            }
            throw serviceError(data: data, status: http.statusCode)
        }

        let decoder = JSONDecoder()
        // Accept a normal Chat response too if a compatible gateway ignores stream.
        if http.mimeType == "application/json" {
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                data.append(byte)
                if data.count > 1_048_576 { throw ArkError.invalidResponse }
            }
            let chunk = try decoder.decode(ArkChunk.self, from: data)
            if chunk.error != nil { throw serviceError(data: data, status: http.statusCode) }
            guard let content = chunk.choices?.first?.message?.content,
                  !Self.answerOnly(content).isEmpty else { throw ArkError.emptyResponse }
            let answer = String(Self.answerOnly(content).prefix(maxCharacters))
            await onText(answer)
            return answer
        }

        var answer = ""
        var finished = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" { finished = true; break }
            guard !payload.isEmpty else { continue }
            let data = Data(payload.utf8)
            guard let chunk = try? decoder.decode(ArkChunk.self, from: data) else {
                throw ArkError.invalidResponse
            }
            if chunk.error != nil { throw serviceError(data: data, status: http.statusCode) }
            guard let choice = chunk.choices?.first else { continue }
            if let content = choice.delta?.content {
                answer += content
                let visible = Self.answerOnly(answer)
                if !visible.isEmpty { await onText(String(visible.prefix(maxCharacters))) }
                if visible.count >= maxCharacters { finished = true; break }
                // Don't let an inline, unclosed thinking block grow indefinitely.
                if answer.count > 32_768 { throw ArkError.emptyResponse }
            }
            if choice.finish_reason != nil { finished = true }
        }
        try Task.checkCancellation()
        guard finished else { throw ArkError.interruptedStream }
        guard !Self.answerOnly(answer).isEmpty else { throw ArkError.emptyResponse }
        return String(Self.answerOnly(answer).prefix(maxCharacters))
    }

    static func answerOnly(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let closing = text.range(of: "</think>") {
            return String(text[closing.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.isEmpty || "<think>".hasPrefix(text) || text.contains("<think>") { return "" }
        return text
    }

    private func serviceError(data: Data, status: Int) -> ArkError {
        let chunk = try? JSONDecoder().decode(ArkChunk.self, from: data)
        let message = chunk?.error?.message ?? chunk?.error?.code
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        // Never include the raw response/request, which could contain credentials.
        let redacted = message.replacingOccurrences(of: configuration.apiKey, with: "[redacted]")
        return .service(status: status, message: String(redacted.prefix(400)))
    }
}
