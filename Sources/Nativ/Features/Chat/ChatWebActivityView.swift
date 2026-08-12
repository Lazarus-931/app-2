import AppKit
import Foundation
import SwiftUI

struct ChatResearchActivityCard: View {
    let activity: ChatResearchActivity
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                header
            }
            .buttonStyle(.plain)
            .disabled(!hasDetails)
            .help(hasDetails ? (isExpanded ? "Hide research details" : "Show research details") : "")

            if !activity.displayedSources.isEmpty {
                Divider()
                    .padding(.top, 8)
                ChatWebSourceStrip(sources: activity.displayedSources)
                    .padding(.top, 8)
            }

            if isExpanded, hasDetails {
                Divider()
                    .padding(.top, 8)
                researchDetails
                    .padding(.top, 9)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Deep Research, \(statusSummary)")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 9) {
            statusIcon
                .frame(width: 16, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Deep Research")
                        .font(.callout.weight(.semibold))
                    statusBadge
                }
                Text(statusSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let question = activity.question {
                    Text(question)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 12)
            if hasDetails {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 3)
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch activity.status {
        case .planning, .searching, .reading, .reviewing:
            ProgressView()
                .controlSize(.small)
        case .complete:
            Image(systemName: activity.errors.isEmpty ? "sparkles" : "exclamationmark.circle.fill")
                .foregroundStyle(activity.errors.isEmpty ? .green : .orange)
        case .incomplete:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch activity.status {
        case .complete:
            NativStatusBadge(
                text: activity.errors.isEmpty ? "Done" : "Done with issues",
                tone: activity.errors.isEmpty ? .success : .warning
            )
        case .incomplete:
            NativStatusBadge(text: "Sources collected", tone: .warning)
        case .failed:
            NativStatusBadge(text: "Failed", tone: .danger)
        case .cancelled:
            NativStatusBadge(text: "Cancelled", tone: .neutral)
        case .planning, .searching, .reading, .reviewing:
            EmptyView()
        }
    }

    private var statusSummary: String {
        switch activity.status {
        case .planning:
            "Planning research…"
        case .searching:
            "Searching the web…"
        case .reading:
            "Reading source pages…"
        case .reviewing:
            "Writing answer…"
        case .complete:
            activity.errors.isEmpty
                ? countSummary
                : "\(countSummary) · \(issueCountLabel)"
        case .incomplete:
            "Synthesis incomplete · \(countSummary)"
        case .failed:
            activity.errors.isEmpty ? "Research stopped" : "Research stopped with an error"
        case .cancelled:
            "Research cancelled"
        }
    }

    private var countSummary: String {
        let sourceLabel = "\(activity.sources.count) source\(activity.sources.count == 1 ? "" : "s")"
        let pageLabel = "\(activity.pagesRead.count) page\(activity.pagesRead.count == 1 ? "" : "s") read"
        return "\(sourceLabel) · \(pageLabel)"
    }

    private var issueCountLabel: String {
        "\(activity.errors.count) issue\(activity.errors.count == 1 ? "" : "s")"
    }

    private var hasDetails: Bool {
        !activity.searchQueries.isEmpty
            || !activity.pagesRead.isEmpty
            || !activity.errors.isEmpty
    }

    @ViewBuilder
    private var researchDetails: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !activity.searchQueries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Searches")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(activity.searchQueries, id: \.self) { query in
                        Text(query)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }

            if !activity.pagesRead.isEmpty {
                ChatWebSourceList(title: "Pages read", sources: activity.pagesRead)
            }

            if !activity.errors.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Issues")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    ForEach(activity.errors, id: \.self) { error in
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatWebSourceStrip: View {
    let sources: [ChatWebSource]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(sources) { source in
                    Link(destination: source.url) {
                        HStack(spacing: 6) {
                            ChatWebFavicon(source: source, size: 16)
                            Text(source.host)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        }
                    }
                    .buttonStyle(.plain)
                    .help(source.label)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ChatWebActivityDetails: View {
    let activity: ChatWebActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let query = activity.query {
                detailValue(label: "Search", value: query)
            }
            if let focus = activity.focus {
                detailValue(label: "Focus", value: focus)
            }
            if activity.sources.isEmpty {
                Text("No sources returned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ChatWebSourceList(title: "Sources", sources: activity.sources)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailValue(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
        }
    }
}

private struct ChatWebSourceList: View {
    let title: String
    let sources: [ChatWebSource]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(sources) { source in
                sourceRow(source)
            }
        }
    }

    private func sourceRow(_ source: ChatWebSource) -> some View {
        Link(destination: source.url) {
            HStack(alignment: .top, spacing: 9) {
                ChatWebFavicon(source: source, size: 20)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.label)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(source.host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let snippet = source.snippet, !snippet.isEmpty {
                        Text(snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let error = source.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

private struct ChatWebFavicon: View {
    let source: ChatWebSource
    let size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: size * 0.22))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .accessibilityHidden(true)
        .task(id: source.faviconURL) {
            guard let url = source.faviconURL else { return }
            image = await ChatWebFaviconCache.shared.image(for: url)
        }
    }

    private var fallback: some View {
        Text(source.host.prefix(1).uppercased())
            .font(.system(size: size * 0.52, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private final class ChatWebFaviconCache {
    static let shared = ChatWebFaviconCache()

    private let images = NSCache<NSURL, NSImage>()
    private var unavailable = Set<URL>()
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 5
        configuration.urlCache = URLCache(memoryCapacity: 2_000_000, diskCapacity: 0)
        session = URLSession(
            configuration: configuration,
            delegate: ChatWebFaviconSessionDelegate(),
            delegateQueue: nil
        )
    }

    func image(for url: URL) async -> NSImage? {
        if let image = images.object(forKey: url as NSURL) {
            return image
        }
        guard !unavailable.contains(url) else { return nil }

        var request = URLRequest(url: url)
        request.setValue("bytes=0-262143", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200 ..< 300).contains(response.statusCode),
                  response.expectedContentLength <= 262_144,
                  data.count <= 262_144,
                  response.mimeType?.hasPrefix("image/") != false,
                  let image = NSImage(data: data) else {
                unavailable.insert(url)
                return nil
            }
            images.setObject(image, forKey: url as NSURL)
            return image
        } catch {
            unavailable.insert(url)
            return nil
        }
    }
}

private final class ChatWebFaviconSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
