import Foundation

struct ChatWebSource: Identifiable, Hashable {
    let url: URL
    let title: String?
    let snippet: String?
    let error: String?

    var id: String { url.absoluteString }

    var host: String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    var label: String {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.flatMap { $0.isEmpty ? nil : $0 } ?? host
    }

    var faviconURL: URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

struct ChatWebActivity {
    let query: String?
    let focus: String?
    let sources: [ChatWebSource]
}

enum ChatWebSourcePresentation {
    static func activity(for message: ChatTranscriptMessage) -> ChatWebActivity? {
        activity(
            toolName: message.toolName,
            arguments: message.toolArguments,
            result: message.content
        )
    }

    static func activity(
        toolName: String?,
        arguments: String?,
        result: String
    ) -> ChatWebActivity? {
        switch toolName {
        case ChatWebSearchToolRegistry.toolName:
            return ChatWebActivity(
                query: stringArgument(named: "query", in: arguments),
                focus: nil,
                sources: searchSources(from: result)
            )
        case ChatWebReadToolRegistry.toolName:
            return ChatWebActivity(
                query: nil,
                focus: stringArgument(named: "focus", in: arguments),
                sources: readSources(
                    arguments: arguments,
                    result: result
                )
            )
        default:
            return nil
        }
    }

    private static func searchSources(from result: String) -> [ChatWebSource] {
        guard let root = object(from: result),
              let results = root["results"] as? [[String: Any]] else {
            return []
        }
        return deduplicated(results.compactMap {
            source(
                url: $0["url"] as? String,
                title: $0["title"] as? String,
                snippet: $0["snippet"] as? String,
                error: nil
            )
        })
    }

    private static func readSources(arguments: String?, result: String) -> [ChatWebSource] {
        let pages = (object(from: result)?["pages"] as? [[String: Any]]) ?? []
        let completed = pages.compactMap { page in
            source(
                url: page["url"] as? String,
                title: page["title"] as? String,
                snippet: nil,
                error: (page["error"] as? [String: Any])?["message"] as? String
            )
        }
        guard completed.isEmpty,
              let values = object(from: arguments ?? "")?["urls"] as? [String] else {
            return deduplicated(completed)
        }
        return deduplicated(values.compactMap {
            source(url: $0, title: nil, snippet: nil, error: nil)
        })
    }

    private static func source(
        url value: String?,
        title: String?,
        snippet: String?,
        error: String?
    ) -> ChatWebSource? {
        guard let value,
              let normalizedURL = WebReadURLPolicy.normalizedURL(
                  value,
                  rejectsSensitiveQuery: false
              ),
              let url = URL(string: normalizedURL) else {
            return nil
        }
        return ChatWebSource(
            url: url,
            title: title,
            snippet: snippet,
            error: error
        )
    }

    private static func deduplicated(_ sources: [ChatWebSource]) -> [ChatWebSource] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.id).inserted }
    }

    private static func stringArgument(named name: String, in arguments: String?) -> String? {
        let value = object(from: arguments ?? "")?[name] as? String
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func object(from value: String) -> [String: Any]? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
