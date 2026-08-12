import Foundation

enum ChatTranscriptPresentationItem: Identifiable, Equatable {
    case message(ChatTranscriptMessage)
    case research(ChatResearchActivity)

    var id: UUID {
        switch self {
        case .message(let message):
            message.id
        case .research(let activity):
            activity.id
        }
    }
}

enum ChatResearchActivityStatus: Equatable {
    case planning
    case searching
    case reading
    case reviewing
    case complete
    case incomplete
    case failed
    case cancelled
}

struct ChatResearchActivity: Identifiable, Equatable {
    let id: UUID
    let question: String?
    let status: ChatResearchActivityStatus
    let searchQueries: [String]
    let sources: [ChatWebSource]
    let pagesRead: [ChatWebSource]
    let errors: [String]

    var displayedSources: [ChatWebSource] {
        Self.deduplicated(pagesRead + sources)
    }

    private static func deduplicated(_ sources: [ChatWebSource]) -> [ChatWebSource] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.id).inserted }
    }
}

enum ChatTranscriptPresentation {
    static func items(from messages: [ChatTranscriptMessage]) -> [ChatTranscriptPresentationItem] {
        let researchMessages = messages.reduce(into: [UUID: [ChatTranscriptMessage]]()) {
            grouped, message in
            guard let context = message.activityContext, context.kind == .deepResearch else {
                return
            }
            grouped[context.id, default: []].append(message)
        }

        var emittedResearchIDs = Set<UUID>()
        var items: [ChatTranscriptPresentationItem] = []
        for (index, message) in messages.enumerated() {
            guard let context = message.activityContext,
                  context.kind == .deepResearch,
                  let activityMessages = researchMessages[context.id]
            else {
                if isVisibleStandaloneMessage(message) {
                    items.append(.message(message))
                }
                continue
            }

            if emittedResearchIDs.insert(context.id).inserted {
                items.append(.research(
                    activity(
                        id: context.id,
                        question: precedingQuestion(before: index, in: messages),
                        messages: activityMessages
                    )
                ))
            }

            if isVisibleOutsideResearchActivity(message) {
                items.append(.message(message))
            }
        }
        return items
    }

    private static func activity(
        id: UUID,
        question: String?,
        messages: [ChatTranscriptMessage]
    ) -> ChatResearchActivity {
        let webMessages = messages.filter { message in
            message.role == .tool && isWebTool(message.toolName)
        }
        let webActivities = webMessages.compactMap { message -> (
            ChatTranscriptMessage,
            ChatWebActivity
        )? in
            guard let activity = ChatWebSourcePresentation.activity(for: message) else {
                return nil
            }
            return (message, activity)
        }

        let searchQueries = uniqueStrings(webActivities.compactMap { message, activity in
            message.toolName == ChatWebSearchToolRegistry.toolName ? activity.query : nil
        })
        let searchSources = webActivities.flatMap { message, activity in
            message.toolName == ChatWebSearchToolRegistry.toolName ? activity.sources : []
        }
        let readSources = webActivities.flatMap { message, activity in
            message.toolName == ChatWebReadToolRegistry.toolName ? activity.sources : []
        }
        let sources = deduplicated(searchSources + readSources)
        let pagesRead = deduplicated(webActivities.flatMap { message, activity in
            guard message.toolName == ChatWebReadToolRegistry.toolName,
                  message.toolStatus == .succeeded else {
                return [ChatWebSource]()
            }
            return activity.sources.filter { $0.error == nil }
        })
        let errors = uniqueStrings(
            webMessages.compactMap(errorMessage)
                + webActivities.flatMap { _, activity in
                    activity.sources.compactMap { source in
                        source.error.map { "\(source.host): \($0)" }
                    }
                }
        )

        return ChatResearchActivity(
            id: id,
            question: question,
            status: status(for: messages, webMessages: webMessages),
            searchQueries: searchQueries,
            sources: sources,
            pagesRead: pagesRead,
            errors: errors
        )
    }

    private static func status(
        for messages: [ChatTranscriptMessage],
        webMessages: [ChatTranscriptMessage]
    ) -> ChatResearchActivityStatus {
        if let activeTool = webMessages.last(where: {
            $0.toolStatus == .preparing || $0.toolStatus == .running
        }) {
            return activeTool.toolName == ChatWebReadToolRegistry.toolName ? .reading : .searching
        }
        if let last = messages.last {
            if last.role == .error {
                return .failed
            }
            if last.isStreaming {
                return webMessages.isEmpty ? .planning : .reviewing
            }
            if last.role == .assistant,
               last.toolCalls.isEmpty,
               (!last.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !last.reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                return ChatResearchFinalizationPolicy.isIncompleteResponse(last.content)
                    ? .incomplete
                    : .complete
            }
        }
        if webMessages.contains(where: { $0.toolStatus == .cancelled }) {
            return .cancelled
        }
        if webMessages.contains(where: { $0.toolStatus == .failed }) {
            return .failed
        }
        return webMessages.isEmpty ? .planning : .reviewing
    }

    private static func isVisibleStandaloneMessage(_ message: ChatTranscriptMessage) -> Bool {
        !(message.role == .assistant
            && message.content.isEmpty
            && message.reasoningContent.isEmpty
            && !message.toolCalls.isEmpty)
    }

    private static func isVisibleOutsideResearchActivity(
        _ message: ChatTranscriptMessage
    ) -> Bool {
        switch message.role {
        case .assistant:
            return !message.isStreaming
                && message.toolCalls.isEmpty
                && (!message.content.isEmpty || !message.reasoningContent.isEmpty)
        case .tool:
            return !isWebTool(message.toolName)
        case .error:
            return true
        case .user:
            return false
        }
    }

    private static func precedingQuestion(
        before index: Int,
        in messages: [ChatTranscriptMessage]
    ) -> String? {
        messages[..<index].reversed().first(where: { $0.role == .user })?.content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }

    private static func isWebTool(_ name: String?) -> Bool {
        name == ChatWebSearchToolRegistry.toolName
            || name == ChatWebReadToolRegistry.toolName
    }

    private static func deduplicated(_ sources: [ChatWebSource]) -> [ChatWebSource] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.id).inserted }
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func errorMessage(from message: ChatTranscriptMessage) -> String? {
        guard message.toolStatus == .failed,
              let data = message.content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let error = object["error"] as? String {
            return error
        }
        return (object["error"] as? [String: Any])?["message"] as? String
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
