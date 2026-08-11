import Foundation
import NativServerKit
import XCTest

private actor StubWebReadHTTPClient: WebBrowsingHTTPClient {
    private let responseData: Data
    private let statusCode: Int
    private var requests: [URLRequest] = []

    init(response: String, statusCode: Int = 200) {
        responseData = Data(response.utf8)
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard let url = request.url else { throw URLError(.badURL) }
        return (
            responseData,
            HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

final class ChatWebReadToolTests: XCTestCase {
    func testProviderReadCapabilitiesAreExplicit() {
        XCTAssertFalse(WebSearchProvider.brave.supports(.read))
        XCTAssertTrue(WebSearchProvider.exa.supports(.read))
        XCTAssertTrue(WebSearchProvider.nimble.supports(.read))
        XCTAssertTrue(WebSearchProvider.firecrawl.supports(.read))
        XCTAssertFalse(WebSearchProvider.perplexity.supports(.read))
    }

    func testExaReadsURLsInOneBoundedBatch() async throws {
        let content = String(repeating: "a", count: 7_000)
        let response = try jsonString([
            "results": [
                ["id": "https://example.com/one", "title": "One", "text": content],
                ["id": "https://example.com/two", "title": "Two", "text": "Second"],
            ],
        ])
        let client = StubWebReadHTTPClient(response: response)

        let pages = try await WebReadService(client: client).read(
            provider: .exa,
            apiKey: "exa-key",
            urls: ["https://example.com/one", "https://example.com/two"]
        )

        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try body(of: request)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://api.exa.ai/contents")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "exa-key")
        XCTAssertEqual(body["urls"] as? [String], ["https://example.com/one", "https://example.com/two"])
        XCTAssertEqual(body["text"] as? Bool, true)
        XCTAssertEqual(pages.map(\.url), ["https://example.com/one", "https://example.com/two"])
        XCTAssertEqual(pages[0].content?.count, 6_000)
        XCTAssertTrue(pages[0].truncated)
        XCTAssertEqual(pages[1].content, "Second")
    }

    func testNimbleRequestsMarkdownFromExtract() async throws {
        let client = StubWebReadHTTPClient(
            response: ##"{"status":"success","data":{"markdown":"# Nimble page"}}"##
        )

        let pages = try await WebReadService(client: client).read(
            provider: .nimble,
            apiKey: "nimble-key",
            urls: ["https://example.com/nimble"]
        )

        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try body(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://sdk.nimbleway.com/v2/extract")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer nimble-key")
        XCTAssertEqual(body["formats"] as? [String], ["markdown"])
        XCTAssertEqual(body["render"] as? String, "auto")
        XCTAssertEqual(pages.first?.content, "# Nimble page")
    }

    func testFirecrawlRequestsOnlyMainMarkdownContent() async throws {
        let client = StubWebReadHTTPClient(
            response: #"{"success":true,"data":{"markdown":"Firecrawl page","metadata":{"title":"Example"}}}"#
        )

        let pages = try await WebReadService(client: client).read(
            provider: .firecrawl,
            apiKey: "firecrawl-key",
            urls: ["https://example.com/firecrawl"]
        )

        let requests = await client.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try body(of: request)
        XCTAssertEqual(request.url?.absoluteString, "https://api.firecrawl.dev/v2/scrape")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer firecrawl-key")
        XCTAssertEqual(body["onlyMainContent"] as? Bool, true)
        XCTAssertEqual(body["removeBase64Images"] as? Bool, true)
        XCTAssertEqual(pages.first?.title, "Example")
        XCTAssertEqual(pages.first?.content, "Firecrawl page")
    }

    func testReadOutputHasAPerPageAndTotalBudget() async throws {
        let content = String(repeating: "x", count: 7_000)
        let results = (1 ... 4).map {
            ["id": "https://example.com/\($0)", "text": content]
        }
        let client = StubWebReadHTTPClient(response: try jsonString(["results": results]))

        let pages = try await WebReadService(client: client).read(
            provider: .exa,
            apiKey: "key",
            urls: (1 ... 4).map { "https://example.com/\($0)" }
        )

        XCTAssertEqual(pages.compactMap(\.content).map(\.count), [5_000, 5_000, 5_000, 5_000])
        XCTAssertEqual(pages.compactMap(\.content).reduce(0) { $0 + $1.count }, 20_000)
        XCTAssertTrue(pages.allSatisfy { $0.truncated })
    }

    func testURLPolicyRejectsPrivateAndCredentialBearingURLs() {
        XCTAssertNil(WebReadURLPolicy.normalizedURL("http://127.0.0.1/private"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("http://127.0.0.1./private"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("http://0x7f.0.0.1/private"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("http://192.168.1.4/private"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("http://[::1]/private"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("https://service.internal/data"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("https://user:secret@example.com"))
        XCTAssertNil(WebReadURLPolicy.normalizedURL("https://example.com?access_token=secret"))
        XCTAssertEqual(
            WebReadURLPolicy.normalizedURL("https://example.com/article#section"),
            "https://example.com/article"
        )
    }

    func testUnsupportedProviderFailsBeforeMakingARequest() async throws {
        let client = StubWebReadHTTPClient(response: "{}")
        do {
            _ = try await WebReadService(client: client).read(
                provider: .brave,
                apiKey: "key",
                urls: ["https://example.com"]
            )
            XCTFail("Expected Brave URL reading to be rejected")
        } catch let error as WebReadError {
            XCTAssertEqual(error.code, "unsupported_provider")
        }
        let requests = await client.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testPageFailureIsReturnedWithoutDiscardingTheBatch() async throws {
        let client = StubWebReadHTTPClient(response: "{}", statusCode: 404)

        let pages = try await WebReadService(client: client).read(
            provider: .firecrawl,
            apiKey: "key",
            urls: ["https://example.com/missing"]
        )

        XCTAssertEqual(pages.count, 1)
        XCTAssertFalse(pages[0].isSuccess)
        XCTAssertEqual(pages[0].error?.code, WebBrowsingFailureCode.requestFailed.rawValue)
    }

    func testToolSchemaStaysCompactAndBounded() throws {
        let parameters = ChatWebReadToolRegistry.definition.function.parameters
        let data = try JSONEncoder().encode(parameters)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let urls = try XCTUnwrap(properties["urls"] as? [String: Any])

        XCTAssertEqual(Set(properties.keys), ["urls"])
        XCTAssertEqual(urls["minItems"] as? Int, 1)
        XCTAssertEqual(urls["maxItems"] as? Int, ChatWebReadToolRegistry.maximumURLs)
        XCTAssertEqual(urls["uniqueItems"] as? Bool, true)
    }

    private func jsonString(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    private func body(of request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
