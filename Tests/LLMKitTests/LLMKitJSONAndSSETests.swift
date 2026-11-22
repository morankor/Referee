import Foundation
import Testing
import RefereeCore
import TestSupport
@testable import LLMKit

/// The small pieces under the adapters: JSON values, the SSE line rule of plan section 5.3, endpoints.
@Suite struct LLMKitJSONAndSSETests {
    @Test func jsonKeepsIntegersBooleansAndDoublesApart() throws {
        let value = try #require(JSONValue.parse(#"{"i":16000,"d":0.2,"b":false,"n":null,"s":"a/b","a":[1,"x",true],"w":90.0}"#))
        #expect(value["i"] == .int(16_000))
        #expect(value["d"] == .double(0.2))
        #expect(value["b"] == .bool(false))
        #expect(value["n"] == .null)
        #expect(value["s"] == .string("a/b"))
        #expect(value["a"] == [1, "x", true])
        #expect(value["w"]?.intValue == 90)
        #expect(value["missing"] == nil)
        let written = String(decoding: try JSONValue.object(["max_tokens": 16_000, "temperature": 0.2, "store": false, "url": "a/b"]).data(),
                             as: UTF8.self)
        #expect(written == #"{"max_tokens":16000,"store":false,"temperature":0.2,"url":"a/b"}"#)
    }

    @Test func mergingOverwritesTopLevelKeysOnly() {
        let body: JSONValue = ["model": "m", "options": ["num_ctx": 2_048, "temperature": 0.2]]
        let merged = body.merging(topLevelKeysOf: ["options": ["seed": 1], "think": false])
        #expect(merged == ["model": "m", "options": ["seed": 1], "think": false])
        #expect(body.merging(topLevelKeysOf: [1, 2]) == body)
        #expect(HTTPRequests.merged(body, extraBodyJSON: "nonsense") == body)
        #expect(HTTPRequests.merged(body, extraBodyJSON: nil) == body)
    }

    @Test func theSSELineRule() throws {
        #expect(SSE.classify(#"data: {"type":"ping"}"#) == .event(["type": "ping"]))
        #expect(SSE.classify(#"data:{"type":"ping"}"#) == .event(["type": "ping"]))          // the space is optional
        #expect(SSE.classify("data: [DONE]") == .done)
        #expect(SSE.classify("data:[DONE]") == .done)
        for ignored in ["event: message_start", "id: 4", ": keep-alive", "", "retry: 3000", "data: not json", "data:", "DATA: {}"] {
            #expect(SSE.classify(ignored) == .ignored, "\(ignored)")
        }
        // The event kind comes from the JSON, never from the event: line.
        let anthropic = AnthropicAdapter()
        var state = StreamState()
        #expect(try anthropic.parse(line: "event: message_stop", state: &state).isEmpty)
        #expect(try anthropic.parse(line: #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"x"}}"#, state: &state)
                == [.textDelta("x")])
    }

    @Test func vendorErrorsAreReadFromEveryShape() {
        #expect(VendorError(body: Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8))
                == VendorError(type: "overloaded_error", message: "Overloaded"))
        #expect(VendorError(body: Data(#"{"error":{"message":"m","type":"t","param":null,"code":"c"}}"#.utf8))
                == VendorError(type: "t", code: "c", message: "m"))
        #expect(VendorError(body: Data(#"{"error":{"code":404,"message":"gone","status":"NOT_FOUND"}}"#.utf8))
                == VendorError(message: "gone"))                    // a numeric code is the HTTP status again
        #expect(VendorError(body: Data(#"{"error":"model 'x' not found"}"#.utf8)) == VendorError(message: "model 'x' not found"))
        #expect(VendorError(body: Data("  Bad Gateway\n".utf8)) == VendorError(message: "Bad Gateway"))
        #expect(VendorError(body: Data()).text(status: 503) == "HTTP 503")
    }

    @Test func endpointsTakeSchemeHostAndPortFromTheBaseURL() throws {
        let url = "https://api.anthropic.com/v1/messages"
        #expect(try Endpoint.resolve(url, override: nil).absoluteString == url)
        #expect(try Endpoint.resolve(url, override: "  ").absoluteString == url)
        #expect(try Endpoint.resolve(url, override: "http://localhost:9000/x/y?z=1").absoluteString == "http://localhost:9000/v1/messages")
        #expect(try Endpoint.resolve(url, override: "proxy.example.invalid").absoluteString == "https://proxy.example.invalid/v1/messages")
        #expect(try Endpoint.resolve(url, override: "http://[::1]:8080").absoluteString == "http://[::1]:8080/v1/messages")
        for bad in ["ftp://host", "http://", "://nothing", "has spaces in it"] {
            #expect(throws: LLMError.self, "\(bad)") { try Endpoint.resolve(url, override: bad) }
        }
        #expect(Endpoint.problem("ftp://host") != nil)
        #expect(Endpoint.problem(nil) == nil)
        #expect(Endpoint.isLoopback("http://127.0.0.1:11434/api/chat", override: nil))
        #expect(!Endpoint.isLoopback("http://127.0.0.1:11434/api/chat", override: "http://10.0.0.2"))
    }
}
