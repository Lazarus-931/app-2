import XCTest
@testable import NativServerKit

final class ChatTranscriptPresentationTests: XCTestCase {
    func testDeepResearchMessagesBecomeOneActivityAndFinalAnswer() throws {
        let context = ChatActivityContext(id: UUID(), kind: .deepResearch)
        let searchCall = call(
            id: "search",
            name: ChatWebSearchToolRegistry.toolName,
            arguments: #"{"query":"Nativ research"}"#
        )
        let readCall = call(
            id: "read",
            name: ChatWebReadToolRegistry.toolName,
            arguments: #"{"urls":["https://nativ.dev/docs"]}"#
        )
        let user = ChatTranscriptMessage(role: .user, content: "Research Nativ")
        let messages = [
            user,
            ChatTranscriptMessage(
                role: .assistant,
                content: "I'll start with the primary source.",
                toolCalls: [searchCall],
                activityContext: context
            ),
            ChatTranscriptMessage(
                role: .tool,
                content: searchResult,
                toolCallID: "search",
                toolName: ChatWebSearchToolRegistry.toolName,
                toolStatus: .succeeded,
                toolArguments: #"{"query":"Nativ research"}"#,
                activityContext: context
            ),
            ChatTranscriptMessage(
                role: .assistant,
                content: "Now I'll read it.",
                toolCalls: [readCall],
                activityContext: context
            ),
            ChatTranscriptMessage(
                role: .tool,
                content: readResult,
                toolCallID: "read",
                toolName: ChatWebReadToolRegistry.toolName,
                toolStatus: .succeeded,
                toolArguments: #"{"urls":["https://nativ.dev/docs"]}"#,
                activityContext: context
            ),
            ChatTranscriptMessage(
                role: .assistant,
                content: "Nativ is documented at https://nativ.dev/docs.",
                activityContext: context
            ),
        ]

        let items = ChatTranscriptPresentation.items(from: messages)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first, .message(user))
        let activity = try researchActivity(in: items)
        XCTAssertEqual(activity.question, "Research Nativ")
        XCTAssertEqual(activity.status, .complete)
        XCTAssertEqual(activity.searchQueries, ["Nativ research"])
        XCTAssertEqual(activity.sources.map(\.host), ["nativ.dev"])
        XCTAssertEqual(activity.pagesRead.map(\.host), ["nativ.dev"])
        XCTAssertEqual(items.last, .message(messages.last!))
    }

    func testOrdinaryWebSearchRemainsAnIndividualMessage() {
        let tool = ChatTranscriptMessage(
            role: .tool,
            content: searchResult,
            toolCallID: "search",
            toolName: ChatWebSearchToolRegistry.toolName,
            toolStatus: .succeeded,
            toolArguments: #"{"query":"Nativ"}"#
        )

        XCTAssertEqual(ChatTranscriptPresentation.items(from: [tool]), [.message(tool)])
    }

    func testReasoningOnlyResearchCompletionIsNotLeftRunning() throws {
        let context = ChatActivityContext(id: UUID(), kind: .deepResearch)
        let final = ChatTranscriptMessage(
            role: .assistant,
            content: "",
            reasoningContent: "Evidence-based conclusion",
            activityContext: context
        )

        let activity = try researchActivity(
            in: ChatTranscriptPresentation.items(from: [final])
        )

        XCTAssertEqual(activity.status, .complete)
        XCTAssertEqual(
            ChatTranscriptPresentation.items(from: [final]),
            [.research(activity), .message(final)]
        )
    }

    func testResearchSourcesAndPageFailuresAreDeduplicated() throws {
        let context = ChatActivityContext(id: UUID(), kind: .deepResearch)
        let search = ChatTranscriptMessage(
            role: .tool,
            content: #"{"results":[{"url":"https://example.com/a"},{"url":"https://example.com/a"}]}"#,
            toolCallID: "search",
            toolName: ChatWebSearchToolRegistry.toolName,
            toolStatus: .succeeded,
            toolArguments: #"{"query":"one"}"#,
            activityContext: context
        )
        let read = ChatTranscriptMessage(
            role: .tool,
            content: #"{"pages":[{"url":"https://example.com/a","title":"A"},{"url":"https://example.com/b","error":{"message":"blocked"}}]}"#,
            toolCallID: "read",
            toolName: ChatWebReadToolRegistry.toolName,
            toolStatus: .succeeded,
            toolArguments: #"{"urls":["https://example.com/a","https://example.com/b"]}"#,
            activityContext: context
        )

        let activity = try researchActivity(
            in: ChatTranscriptPresentation.items(from: [search, read])
        )

        XCTAssertEqual(activity.sources.count, 1)
        XCTAssertEqual(activity.pagesRead.count, 1)
        XCTAssertEqual(activity.errors, ["example.com: blocked"])
    }

    func testConversationExportIncludesToolNameArgumentsAndResult() {
        let tool = ChatTranscriptMessage(
            role: .tool,
            content: searchResult,
            toolCallID: "search",
            toolName: ChatWebSearchToolRegistry.toolName,
            toolStatus: .succeeded,
            toolArguments: #"{"query":"Nativ"}"#
        )
        let now = Date(timeIntervalSince1970: 0)
        let session = ChatSession(
            id: UUID(),
            title: "Research",
            createdAt: now,
            updatedAt: now,
            messages: [tool]
        )

        let export = ChatConversationExporter.text(for: session)

        XCTAssertTrue(export.contains("Web Search:"))
        XCTAssertTrue(export.contains(#"Arguments: {"query":"Nativ"}"#))
        XCTAssertTrue(export.contains("Result:"))
        XCTAssertTrue(export.contains(searchResult))
        XCTAssertFalse(export.contains("Image generation"))
    }

    private var searchResult: String {
        #"{"results":[{"title":"Docs","url":"https://nativ.dev/docs","snippet":"Source"}]}"#
    }

    private var readResult: String {
        #"{"pages":[{"title":"Docs","url":"https://nativ.dev/docs","content":"Evidence"}]}"#
    }

    private func call(
        id: String,
        name: String,
        arguments: String
    ) -> MLXChatToolCall {
        MLXChatToolCall(
            id: id,
            function: MLXChatFunctionCall(name: name, arguments: arguments)
        )
    }

    private func researchActivity(
        in items: [ChatTranscriptPresentationItem]
    ) throws -> ChatResearchActivity {
        try XCTUnwrap(items.compactMap { item in
            guard case .research(let activity) = item else { return nil }
            return activity
        }.first)
    }
}
