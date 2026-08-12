import AppKit
import SwiftUI

@MainActor
final class WebSearchSettingsViewModel: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connected
        case issue(WebSearchCredentialIssue)
    }

    enum Status: Equatable {
        case connected(String)
        case failure(String)
    }

    @Published var selectedProvider: WebSearchProvider
    @Published private(set) var searchProvider: WebSearchProvider
    @Published private(set) var pageReaderProvider: WebSearchProvider?
    @Published var draftAPIKey = ""
    @Published var revealsKey = false
    @Published private(set) var isTesting = false
    @Published private(set) var status: Status?
    @Published private(set) var connectionStates: [WebSearchProvider: ConnectionState] = [:]

    private let preferences: WebBrowsingPreferences
    private let credentials: any WebSearchCredentialStoring
    private let service: WebSearchService

    init(
        preferences: WebBrowsingPreferences = WebBrowsingPreferences(),
        credentials: any WebSearchCredentialStoring = KeychainWebSearchCredentialStore(),
        service: WebSearchService = WebSearchService()
    ) {
        self.preferences = preferences
        self.credentials = credentials
        self.service = service
        selectedProvider = preferences.searchProvider
        searchProvider = preferences.searchProvider
        pageReaderProvider = preferences.pageReaderProvider
        loadConnectionStates()
    }

    var selectedConnectionState: ConnectionState {
        connectionStates[selectedProvider] ?? .disconnected
    }

    var canConnect: Bool {
        !isTesting && !draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func select(_ provider: WebSearchProvider) {
        guard !isTesting else { return }
        selectedProvider = provider
        draftAPIKey = ""
        revealsKey = false
        status = nil
    }

    func setSearchProvider(_ provider: WebSearchProvider) {
        guard !isTesting else { return }
        searchProvider = provider
        preferences.searchProvider = provider
        select(provider)
    }

    func setPageReaderProvider(_ provider: WebSearchProvider?) {
        guard !isTesting, provider?.supports(.read) != false else { return }
        pageReaderProvider = provider
        preferences.pageReaderProvider = provider
        if let provider {
            select(provider)
        }
    }

    func testAndConnect() async -> Bool {
        let apiKey = draftAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty, !isTesting else { return false }
        let provider = selectedProvider
        let hadConfiguredSearch = hasCredential(for: searchProvider)
        let hadConfiguredReader = resolvedPageReaderProvider.map {
            hasCredential(for: $0)
        } ?? false
        isTesting = true
        status = nil

        defer { isTesting = false }
        do {
            try await service.validateCredential(provider: provider, apiKey: apiKey)
            try credentials.save(apiKey, for: provider)
            preferences.setCredentialIssue(nil, for: provider)
            connectionStates[provider] = .connected
            if !hadConfiguredSearch {
                searchProvider = provider
                preferences.searchProvider = provider
            }
            if !hadConfiguredReader,
               resolvedPageReaderProvider == nil,
               provider.supports(.read) {
                pageReaderProvider = provider
                preferences.pageReaderProvider = provider
            }
            if selectedProvider == provider {
                draftAPIKey = ""
                revealsKey = false
                status = .connected("Connected to \(provider.metadata.displayName).")
            }
            return true
        } catch {
            if selectedProvider == provider {
                status = .failure(error.localizedDescription)
            }
            return false
        }
    }

    var resolvedPageReaderProvider: WebSearchProvider? {
        preferences.provider(for: .read)
    }

    var pageReaderStatus: String? {
        guard let provider = resolvedPageReaderProvider else {
            return "\(searchProvider.metadata.displayName) cannot read pages. Choose a page reader."
        }
        switch connectionStates[provider] ?? .disconnected {
        case .connected:
            return nil
        case .disconnected:
            return "Connect \(provider.metadata.displayName) to enable page reading."
        case .issue:
            return "\(provider.metadata.displayName) needs attention before it can read pages."
        }
    }

    func removeKey() -> Bool {
        let provider = selectedProvider
        do {
            try credentials.remove(for: provider)
            preferences.setCredentialIssue(nil, for: provider)
            connectionStates[provider] = .disconnected
            draftAPIKey = ""
            revealsKey = false
            status = nil
            return true
        } catch {
            status = .failure(error.localizedDescription)
            return false
        }
    }

    private func loadConnectionStates() {
        for provider in WebSearchProvider.allCases {
            do {
                guard try credentials.load(for: provider) != nil else {
                    connectionStates[provider] = .disconnected
                    continue
                }
                if let issue = preferences.credentialIssue(for: provider) {
                    connectionStates[provider] = .issue(issue)
                } else {
                    connectionStates[provider] = .connected
                }
            } catch {
                connectionStates[provider] = .disconnected
                if provider == selectedProvider {
                    status = .failure("Nativ could not read this provider's API key from Keychain.")
                }
            }
        }
    }

    private func hasCredential(for provider: WebSearchProvider) -> Bool {
        switch connectionStates[provider] ?? .disconnected {
        case .connected, .issue:
            true
        case .disconnected:
            false
        }
    }
}

@MainActor
struct WebSearchSettingsView: View {
    @StateObject private var viewModel: WebSearchSettingsViewModel
    private let onConfigurationChanged: (Bool) -> Void

    init(
        onConfigurationChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _viewModel = StateObject(wrappedValue: WebSearchSettingsViewModel())
        self.onConfigurationChanged = onConfigurationChanged
    }

