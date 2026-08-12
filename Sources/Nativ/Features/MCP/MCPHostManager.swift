import Combine
import Foundation
import NativServerKit

enum MCPServerConnectionState: Equatable {
    case available
    case connecting
    case connected(toolCount: Int)
    case failed(String)
}

struct MCPHostedTool {
    let serverID: UUID
    let definition: MLXChatToolDefinition
}

@MainActor
final class MCPServerLease {
    let serverIDs: Set<UUID>

    private let id: UUID
    private weak var host: MCPHostManager?
    private var isReleased = false

    fileprivate init(id: UUID, serverIDs: Set<UUID>, host: MCPHostManager) {
        self.id = id
        self.serverIDs = serverIDs
        self.host = host
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        host?.releaseLease(id)
    }

    deinit {
        // Safety net: if an owner drops the lease without calling release()
        // (e.g. a cancelled task before its defer runs), free its servers so
        // they aren't left connected for the app's lifetime. releaseLease is
        // idempotent, so a normal release() first makes this a no-op.
        guard !isReleased, let host else { return }
        let id = self.id
        Task { @MainActor in host.releaseLease(id) }
    }
}

@MainActor
final class MCPHostManager: ObservableObject {
    @Published private(set) var states: [UUID: MCPServerConnectionState] = [:]

    private struct Connection {
        let config: MCPServerConfig
        let client: MCPClient
        let slug: String
        let tools: [MCPToolInfo]
    }

    private var connections: [UUID: Connection] = [:]
    private var appliedServers: [MCPServerConfig] = []
    private var leasedServerIDs: [UUID: Set<UUID>] = [:]
    private var manuallyConnectedServerIDs = Set<UUID>()
    // Slugs embedded in tool names must stay stable across reconnects, so a
    // server keeps its assigned slug for as long as it remains configured.
    private var slugByServerID: [UUID: String] = [:]
    private var reloadTask: Task<Void, Never>?
    private var reloadGeneration = 0

    func hostedTools(serverIDs: Set<UUID>) -> [MCPHostedTool] {
        connections.compactMap { id, connection in
            serverIDs.contains(id) ? (id, connection) : nil
        }.sorted {
            $0.0.uuidString < $1.0.uuidString
        }.flatMap { _, connection in
            connection.tools.map { tool in
                MCPHostedTool(
                    serverID: connection.config.id,
                    definition: MLXChatToolDefinition(
                        function: MLXChatFunctionDefinition(
                            name: Self.toolName(slug: connection.slug, tool: tool.name),
                            description: tool.description,
                            parameters: tool.parameters
                        )
                    )
                )
            }
        }
    }

    func toolDefinitions(serverIDs: Set<UUID>) -> [MLXChatToolDefinition] {
        hostedTools(serverIDs: serverIDs).map(\.definition)
    }

    func toolDefinitions() -> [MLXChatToolDefinition] {
        toolDefinitions(serverIDs: Set(connections.keys))
    }

    func tools(forServer id: UUID) -> [(name: String, displayName: String)] {
        guard let connection = connections[id] else { return [] }
        return connection.tools.map {
            (name: Self.toolName(slug: connection.slug, tool: $0.name), displayName: $0.name)
        }
    }

    func handlesTool(named name: String, serverIDs: Set<UUID>) -> Bool {
        route(for: name, serverIDs: serverIDs) != nil
    }

    func handlesTool(named name: String) -> Bool {
        handlesTool(named: name, serverIDs: Set(connections.keys))
    }

    func callTool(
        named name: String,
        argumentsJSON: String?,
        serverID: UUID
    ) async throws -> String {
        guard let route = route(for: name, serverID: serverID) else {
            throw MCPClientError.notConnected
        }
        return try await route.client.callTool(name: route.toolName, argumentsJSON: argumentsJSON)
    }

    func callTool(named name: String, argumentsJSON: String?) async throws -> String {
        try await callTool(
            named: name,
            argumentsJSON: argumentsJSON,
            serverIDs: Set(connections.keys)
        )
    }

    private func callTool(
        named name: String,
        argumentsJSON: String?,
        serverIDs: Set<UUID>
    ) async throws -> String {
        guard let route = route(for: name, serverIDs: serverIDs) else {
            throw MCPClientError.notConnected
        }
        return try await route.client.callTool(name: route.toolName, argumentsJSON: argumentsJSON)
    }

