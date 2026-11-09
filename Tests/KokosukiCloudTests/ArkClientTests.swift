import Foundation
import XCTest
@testable import KokosukiCloud

final class ArkClientTests: XCTestCase {
    private let key = "test-key-not-a-real-隐藏内容"

    private func config(baseURL: String = ArkConfiguration.agentPlanBaseURL) -> ArkConfiguration {
        ArkConfiguration(baseURL: baseURL, model: ArkConfiguration.defaultModel, apiKey: key)
    }

    func testPlanRequestUsesDedicatedEndpointAndMessages() throws {
        let request = try ArkClient(configuration: config()).request(
            messages: [ArkMessage(role: "system", content: "你是一只桌面小猫。"), ArkMessage(role: "user", content: "你好")],
            thinking: false, maxTokens: 256)
        XCTAssertEqual(request.url?.absoluteString, ArkConfiguration.agentPlanBaseURL + "/chat/completions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "ark-code-latest")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertNil(body["temperature"])
        XCTAssertEqual((body["messages"] as? [[String: String]])?.last?["content"], "你好")
    }

    func testEndpointAcceptsTrailingSlashAndFullPath() throws {
        XCTAssertEqual(try config(baseURL: ArkConfiguration.agentPlanBaseURL + "/").endpoint().absoluteString,
                       ArkConfiguration.agentPlanBaseURL + "/chat/completions")
        XCTAssertEqual(try config(baseURL: ArkConfiguration.agentPlanBaseURL + "/chat/completions").endpoint().absoluteString,
                       ArkConfiguration.agentPlanBaseURL + "/chat/completions")
    }

    func testRejectsMissingCredentialsAndInvalidURLs() {
        XCTAssertThrowsError(try ArkConfiguration(baseURL: config().baseURL, model: "m", apiKey: " ").endpoint())
        XCTAssertThrowsError(try ArkConfiguration(baseURL: config().baseURL, model: " ", apiKey: key).endpoint())
        for url in ["http://example.com/v3", "not a URL", "https://key@example.com/v3", "https://example.com/v3?key=隐藏内容"] {
            XCTAssertThrowsError(try config(baseURL: url).endpoint())
        }
    }

    func testStreamIgnoresReasoningRoleAndUsage() async throws {
        let client = mockClient(body: """
        : keepalive
        data: {"choices":[{"delta":{"role":"assistant"}}]}

        data: {"choices":[{"delta":{"reasoning_content":"内部思考内容"}}]}

        data: {"choices":[{"delta":{"content":"[happy] 你好"}}]}

        data: {"choices":[{"delta":{"content":"呀！ [dance]"}}]}

        data: {"choices":[],"usage":{"total_tokens":20}}

        data: [DONE]

        """)
        let received = ReceivedText()
        let answer = try await client.generate(messages: [ArkMessage(role: "user", content: "你好")],
            thinking: true, maxTokens: 512, onText: { await received.append($0) })
        XCTAssertEqual(answer, "[happy] 你好呀！ [dance]")
        let chunks = await received.values
        XCTAssertEqual(chunks.last, answer)
        XCTAssertFalse(chunks.joined().contains("内部思考"))
    }

    func testInlineThinkingIsNotSentToUIUntilItCloses() async throws {
        XCTAssertEqual(ArkClient.answerOnly("<thi"), "")
        XCTAssertEqual(ArkClient.answerOnly("<think>[angry] 隐藏内容"), "")
        XCTAssertEqual(ArkClient.answerOnly("<think>隐藏内容</think>[happy] 你好"), "[happy] 你好")
        let client = mockClient(body: """
        data: {"choices":[{"delta":{"content":"<think>隐藏内容"}}]}
        data: {"choices":[{"delta":{"content":"</think>[happy] 你好"},"finish_reason":"stop"}]}
        data: [DONE]

        """)
        let received = ReceivedText()
        _ = try await client.generate(messages: [], thinking: true, maxTokens: 512,
                                      onText: { await received.append($0) })
        let values = await received.values
        XCTAssertEqual(values, ["[happy] 你好"])
    }

    func testHTTPErrorRedactsCredential() async {
        let client = mockClient(body: "{\"error\":{\"message\":\"Key 无效 \(key)\",\"code\":\"Unauthorized\"}}", status: 401)
        do {
            _ = try await client.generate(messages: [], thinking: false, maxTokens: 16, onText: { _ in })
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("401"))
            XCTAssertFalse(error.localizedDescription.contains(key))
        }
    }

    func testInStreamErrorDoesNotBecomeAReply() async {
        let client = mockClient(body: "data: {\"error\":{\"message\":\"额度已用完\"}}\n\n")
        do {
            _ = try await client.generate(messages: [], thinking: false, maxTokens: 16, onText: { _ in })
            XCTFail("Expected service failure")
        } catch { XCTAssertTrue(error.localizedDescription.contains("额度已用完")) }
    }

    func testInterruptedStreamDoesNotCommitPartialReply() async {
        let client = mockClient(body: "data: {\"choices\":[{\"delta\":{\"content\":\"未完成的回复\"}}]}\n\n")
        do {
            _ = try await client.generate(messages: [], thinking: false, maxTokens: 16, onText: { _ in })
            XCTFail("Expected interrupted stream")
        } catch { XCTAssertTrue(error is ArkError) }
    }

    func testNormalJSONResponse() async throws {
        let client = mockClient(body: "{\"choices\":[{\"message\":{\"content\":\"[happy] 你好\"}}]}", mimeType: "application/json")
        let reply = try await client.generate(messages: [], thinking: false, maxTokens: 16, onText: { _ in })
        XCTAssertEqual(reply, "[happy] 你好")
    }

    func testCancellationStopsRequest() async {
        let client = mockClient(body: "data: [DONE]\n\n")
        let task = Task {
            try Task.checkCancellation()
            return try await client.generate(messages: [], thinking: false, maxTokens: 16, onText: { _ in })
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled) }
    }

    private func mockClient(body: String, status: Int = 200, mimeType: String = "text/event-stream") -> ArkClient {
        let url = "https://\(UUID().uuidString.lowercased()).example.test/v3"
        StubProtocol.register(url: url + "/chat/completions", body: body, status: status, mimeType: mimeType)
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [StubProtocol.self]
        return ArkClient(configuration: config(baseURL: url), session: URLSession(configuration: settings))
    }
}

private actor ReceivedText {
    var values: [String] = []
    func append(_ text: String) { values.append(text) }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Stub { let body: String; let status: Int; let mimeType: String }
    private static let lock = NSLock()
    private static var stubs: [String: Stub] = [:]

    static func register(url: String, body: String, status: Int, mimeType: String) {
        lock.lock()
        defer { lock.unlock() }
        stubs[url] = Stub(body: body, status: status, mimeType: mimeType)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let stub = Self.stubs.removeValue(forKey: request.url!.absoluteString)
        Self.lock.unlock()
        guard let stub else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": stub.mimeType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(stub.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
