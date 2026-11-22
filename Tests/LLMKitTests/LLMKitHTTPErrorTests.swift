import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import LLMKit

/// One cell of the table of plan section 5.5 (or of xAI's status mapping in section 5.4.3): a response and the error
/// it must become.
struct HTTPErrorCase: Sendable, CustomTestStringConvertible {
    let provider: ProviderID
    let status: Int
    let body: String
    var headers: [String: String] = [:]
    let kind: ErrorKind
    var retryAfter: Double? = nil
    var serverStatus: Int? = nil

    var testDescription: String {
        "\(provider) \(status) \(body.prefix(60)) → \(kind.rawValue)"
    }

    static func anthropic(_ kind: ErrorKind, _ status: Int, _ type: String, _ message: String = "message", headers: [String: String] = [:],
                          retryAfter: Double? = nil, server: Int? = nil) -> HTTPErrorCase {
        HTTPErrorCase(provider: "anthropic-api", status: status,
                      body: #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"},"request_id":"req_1"}"#,
                      headers: headers, kind: kind, retryAfter: retryAfter, serverStatus: server)
    }

    static func openAI(_ kind: ErrorKind, _ status: Int, code: String?, _ message: String = "message", headers: [String: String] = [:],
                       retryAfter: Double? = nil, server: Int? = nil) -> HTTPErrorCase {
        let codeJSON = code.map { "\"\($0)\"" } ?? "null"
        return HTTPErrorCase(provider: "openai-api", status: status,
                             body: #"{"error":{"message":"\#(message)","type":"invalid_request_error","param":null,"code":\#(codeJSON)}}"#,
                             headers: headers, kind: kind, retryAfter: retryAfter, serverStatus: server)
    }

    static func gemini(_ kind: ErrorKind, _ status: Int, code: String, _ message: String = "message", headers: [String: String] = [:],
                       retryAfter: Double? = nil, server: Int? = nil) -> HTTPErrorCase {
        HTTPErrorCase(provider: "gemini-api", status: status, body: #"{"error":{"code":"\#(code)","message":"\#(message)"}}"#,
                      headers: headers, kind: kind, retryAfter: retryAfter, serverStatus: server)
    }

