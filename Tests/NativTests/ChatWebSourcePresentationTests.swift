import XCTest

final class ChatWebSourcePresentationTests: XCTestCase {
    func testReadActivityShowsRequestedURLsBeforeResultsArrive() throws {
        let message = ChatTranscriptMessage(
            role: .tool,
            content: "",
            toolName: ChatWebReadToolRegistry.toolName,
            toolStatus: .running,
            toolArguments: #"{"urls":["https://example.com/one","https://nativ.dev/two"],"focus":"release date"}"#
        )

        let activity = try XCTUnwrap(ChatWebSourcePresentation.activity(for: message))

        XCTAssertEqual(activity.focus, "release date")
        XCTAssertEqual(activity.sources.map(\.host), ["example.com", "nativ.dev"])
        XCTAssertEqual(activity.sources.first?.faviconURL?.absoluteString, "https://example.com/favicon.ico")
    }

    func testSearchActivityUsesResultMetadataWithoutUnsafeURLs() throws {
        let message = ChatTranscriptMessage(
            role: .tool,
            content: #"{"results":[{"title":"Nativ","url":"https://nativ.dev/docs#start","snippet":"Local AI"},{"title":"Private","url":"http://127.0.0.1/private","snippet":"No"}]}"#,
            toolName: ChatWebSearchToolRegistry.toolName,
            toolStatus: .succeeded,
            toolArguments: #"{"query":"Nativ docs"}"#
        )

        let activity = try XCTUnwrap(ChatWebSourcePresentation.activity(for: message))

        XCTAssertEqual(activity.query, "Nativ docs")
        XCTAssertEqual(activity.sources.map(\.url.absoluteString), ["https://nativ.dev/docs"])
        XCTAssertEqual(activity.sources.first?.label, "Nativ")
        XCTAssertEqual(activity.sources.first?.snippet, "Local AI")
    }
}