    func reload(servers: [MCPServerConfig]) {
        guard servers != appliedServers else { return }
        appliedServers = servers
        scheduleReload(servers: servers, debounce: true)
    }

    func acquireLease(
        serverIDs: Set<UUID>,
        servers: [MCPServerConfig]
    ) async -> MCPServerLease {
        appliedServers = servers
        let configuredIDs = Set(servers.map(\.id))
        let leaseID = UUID()
        let leasedIDs = serverIDs.intersection(configuredIDs)
        leasedServerIDs[leaseID] = leasedIDs
        scheduleReload(servers: servers, debounce: false)
        await waitForLatestReload()
        return MCPServerLease(id: leaseID, serverIDs: leasedIDs, host: self)
    }

    fileprivate func releaseLease(_ id: UUID) {
        guard leasedServerIDs.removeValue(forKey: id) != nil else { return }
        scheduleReload(servers: appliedServers, debounce: true)
    }

    func reconnect(_ serverID: UUID) {
        manuallyConnectedServerIDs.insert(serverID)
        if let connection = connections.removeValue(forKey: serverID) {
            states[serverID] = .connecting
            let client = connection.client
            Task { await client.disconnect() }
        }
        scheduleReload(servers: appliedServers, debounce: false)
    }

    func shutdown() {
        reloadTask?.cancel()
        let previous = connections
        connections = [:]
        states = [:]
        leasedServerIDs = [:]
        manuallyConnectedServerIDs = []
        slugByServerID = [:]
        Task {
            for connection in previous.values {
                await connection.client.disconnect()
            }
        }
    }

