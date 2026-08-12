import XCTest
@testable import NativServerKit

final class ChatResearchRunTests: XCTestCase {
    func testActivityContextSurvivesMessageRoundTrip() throws {
        let context = ChatActivityContext(id: UUID(), kind: .deepResearch)
        let message = ChatTranscriptMessage(
            role: .tool,
            content: #"{"results":[]}"#,
            toolName: ChatWebSearchToolRegistry.toolName,
            toolStatus: .succeeded,
            toolArguments: #"{"query":"Nativ"}"#,
            activityContext: context
        )

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatTranscriptMessage.self, from: data)

        XCTAssertEqual(decoded.activityContext, context)
    }

    func testSuccessfulDuplicateCallUsesCachedResult() throws {
        var controller = ChatResearchRunController()
        let original = call(arguments: #"{"count":5,"query":"Nativ"}"#)
        let equivalent = call(arguments: #"{"query":"Nativ","count":5}"#)
        let result = searchResult("https://nativ.dev")

        XCTAssertNil(controller.record([
            observation(call: original, content: result),
        ]))
        let cached = try XCTUnwrap(controller.cachedResults(for: [equivalent]))

        XCTAssertEqual(cached.map(\.content), [result])
    }

    func testTwoSearchRoundsWithoutNewSourcesFinalizeResearch() {
        var controller = ChatResearchRunController()
        let first = call(arguments: #"{"query":"first"}"#)
        let second = call(arguments: #"{"query":"second"}"#)
        let third = call(arguments: #"{"query":"third"}"#)
        let result = searchResult("https://example.com/source")

        XCTAssertNil(controller.record([observation(call: first, content: result)]))
        XCTAssertNil(controller.record([observation(call: second, content: result)]))
        XCTAssertEqual(
            controller.record([observation(call: third, content: result)]),
            .stalled
        )
    }

    func testNewSearchSourceResetsStagnation() {
        var controller = ChatResearchRunController()

        XCTAssertNil(controller.record([
            observation(
                call: call(arguments: #"{"query":"one"}"#),
                content: searchResult("https://example.com/one")
            ),
        ]))
        XCTAssertNil(controller.record([
            observation(
                call: call(arguments: #"{"query":"two"}"#),
                content: searchResult("https://example.com/one")
            ),
        ]))
        XCTAssertNil(controller.record([
            observation(
                call: call(arguments: #"{"query":"three"}"#),
                content: searchResult("https://example.com/two")
            ),
        ]))
        XCTAssertNil(controller.record([
            observation(
                call: call(arguments: #"{"query":"four"}"#),
                content: searchResult("https://example.com/two")
            ),
        ]))
    }

    func testRepeatedFailedWebBatchesFinalizeResearch() {
        var controller = ChatResearchRunController()
        let failure = #"{"ok":false,"error":"rate limited"}"#

        XCTAssertNil(controller.record([
            observation(call: call(arguments: #"{"query":"one"}"#), content: failure, succeeded: false),
        ]))
        XCTAssertEqual(
            controller.record([
                observation(call: call(arguments: #"{"query":"two"}"#), content: failure, succeeded: false),
            ]),
            .repeatedFailures
        )
    }

    func testWebToolLimitIsAnEmergencyFinalizationBoundary() {
        var controller = ChatResearchRunController()
        var reason: ChatResearchFinalizationReason?

        for index in 0 ..< ChatResearchRunController.maximumWebToolCalls {
            let readCall = call(
                name: ChatWebReadToolRegistry.toolName,
                arguments: #"{"urls":["https://example.com/\#(index)"]}"#
            )
            reason = controller.record([
                observation(call: readCall, content: #"{"pages":[]}"#),
            ])
        }

        XCTAssertEqual(reason, .toolLimit)
    }

    func testContextBudgetFinalizesBeforeToolOutputConsumesSynthesisHeadroom() {
        var controller = ChatResearchRunController()
        let pageContent = String(repeating: "evidence ", count: 600)
        let readCall = call(
            name: ChatWebReadToolRegistry.toolName,
            arguments: #"{"urls":["https://example.com/source"]}"#
        )

        let reason = controller.record(
            [observation(
                call: readCall,
                content: #"{"pages":[{"url":"https://example.com/source","content":"\#(pageContent)"}]}"#
            )],
            responseTotalTokens: 5_800,
            contextLimit: 8_192,
            maximumOutputTokens: 2_048
        )

        XCTAssertEqual(reason, .contextBudget)
    }

    func testFinalizationEvidenceDeduplicatesSourcesAndPrefersPageContent() throws {
        var controller = ChatResearchRunController()
        let url = "https://example.com/source"
        let searchCall = call(arguments: #"{"query":"Nativ evidence"}"#)
        let readCall = call(
            name: ChatWebReadToolRegistry.toolName,
            arguments: #"{"urls":["https://example.com/source"]}"#
        )

        XCTAssertNil(controller.record([
            observation(call: searchCall, content: searchResult(url)),
            observation(
                call: readCall,
                content: #"{"pages":[{"title":"Primary source","url":"\#(url)","content":"Detailed page evidence"}]}"#
            ),
        ]))
        let state = controller.finalizationState(reason: .repeatedCalls)

        XCTAssertEqual(state.evidence.sourceCount, 1)
        XCTAssertTrue(state.evidence.content.contains("Nativ evidence"))
        XCTAssertTrue(state.evidence.content.contains("Primary source"))
        XCTAssertTrue(state.evidence.content.contains("Detailed page evidence"))
    }

    func testFinalizationRejectsToolOnlyMarkupButAcceptsAnAnswer() {
        XCTAssertTrue(ChatResearchFinalizationPolicy.needsRetry(
            content: "Let me search once more. <tool_call><function=web_search></function></tool_call>",
            toolCalls: []
        ))
        XCTAssertFalse(ChatResearchFinalizationPolicy.needsRetry(
            content: "The evidence supports the conclusion [https://example.com].",
            toolCalls: []
        ))
    }

    func testIncompleteResponsePreservesCollectedSourceCount() {
        let state = ChatResearchFinalizationState(
            reason: .toolLimit,
            evidence: ChatResearchEvidenceBrief(content: "Evidence", sourceCount: 3),
            retryCount: 1
        )

        XCTAssertTrue(
            ChatResearchFinalizationPolicy.incompleteResponse(for: state)
                .contains("collected 3 sources")
        )
    }

    private func call(
        name: String = ChatWebSearchToolRegistry.toolName,
        arguments: String
    ) -> MLXChatToolCall {
        MLXChatToolCall(
            id: UUID().uuidString,
            function: MLXChatFunctionCall(name: name, arguments: arguments)
        )
    }

    private func observation(
        call: MLXChatToolCall,
        content: String,
        succeeded: Bool = true
    ) -> ChatResearchToolObservation {
        ChatResearchToolObservation(call: call, content: content, succeeded: succeeded)
    }

    private func searchResult(_ url: String) -> String {
        #"{"results":[{"title":"Source","url":"\#(url)","snippet":"Evidence"}]}"#
    }
}
