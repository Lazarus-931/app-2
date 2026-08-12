import Foundation
import NativServerKit

enum ChatResearchFinalizationReason: Equatable {
    case repeatedCalls
    case stalled
    case repeatedFailures
    case toolLimit

    var summary: String {
        switch self {
        case .repeatedCalls:
            "the next calls repeated completed work"
        case .stalled:
            "recent searches stopped finding new sources"
        case .repeatedFailures:
            "the browsing providers repeatedly failed"
        case .toolLimit:
            "the research run reached its tool-call safety limit"
        }
    }
}

struct ChatResearchFinalizationState: Equatable {
    let reason: ChatResearchFinalizationReason
    var retryCount = 0
}

struct ChatResearchToolObservation {
    let call: MLXChatToolCall
    let content: String
    let succeeded: Bool

    var toolName: String? { call.function?.name }
    var arguments: String? { call.function?.arguments }
}

struct ChatResearchCachedToolResult {
    let call: MLXChatToolCall
    let content: String
}

struct ChatResearchRunController {
    static let maximumWebToolCalls = 20

    private var successfulResults: [String: String] = [:]
    private var discoveredSourceIDs = Set<String>()
    private var webToolCallCount = 0
    private var unproductiveSearchRounds = 0
    private var failedWebBatches = 0

    static func containsOnlyWebCalls(_ calls: [MLXChatToolCall]) -> Bool {
        !calls.isEmpty && calls.allSatisfy { isWebTool($0.function?.name) }
    }

    func cachedResults(for calls: [MLXChatToolCall]) -> [ChatResearchCachedToolResult]? {
        guard Self.containsOnlyWebCalls(calls) else { return nil }
        let cached = calls.compactMap { call -> ChatResearchCachedToolResult? in
            guard let content = successfulResults[ChatToolCallSignature.value(for: call)] else {
                return nil
            }
            return ChatResearchCachedToolResult(call: call, content: content)
        }
        return cached.count == calls.count ? cached : nil
    }

    mutating func record(
        _ observations: [ChatResearchToolObservation]
    ) -> ChatResearchFinalizationReason? {
        let webObservations = observations.filter { Self.isWebTool($0.toolName) }
        guard !webObservations.isEmpty else { return nil }

        webToolCallCount += webObservations.count
        for observation in webObservations where observation.succeeded {
            successfulResults[ChatToolCallSignature.value(for: observation.call)] = observation.content
        }

        updateSearchProgress(from: webObservations)
        failedWebBatches = webObservations.allSatisfy { !$0.succeeded }
            ? failedWebBatches + 1
            : 0

        if failedWebBatches >= 2 {
            return .repeatedFailures
        }
        if unproductiveSearchRounds >= 2 {
            return .stalled
        }
        if webToolCallCount >= Self.maximumWebToolCalls {
            return .toolLimit
        }
        return nil
    }

    private mutating func updateSearchProgress(
        from observations: [ChatResearchToolObservation]
    ) {
        let searches = observations.filter {
            $0.succeeded && $0.toolName == ChatWebSearchToolRegistry.toolName
        }
        guard !searches.isEmpty else { return }

        let sourceIDs = Set(searches.flatMap { observation in
            ChatWebSourcePresentation.activity(
                toolName: observation.toolName,
                arguments: observation.arguments,
                result: observation.content
            )?.sources.map(\.id) ?? []
        })
        let newSourceIDs = sourceIDs.subtracting(discoveredSourceIDs)
        discoveredSourceIDs.formUnion(sourceIDs)
        unproductiveSearchRounds = newSourceIDs.isEmpty
            ? unproductiveSearchRounds + 1
            : 0
    }

    private static func isWebTool(_ name: String?) -> Bool {
        name == ChatWebSearchToolRegistry.toolName
            || name == ChatWebReadToolRegistry.toolName
    }
}

enum ChatResearchFinalizationPolicy {
    static func instruction(for state: ChatResearchFinalizationState) -> String {
        let retry = state.retryCount == 0
            ? ""
            : " Your previous response attempted another tool call even though tools are no longer available."
        return """
        The research phase is complete because \(state.reason.summary).\(retry)
        Do not call tools, emit tool-call markup, or describe what you would search next.
        Answer the user's original request now using the evidence already gathered. Cite source URLs inline, distinguish supported facts from uncertainty, and mention any material provider failures.
        """
    }

    static func needsRetry(content: String, toolCalls: [MLXChatToolCall]) -> Bool {
        if !toolCalls.isEmpty {
            return true
        }
        let response = content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !response.isEmpty else { return true }
        return [
            "<tool_call",
            "<function=",
            "<|tool_call|>",
            "```tool_call",
        ].contains { response.contains($0) }
    }
}

enum ChatResearchFinalizationError: LocalizedError {
    case noFinalAnswer

    var errorDescription: String? {
        "Research finished, but the model did not produce a final answer. Try a larger tool-capable model or ask for a narrower topic."
    }
}