    private func scheduleReload(servers: [MCPServerConfig], debounce: Bool) {
        reloadGeneration += 1
        let generation = reloadGeneration
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(400))
            }
            // Bail for both paths once superseded, so a non-debounced reload
            // that was cancelled by a newer one never runs applyReload.
            if Task.isCancelled { return }
            await self?.applyReload(servers: servers, generation: generation)
        }
    }

    private func waitForLatestReload() async {
        while true {
            let generation = reloadGeneration
            let task = reloadTask
            await task?.value
            if generation == reloadGeneration {
                return
            }
        }
    }

    private func applyReload(servers: [MCPServerConfig], generation: Int) async {
        // A superseded reload must not mutate shared connection/state; the newer
        // generation owns it now.
        guard generation == reloadGeneration else { return }
        manuallyConnectedServerIDs.formIntersection(servers.map(\.id))
        let activeServerIDs = leasedServerIDs.values.reduce(
            into: manuallyConnectedServerIDs
        ) { result, ids in
            result.formUnion(ids)
        }
        let active = servers.filter { activeServerIDs.contains($0.id) }
        let activeByID = Dictionary(active.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (id, connection) in connections {
            // Re-check between awaits: a newer reload can supersede us while a
            // previous disconnect is in flight, and it must not tear down a
            // server the newer generation wants to keep.
            guard generation == reloadGeneration else { return }
            let reusable = activeByID[id].map { Self.launchEquivalent($0, connection.config) } ?? false
            if !reusable {
                connections[id] = nil
                await connection.client.disconnect()
            }
        }
        guard generation == reloadGeneration else { return }

        for server in servers where !activeServerIDs.contains(server.id) {
            states[server.id] = .available
        }
        pruneStates(keeping: servers)

        let toConnect = active.filter { connections[$0.id] == nil }
        guard !toConnect.isEmpty else { return }

        for config in toConnect {
            states[config.id] = .connecting
        }
        let searchPath = await Task.detached(priority: .utility) {
            ShellEnvironment.resolveFromLoginShell(names: ["PATH"])["PATH"]
        }.value
        guard generation == reloadGeneration else { return }

        var pending: [(config: MCPServerConfig, client: MCPClient)] = []
        for config in toConnect where connections[config.id] == nil {
            guard let executable = Self.resolveExecutable(config.command, searchPath: searchPath) else {
                states[config.id] = .failed("Couldn’t find “\(config.command)”")
                continue
            }
            let client = MCPClient(
                executableURL: executable,
                arguments: config.arguments,
                environment: Self.childEnvironment(searchPath: searchPath, overrides: config.environment),
                workingDirectory: Self.workingDirectory(for: config.id.uuidString)
            )
            pending.append((config, client))
        }
        guard !pending.isEmpty else { return }

        // Connect every server concurrently so a slow or hung one can't hold up
        // the rest; each has its own handshake deadline.
        await withTaskGroup(of: ConnectOutcome.self) { group in
            for item in pending {
                group.addTask {
                    do {
                        let tools = try await item.client.connectAndListTools()
                        return ConnectOutcome(config: item.config, tools: tools, error: nil, client: item.client)
                    } catch {
                        return ConnectOutcome(config: item.config, tools: nil, error: error.localizedDescription, client: item.client)
                    }
                }
            }

            var usedSlugs = Set(connections.values.map(\.slug))
            for await outcome in group {
                guard generation == reloadGeneration else {
                    await outcome.client.disconnect()
                    continue
                }
                if let tools = outcome.tools {
                    let slug = uniqueSlug(for: outcome.config, used: &usedSlugs)
                    connections[outcome.config.id] = Connection(
                        config: outcome.config,
                        client: outcome.client,
                        slug: slug,
                        tools: tools
                    )
                    states[outcome.config.id] = .connected(toolCount: tools.count)
                } else {
                    await outcome.client.disconnect()
                    states[outcome.config.id] = .failed(outcome.error ?? "Failed to connect")
                }
            }
        }
    }

    private struct ConnectOutcome: Sendable {
        let config: MCPServerConfig
        let tools: [MCPToolInfo]?
        let error: String?
        let client: MCPClient
    }

    private func route(
        for name: String,
        serverIDs: Set<UUID>
    ) -> (client: MCPClient, toolName: String)? {
        for (id, connection) in connections where serverIDs.contains(id) {
            let prefix = "mcp__\(connection.slug)__"
            guard name.hasPrefix(prefix) else { continue }
            let toolName = String(name.dropFirst(prefix.count))
            if connection.tools.contains(where: { $0.name == toolName }) {
                return (connection.client, toolName)
            }
        }
        return nil
    }

    private func route(
        for name: String,
        serverID: UUID
    ) -> (client: MCPClient, toolName: String)? {
        guard let connection = connections[serverID] else { return nil }
        let prefix = "mcp__\(connection.slug)__"
        guard name.hasPrefix(prefix) else { return nil }
        let toolName = String(name.dropFirst(prefix.count))
        guard connection.tools.contains(where: { $0.name == toolName }) else {
            return nil
        }
        return (connection.client, toolName)
    }

    private func pruneStates(keeping servers: [MCPServerConfig]) {
        let ids = Set(servers.map(\.id))
        states = states.filter { ids.contains($0.key) }
        slugByServerID = slugByServerID.filter { ids.contains($0.key) }
    }

    private static func toolName(slug: String, tool: String) -> String {
        "mcp__\(slug)__\(tool)"
    }

    private static func launchEquivalent(_ lhs: MCPServerConfig, _ rhs: MCPServerConfig) -> Bool {
        lhs.command == rhs.command
            && lhs.arguments == rhs.arguments
            && lhs.environment == rhs.environment
    }

    private static func resolveExecutable(_ command: String, searchPath: String?) -> URL? {
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded)
                ? URL(fileURLWithPath: expanded)
                : nil
        }
        for directory in (searchPath ?? "").split(separator: ":") where !directory.isEmpty {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func childEnvironment(
        searchPath: String?,
        overrides: [String: String]
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let searchPath, !searchPath.isEmpty {
            environment["PATH"] = searchPath
        }
        for (key, value) in overrides {
            environment[key] = value
        }
        return environment
    }

    private static func workingDirectory(for id: String) -> URL? {
        guard let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        return support
            .appendingPathComponent("Nativ", isDirectory: true)
            .appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent(slug(id), isDirectory: true)
    }

    private static func slug(_ raw: String) -> String {
        let characters = raw.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        let joined = String(characters)
        return joined.isEmpty ? "server" : joined
    }

    private func uniqueSlug(for config: MCPServerConfig, used: inout Set<String>) -> String {
        // Reuse a server's previously assigned slug when it's still free, so a
        // reconnect keeps the same slug (and therefore the same tool names).
        if let existing = slugByServerID[config.id], !used.contains(existing) {
            used.insert(existing)
            return existing
        }
        let base = Self.slug(config.name.isEmpty ? config.command : config.name)
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        slugByServerID[config.id] = candidate
        return candidate
    }
}
