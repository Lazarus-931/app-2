import Foundation

struct WebReadPage: Encodable, Equatable, Sendable {
    let url: String
    let title: String?
    let content: String?
    let truncated: Bool
    let error: WebReadPageError?

    var isSuccess: Bool { content != nil && error == nil }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(content, forKey: .content)
        if truncated {
            try container.encode(true, forKey: .truncated)
        }
        try container.encodeIfPresent(error, forKey: .error)
    }

    private enum CodingKeys: String, CodingKey {
        case url, title, content, truncated, error
    }
}

struct WebReadPageError: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

struct WebReadService: Sendable {
    private struct Document {
        let url: String
        let title: String?
        let content: String?
        let isExcerpt: Bool
        let error: WebReadPageError?

        init(
            url: String,
            title: String?,
            content: String?,
            isExcerpt: Bool = false,
            error: WebReadPageError?
        ) {
            self.url = url
            self.title = title
            self.content = content
            self.isExcerpt = isExcerpt
            self.error = error
        }
    }

    private let transport: WebBrowsingTransport
    private let maximumCharactersPerPage = 6_000
    private let maximumTotalCharacters = 20_000

    init(client: any WebBrowsingHTTPClient = URLSessionWebBrowsingHTTPClient()) {
        transport = WebBrowsingTransport(client: client)
    }

    func read(
        provider: WebSearchProvider,
        apiKey: String,
        urls: [String],
        focus: String? = nil
    ) async throws -> [WebReadPage] {
        guard provider.supports(.read) else {
            throw WebReadError.unsupportedProvider(provider)
        }
        guard (1 ... ChatWebReadToolRegistry.maximumURLs).contains(urls.count) else {
            throw WebReadError.invalidArguments
        }

        let normalizedURLs = try urls.map {
            guard let url = WebReadURLPolicy.normalizedURL($0) else {
                throw WebReadError.invalidURL
            }
            return url
        }
        guard Set(normalizedURLs).count == normalizedURLs.count else {
            throw WebReadError.invalidArguments
        }
        let focus = focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard focus?.count ?? 0 <= ChatWebReadToolRegistry.maximumFocusLength else {
            throw WebReadError.invalidArguments
        }
        let normalizedFocus = focus?.isEmpty == false ? focus : nil

        let documents: [Document]
        switch provider {
        case .exa:
            documents = try await readExa(
                apiKey: apiKey,
                urls: normalizedURLs,
                focus: normalizedFocus
            )
        case .nimble:
            documents = try await readIndividually(
                provider: provider,
                urls: normalizedURLs
            ) { url in
                try await readNimble(apiKey: apiKey, url: url)
            }
        case .firecrawl:
            documents = try await readIndividually(
                provider: provider,
                urls: normalizedURLs
            ) { url in
                try await readFirecrawl(apiKey: apiKey, url: url)
            }
        case .brave, .perplexity:
            throw WebReadError.unsupportedProvider(provider)
        }

        return boundedPages(documents, focus: normalizedFocus)
    }

    private func readExa(
        apiKey: String,
        urls: [String],
        focus: String?
    ) async throws -> [Document] {
        let provider = WebSearchProvider.exa
        let highlights = focus.flatMap { value in
            value.isEmpty
                ? nil
                : ExaHighlightsRequest(
                    query: value,
                    maxCharacters: maximumCharactersPerPage
                )
        }
        let request = try transport.postRequest(
            url: "https://api.exa.ai/contents",
            provider: provider,
            apiKey: apiKey,
            authentication: .header("x-api-key"),
            body: ExaReadRequest(
                urls: urls,
                text: highlights == nil ? true : nil,
                highlights: highlights
            ),
            timeout: 30
        )
        let response: ExaReadResponse = try await transport.response(for: request, provider: provider)
        return urls.map { requestedURL in
            guard let result = response.results.first(where: {
                $0.id == requestedURL || $0.url == requestedURL
            }) else {
                return Document(
                    url: requestedURL,
                    title: nil,
                    content: nil,
                    error: WebReadPageError(
                        code: "page_unavailable",
                        message: "Exa could not read this page."
                    )
                )
            }
            let highlights = result.highlights?
                .compactMap { normalizedContent($0) }
                .joined(separator: "\n\n")
            let focusedContent = normalizedContent(highlights)
            guard let content = focusedContent ?? normalizedContent(result.text) else {
                return Document(
                    url: requestedURL,
                    title: normalizedTitle(result.title),
                    content: nil,
                    error: WebReadPageError(
                        code: "page_unavailable",
                        message: "Exa could not read this page."
                    )
                )
            }
            return Document(
                url: requestedURL,
                title: normalizedTitle(result.title),
                content: content,
                isExcerpt: focusedContent != nil,
                error: nil
            )
        }
    }