    init(
        viewModel: WebSearchSettingsViewModel,
        onConfigurationChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onConfigurationChanged = onConfigurationChanged
    }

    var body: some View {
        VStack(spacing: 16) {
            providerRouting
            HStack(alignment: .top, spacing: 16) {
                providerPicker
                    .frame(width: 250)
                keySetup
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var providerRouting: some View {
        VStack(alignment: .leading, spacing: 10) {
            routeRow("Search provider", selection: Binding(
                get: { viewModel.searchProvider },
                set: { viewModel.setSearchProvider($0) }
            ))

            HStack(spacing: 12) {
                Text("Page reader")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 100, alignment: .leading)
                Picker("", selection: Binding(
                    get: { viewModel.pageReaderProvider },
                    set: { viewModel.setPageReaderProvider($0) }
                )) {
                    Text("Same as search")
                        .tag(nil as WebSearchProvider?)
                    ForEach(WebSearchProvider.pageReaders) { provider in
                        Text(provider.metadata.displayName)
                            .tag(provider as WebSearchProvider?)
                    }
                }
                .labelsHidden()
                .disabled(viewModel.isTesting)
                Spacer(minLength: 0)
            }

            if let status = viewModel.pageReaderStatus {
                Label(status, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func routeRow(
        _ title: String,
        selection: Binding<WebSearchProvider>
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 100, alignment: .leading)
            Picker("", selection: selection) {
                ForEach(WebSearchProvider.allCases) { provider in
                    Text(provider.metadata.displayName)
                        .tag(provider)
                }
            }
            .labelsHidden()
            .disabled(viewModel.isTesting)
            Spacer(minLength: 0)
        }
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Providers")
                .font(.system(size: 13, weight: .semibold))

            ForEach(WebSearchProvider.allCases) { provider in
                providerRow(provider)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func providerRow(_ provider: WebSearchProvider) -> some View {
        HStack(spacing: 4) {
            Button {
                viewModel.select(provider)
                if viewModel.selectedConnectionState == .connected {
                    onConfigurationChanged(true)
                }
            } label: {
                HStack(spacing: 10) {
                    ProviderLogo(provider: provider, size: 24)
                    Text(provider.metadata.displayName)
                        .font(.system(
                            size: 12,
                            weight: provider == viewModel.selectedProvider ? .semibold : .regular
                        ))
                    Spacer(minLength: 0)
                    connectionIndicator(for: provider)
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 7)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isTesting)

            Link(destination: provider.metadata.apiKeySetupURL) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Open \(provider.metadata.displayName) API key setup")
            .accessibilityLabel("Open \(provider.metadata.displayName) API key setup")
        }
        .background(
            provider == viewModel.selectedProvider ? Color.accentColor.opacity(0.12) : .clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    @ViewBuilder
    private func connectionIndicator(for provider: WebSearchProvider) -> some View {
        switch viewModel.connectionStates[provider] ?? .disconnected {
        case .disconnected:
            EmptyView()
        case .connected:
            Circle()
                .fill(Color.green)
                .frame(width: 6, height: 6)
                .help("Connected")
        case .issue:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .help("This connection needs attention")
        }
    }

    private var keySetup: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.selectedProvider.metadata.displayName)
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                keyField
                Button { viewModel.revealsKey.toggle() } label: {
                    Image(systemName: viewModel.revealsKey ? "eye.slash" : "eye")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(viewModel.revealsKey ? "Hide API key" : "Show API key")
            }

            HStack {
                Button(viewModel.isTesting ? "Testing…" : "Test & connect") {
                    Task {
                        if await viewModel.testAndConnect() {
                            onConfigurationChanged(true)
                        }
                    }
                }
                .disabled(!viewModel.canConnect)

                if viewModel.selectedConnectionState != .disconnected {
                    Button("Remove key", role: .destructive) {
                        if viewModel.removeKey() {
                            onConfigurationChanged(false)
                        }
                    }
                    .disabled(viewModel.isTesting)
                }
                Spacer()
            }

            statusView

            Text("Browsing requests are sent to the selected third-party providers. API keys stay in macOS Keychain.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var keyField: some View {
        let prompt = "Enter \(viewModel.selectedProvider.metadata.displayName) API key"
        if viewModel.revealsKey {
            TextField(prompt, text: $viewModel.draftAPIKey)
                .textFieldStyle(.roundedBorder)
        } else {
            SecureField(prompt, text: $viewModel.draftAPIKey)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let status = viewModel.status {
            switch status {
            case .connected(let message):
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            case .failure(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        } else {
            switch viewModel.selectedConnectionState {
            case .disconnected:
                EmptyView()
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            case .issue(let issue):
                Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct ProviderLogo: View {
    let provider: WebSearchProvider
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary)
                    .padding(3)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
    }

    private var image: NSImage? {
        Bundle.main.url(
            forResource: provider.metadata.logoResourceName,
            withExtension: "png"
        ).flatMap(NSImage.init(contentsOf:))
    }
}

private extension WebSearchCredentialIssue {
    var message: String {
        switch self {
        case .invalidAuthentication:
            "Replace this provider's API key."
        case .insufficientFunds:
            "This provider needs additional credits."
        case .planAccess:
            "This provider's plan does not allow API search."
        }
    }
}