    static func ollama(_ kind: ErrorKind, _ status: Int, _ message: String, server: Int? = nil) -> HTTPErrorCase {
        HTTPErrorCase(provider: "ollama", status: status, body: #"{"error":"\#(message)"}"#, kind: kind, serverStatus: server)
    }

    static func xAI(_ kind: ErrorKind, _ status: Int, _ body: String, headers: [String: String] = [:], retryAfter: Double? = nil,
                    server: Int? = nil) -> HTTPErrorCase {
        HTTPErrorCase(provider: "xai-api", status: status, body: body, headers: headers, kind: kind, retryAfter: retryAfter, serverStatus: server)
    }

    /// Every cell, row by row.
    static let all: [HTTPErrorCase] = anthropicCells + openAICells + geminiCells + ollamaCells + xAICells

    static let anthropicCells: [HTTPErrorCase] = [
        .anthropic(.auth, 401, "authentication_error", "invalid x-api-key"),
        .anthropic(.auth, 403, "permission_error"),
        .anthropic(.rateLimited, 429, "rate_limit_error", headers: ["retry-after": "7"], retryAfter: 7),
        .anthropic(.rateLimited, 429, "rate_limit_error"),
        .anthropic(.quotaExhausted, 402, "billing_error"),
        .anthropic(.quotaExhausted, 400, "invalid_request_error", "This request would exceed your organization's spend limit."),
        .anthropic(.overloaded, 529, "overloaded_error", "Overloaded"),
        .anthropic(.overloaded, 529, "overloaded_error", "Overloaded", headers: ["Retry-After": "3"], retryAfter: 3),
        .anthropic(.contextTooLong, 413, "request_too_large", "Request exceeds the maximum allowed number of bytes."),
        .anthropic(.contextTooLong, 400, "invalid_request_error", "prompt is too long: 250000 tokens > 200000 maximum"),
        .anthropic(.contextTooLong, 400, "invalid_request_error", "The PDF is too large."),
        .anthropic(.contextTooLong, 400, "invalid_request_error", "input length exceeds the context window"),
        .anthropic(.contextTooLong, 400, "invalid_request_error", "max_tokens: 99999 > 64000, the maximum allowed number of output tokens"),
        .anthropic(.modelNotFound, 404, "not_found_error", "model: nope"),
        .anthropic(.invalidRequest, 400, "invalid_request_error", "messages: roles must alternate"),
        .anthropic(.invalidRequest, 409, "invalid_request_error"),
        .anthropic(.invalidRequest, 422, "invalid_request_error"),
        .anthropic(.server, 500, "api_error", "Internal server error", server: 500),
        .anthropic(.server, 504, "timeout_error", server: 504),
    ]

    static let openAICells: [HTTPErrorCase] = [
        .openAI(.auth, 401, code: "invalid_api_key", "Incorrect API key provided."),
        .openAI(.auth, 403, code: nil, "Project does not have access."),
        .openAI(.rateLimited, 429, code: "rate_limit_exceeded", "Rate limit reached.", headers: ["Retry-After": "2"], retryAfter: 2),
        .openAI(.rateLimited, 429, code: nil),
        .openAI(.quotaExhausted, 429, code: "credit_balance_exhausted"),
        .openAI(.quotaExhausted, 429, code: "insufficient_quota"),
        .openAI(.quotaExhausted, 429, code: "monthly_spend_limit_exceeded"),
        .openAI(.quotaExhausted, 429, code: "organization_usage_limit_exceeded"),
        .openAI(.overloaded, 503, code: "server_is_overloaded", headers: ["Retry-After": "5"], retryAfter: 5),
        .openAI(.contextTooLong, 400, code: "context_length_exceeded", "This model's maximum context length is 128000 tokens."),
        .openAI(.contextTooLong, 400, code: nil, "Your input exceeds the context window of this model."),
        .openAI(.modelNotFound, 404, code: "model_not_found", "The model does not exist."),
        .openAI(.modelNotFound, 400, code: "model_not_found", "The model does not exist."),
        .openAI(.invalidRequest, 400, code: "invalid_value", "Invalid value for 'input'."),
        .openAI(.invalidRequest, 422, code: nil),
        .openAI(.server, 500, code: "server_error", server: 500),
    ]

    static let geminiCells: [HTTPErrorCase] = [
        .gemini(.auth, 401, code: "authentication"),
        .gemini(.auth, 403, code: "permission_denied"),
        .gemini(.rateLimited, 429, code: "rate_limit_exceeded", headers: ["Retry-After": "4"], retryAfter: 4),
        .gemini(.rateLimited, 429, code: "too_many_requests"),
        .gemini(.quotaExhausted, 402, code: "payment_required"),
        .gemini(.quotaExhausted, 429, code: "quota_exceeded"),
        .gemini(.overloaded, 503, code: "service_unavailable"),
        .gemini(.contextTooLong, 400, code: "invalid_request", "The input token count exceeds the maximum number of tokens allowed."),
        .gemini(.modelNotFound, 404, code: "model_not_found"),
        .gemini(.invalidRequest, 400, code: "invalid_request", "Request contains an invalid argument."),
        .gemini(.invalidRequest, 400, code: "parameter_unknown"),
        .gemini(.invalidRequest, 400, code: "failed_precondition"),
        .gemini(.refused, 400, code: "safety"),
        .gemini(.refused, 400, code: "recitation"),
        .gemini(.refused, 400, code: "prohibited_content"),
        .gemini(.refused, 400, code: "blocklist"),
        .gemini(.refused, 400, code: "spii"),
        .gemini(.refused, 400, code: "content_blocked"),
        .gemini(.refused, 400, code: "language"),
        .gemini(.server, 500, code: "api_error", server: 500),
        .gemini(.server, 504, code: "deadline_exceeded", server: 504),
        .gemini(.server, 409, code: "aborted", server: 409),
        .gemini(.server, 504, code: "gateway_timeout", server: 504),
        .gemini(.server, 400, code: "a_code_nobody_has_seen", server: 400),
    ]

    static let ollamaCells: [HTTPErrorCase] = [
        .ollama(.rateLimited, 429, "too many requests"),
        .ollama(.modelNotFound, 404, "model 'nope' not found"),
        .ollama(.invalidRequest, 400, "invalid options"),
        .ollama(.server, 500, "an error was encountered while running the model", server: 500),
    ]

    static let xAICells: [HTTPErrorCase] = [
        .xAI(.auth, 401, #"{"code":"Client specified an invalid argument","error":"Incorrect API key provided."}"#),
        .xAI(.auth, 403, "Forbidden"),
        .xAI(.rateLimited, 429, #"{"error":"Too many requests"}"#, headers: ["retry-after": "9"], retryAfter: 9),
        .xAI(.modelNotFound, 404, #"{"error":"The model nope does not exist."}"#),
        .xAI(.invalidRequest, 400, #"{"error":"Invalid request content."}"#),
        .xAI(.invalidRequest, 415, "Unsupported Media Type"),
        .xAI(.invalidRequest, 422, #"{"error":"Failed to deserialize the JSON body."}"#),
        .xAI(.contextTooLong, 400, #"{"error":"This model's maximum prompt length is 131072 but the request contains 200000 tokens."}"#),
        .xAI(.contextTooLong, 400, #"{"error":"The context is longer than the model allows."}"#),
        .xAI(.contextTooLong, 422, "Prompt too long"),
        .xAI(.server, 500, "Internal Server Error", server: 500),
        .xAI(.server, 502, "Bad Gateway", server: 502),
        .xAI(.server, 503, #"{"error":"Service temporarily unavailable"}"#, server: 503),
    ]
}

/// WP4 "HTTP errors": one case per cell of the section 5.5 table, `Retry-After`, and xAI's status mapping.
@Suite struct LLMKitHTTPErrorTests {
    @Test(arguments: HTTPErrorCase.all)
    func theResponseBecomesTheErrorOfItsCell(_ cell: HTTPErrorCase) async throws {
        StubURLProtocol.setHandler { _ in Stub.json(cell.body, status: cell.status, headers: cell.headers) }
        let outcome = await collect(Harness().provider(cell.provider).stream(Requests.text(contextWindow: 2_048)))
        let error = try #require(outcome.llmError, "\(String(describing: outcome.error))")
        #expect(ErrorKind(error) == cell.kind, "\(error)")
        #expect(error.retryAfter == cell.retryAfter)
        if let serverStatus = cell.serverStatus { #expect(error.status == serverStatus) }
        #expect(outcome.events.isEmpty)
        #expect(StubURLProtocol.recordedRequests.count == 1)            // with no retry rule: one request
    }

    @Test func theVendorsMessageIsKept() async throws {
        StubURLProtocol.setHandler { _ in Stub.json(AppendixDVariants.anthropicHTTPError, status: 401) }
        let anthropic = await collect(Harness().provider("anthropic-api").stream(Requests.text()))
        #expect(anthropic.llmError == .auth("invalid x-api-key"))

        StubURLProtocol.setHandler { _ in Stub.json(AppendixDVariants.openaiHTTPError, status: 400) }
        let openAI = await collect(Harness().provider("openai-api").stream(Requests.text()))
        #expect(openAI.llmError == .contextTooLong("This model's maximum context length is 128000 tokens."))

        StubURLProtocol.setHandler { _ in Stub.json(AppendixDVariants.geminiHTTPError, status: 400) }
        let gemini = await collect(Harness().provider("gemini-api").stream(Requests.text()))
        #expect(gemini.llmError == .invalidRequest("Request contains an invalid argument."))

        StubURLProtocol.setHandler { _ in StubURLProtocol.Response(status: 502, chunks: []) }
        let empty = await collect(Harness().provider("xai-api").stream(Requests.text()))
        #expect(empty.llmError == .server(status: 502, message: "HTTP 502"))
    }

    @Test func aKeyEchoedInAnErrorIsNotShown() async throws {
        let key = Harness.keys["openai-api"] ?? ""
        StubURLProtocol.setHandler { _ in
            Stub.json(#"{"error":{"message":"Incorrect API key provided: \#(key).","type":"invalid_request_error","code":"invalid_api_key"}}"#,
                      status: 401)
        }
        let outcome = await collect(Harness().provider("openai-api").stream(Requests.text()))
        #expect(outcome.llmError == .auth("Incorrect API key provided: ••••."))
        #expect(!(outcome.llmError?.userMessage.contains(key) ?? true))
    }

    @Test func aHugeErrorBodyIsCutTo64KB() async throws {
        let big = String(repeating: "x", count: 200_000)
        StubURLProtocol.setHandler { _ in StubURLProtocol.Response(status: 500, headers: ["Content-Type": "text/plain"],
                                                                  chunks: [Data(big.utf8)]) }
        let outcome = await collect(Harness().provider("xai-api").stream(Requests.text()))
        guard case .server(500, let message)? = outcome.llmError else {
            Issue.record("expected a server error, got \(String(describing: outcome.error))")
            return
        }
        #expect(message.count <= VendorError.maxMessageCharacters + 1)
        let failure = HTTPFailure(status: 500, body: Data(big.utf8))
        #expect(failure.body.count == 64 * 1024)
    }

    @Test func aRefusedConnectionIsANetworkErrorExceptForOllama() async throws {
        StubURLProtocol.setHandler(nil)                                 // every request: connection refused
        let anthropic = await collect(Harness().provider("anthropic-api").stream(Requests.text()))
        #expect(ErrorKind(anthropic.error) == .network)
        let ollama = await collect(Harness().provider("ollama").stream(Requests.text(contextWindow: 2_048)))
        #expect(ollama.llmError == .notConfigured("Ollama is not running"))
    }

    // ---- Retry-After ----

    @Test func retryAfterIsReadInSecondsOrAsAnHTTPDate() throws {
        #expect(RetryAfter.seconds("7") == 7)
        #expect(RetryAfter.seconds(" 1.5 ") == 1.5)
        #expect(RetryAfter.seconds("0") == 0)
        #expect(RetryAfter.seconds("-4") == 0)
        #expect(RetryAfter.seconds(nil) == nil)
        #expect(RetryAfter.seconds("") == nil)
        #expect(RetryAfter.seconds("soon") == nil)
        #expect(RetryAfter.seconds("inf") == nil)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = try #require(formatter.date(from: "Wed, 21 Oct 2026 07:28:00 GMT"))
        #expect(RetryAfter.seconds("Wed, 21 Oct 2026 07:28:00 GMT", now: date.addingTimeInterval(-30)) == 30)
        #expect(RetryAfter.seconds("Wed, 21 Oct 2026 07:28:00 GMT", now: date.addingTimeInterval(30)) == 0)
        // The header is found whatever its case.
        #expect(HTTPFailure(status: 429, headers: ["RETRY-AFTER": "12"]).retryAfter() == 12)
    }
}