    private func readNimble(apiKey: String, url: String) async throws -> Document {
        let provider = WebSearchProvider.nimble
        let request = try transport.postRequest(
            url: "https://sdk.nimbleway.com/v2/extract",
            provider: provider,
            apiKey: apiKey,
            authentication: .bearer,
            body: NimbleReadRequest(url: url, formats: ["markdown"], render: "auto"),
            timeout: 30
        )
        let response: NimbleReadResponse = try await transport.response(for: request, provider: provider)
        guard response.status == "success", let content = normalizedContent(response.data.markdown) else {
            throw WebReadError.pageUnavailable(provider)
        }
        return Document(url: url, title: nil, content: content, error: nil)
    }

    private func readFirecrawl(apiKey: String, url: String) async throws -> Document {
        let provider = WebSearchProvider.firecrawl
        let request = try transport.postRequest(
            url: "https://api.firecrawl.dev/v2/scrape",
            provider: provider,
            apiKey: apiKey,
            authentication: .bearer,
            body: FirecrawlReadRequest(
                url: url,
                formats: ["markdown"],
                onlyMainContent: true,
                removeBase64Images: true
            ),
            timeout: 30
        )
        let response: FirecrawlReadResponse = try await transport.response(for: request, provider: provider)
        guard response.success, let content = normalizedContent(response.data.markdown) else {
            throw WebReadError.pageUnavailable(provider)
        }
        return Document(
            url: url,
            title: normalizedTitle(response.data.metadata?.title),
            content: content,
            error: nil
        )
    }

    private func readIndividually(
        provider: WebSearchProvider,
        urls: [String],
        operation: (String) async throws -> Document
    ) async throws -> [Document] {
        var documents: [Document] = []
        documents.reserveCapacity(urls.count)
        for url in urls {
            do {
                documents.append(try await operation(url))
            } catch let error as WebBrowsingError {
                if error.shouldAbortReadBatch {
                    throw error
                }
                documents.append(Document(
                    url: url,
                    title: nil,
                    content: nil,
                    error: WebReadPageError(
                        code: error.code.rawValue,
                        message: "\(provider.metadata.displayName) could not read this page."
                    )
                ))
            } catch let error as WebReadError {
                documents.append(Document(
                    url: url,
                    title: nil,
                    content: nil,
                    error: WebReadPageError(code: error.code, message: error.localizedDescription)
                ))
            }
        }
        return documents
    }

    private func boundedPages(_ documents: [Document], focus: String?) -> [WebReadPage] {
        let successfulDocumentCount = max(
            documents.filter { $0.content != nil && $0.error == nil }.count,
            1
        )
        let perPageLimit = min(
            maximumCharactersPerPage,
            maximumTotalCharacters / successfulDocumentCount
        )
        var remainingCharacters = maximumTotalCharacters
        return documents.map { document in
            guard let content = document.content, document.error == nil else {
                return WebReadPage(
                    url: document.url,
                    title: document.title,
                    content: nil,
                    truncated: false,
                    error: document.error
                )
            }

            let limit = min(perPageLimit, remainingCharacters)
            let selection = WebReadContentSelector.select(content, focus: focus, limit: limit)
            remainingCharacters -= selection.content.count
            return WebReadPage(
                url: document.url,
                title: document.title,
                content: selection.content,
                truncated: document.isExcerpt || selection.truncated,
                error: nil
            )
        }
    }

    private func normalizedContent(_ content: String?) -> String? {
        let content = content?
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return content?.isEmpty == false ? content : nil
    }

    private func normalizedTitle(_ title: String?) -> String? {
        let title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title?.isEmpty == false else { return nil }
        return title.map { String($0.prefix(200)) }
    }
}

enum WebReadURLPolicy {
    private static let sensitiveQueryNames: Set<String> = [
        "access_token", "api_key", "apikey", "auth", "authorization", "key", "password",
        "secret", "signature", "sig", "token",
    ]

    static func normalizedURL(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2_048,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.user == nil,
              components.password == nil,
              let host = components.host?.lowercased(),
              isPublicHost(host),
              !containsSensitiveQuery(components.queryItems) else {
            return nil
        }
        components.fragment = nil
        return components.url?.absoluteString
    }

    private static func containsSensitiveQuery(_ items: [URLQueryItem]?) -> Bool {
        items?.contains { sensitiveQueryNames.contains($0.name.lowercased()) } == true
    }

    private static func isPublicHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        let blockedNames = ["localhost", "localhost.localdomain"]
        guard !blockedNames.contains(host),
              !host.hasSuffix(".localhost"),
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              !host.hasSuffix(".lan"),
              !host.hasSuffix(".home") else {
            return false
        }
        if let octets = ipv4Octets(host) {
            return isPublicIPv4(octets)
        }
        if isAmbiguousNumericHost(host) {
            return false
        }
        if host.contains(":") {
            return isPublicIPv6(host)
        }
        return host.contains(".")
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0 ... 255).contains($0) }) else {
            return nil
        }
        return octets
    }

    private static func isAmbiguousNumericHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return !labels.isEmpty && labels.allSatisfy { label in
            let label = label.lowercased()
            if label.hasPrefix("0x") {
                return !label.dropFirst(2).isEmpty
                    && label.dropFirst(2).allSatisfy { $0.isHexDigit }
            }
            return label.allSatisfy { $0.isNumber }
        }
    }

    private static func isPublicIPv4(_ octets: [Int]) -> Bool {
        let first = octets[0]
        let second = octets[1]
        switch first {
        case 0, 10, 127, 224 ... 255:
            return false
        case 100 where (64 ... 127).contains(second):
            return false
        case 169 where second == 254:
            return false
        case 172 where (16 ... 31).contains(second):
            return false
        case 192 where second == 168 || (second == 0 && octets[2] == 0):
            return false
        case 198 where (18 ... 19).contains(second):
            return false
        default:
            return true
        }
    }

    private static func isPublicIPv6(_ host: String) -> Bool {
        let host = host.lowercased()
        guard host != "::", host != "::1", !host.hasPrefix("::ffff:") else {
            return false
        }
        return !host.hasPrefix("fc")
            && !host.hasPrefix("fd")
            && !host.hasPrefix("fe8")
            && !host.hasPrefix("fe9")
            && !host.hasPrefix("fea")
            && !host.hasPrefix("feb")
    }
}

private struct ExaReadRequest: Encodable {
    let urls: [String]
    let text: Bool?
    let highlights: ExaHighlightsRequest?
}

private struct ExaHighlightsRequest: Encodable {
    let query: String
    let maxCharacters: Int
}

private struct ExaReadResponse: Decodable {
    let results: [ExaReadResult]
}

private struct ExaReadResult: Decodable {
    let id: String?
    let title: String?
    let url: String?
    let text: String?
    let highlights: [String]?
}

private struct NimbleReadRequest: Encodable {
    let url: String
    let formats: [String]
    let render: String
}

private struct NimbleReadResponse: Decodable {
    let status: String
    let data: NimbleReadData
}

private struct NimbleReadData: Decodable {
    let markdown: String?
}

private struct FirecrawlReadRequest: Encodable {
    let url: String
    let formats: [String]
    let onlyMainContent: Bool
    let removeBase64Images: Bool
}

private struct FirecrawlReadResponse: Decodable {
    let success: Bool
    let data: FirecrawlReadData
}

private struct FirecrawlReadData: Decodable {
    let markdown: String?
    let metadata: FirecrawlReadMetadata?
}

private struct FirecrawlReadMetadata: Decodable {
    let title: String?
}

enum WebReadError: LocalizedError {
    case invalidArguments
    case invalidURL
    case pageReaderNotConfigured(WebSearchProvider)
    case unsupportedProvider(WebSearchProvider)
    case pageUnavailable(WebSearchProvider)
    case unexpectedFailure

    var code: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .invalidURL: "invalid_url"
        case .pageReaderNotConfigured: "page_reader_not_configured"
        case .unsupportedProvider: "unsupported_provider"
        case .pageUnavailable: "page_unavailable"
        case .unexpectedFailure: "unexpected_failure"
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            "web_read needs one to four unique URLs and an optional focus no longer than \(ChatWebReadToolRegistry.maximumFocusLength) characters."
        case .invalidURL:
            "web_read accepts only public HTTP or HTTPS URLs without embedded credentials."
        case .pageReaderNotConfigured(let searchProvider):
            "\(searchProvider.metadata.displayName) supports web search but not page reading."
        case .unsupportedProvider(let provider):
            "\(provider.metadata.displayName) does not support reading arbitrary URLs."
        case .pageUnavailable(let provider):
            "\(provider.metadata.displayName) could not read this page."
        case .unexpectedFailure:
            "Web read failed unexpectedly."
        }
    }
}

private extension WebBrowsingError {
    var shouldAbortReadBatch: Bool {
        switch self {
        case .providerUnavailable:
            true
        case .requestFailed(_, let status):
            [401, 402, 403, 429].contains(status)
        case .invalidArguments, .missingAPIKey, .credentialAccess, .invalidResponse, .responseTooLarge,
             .unexpectedFailure:
            false
        }
    }
}
