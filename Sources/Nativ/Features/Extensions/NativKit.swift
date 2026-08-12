import NativServerKit
import SwiftUI

// A Kit is a ready-made setup: a curated bundle of MCP servers, skills, and
// extensions for a role or use-case. It can be selected as one chat capability.

struct NativKit: Identifiable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let tint: Color
    let builtInToolNames: [String]
    let mcpServerIDs: [String]
    let extensionIDs: [String]
    let skills: [NativSkill]

    /// Catalog MCP entries this kit references, in listed order.
    var mcpEntries: [MCPCatalogEntry] {
        mcpServerIDs.compactMap { MCPServerCatalog.bundled.entry(id: $0) }
    }

    var builtInTools: [ChatNativeToolDescriptor] {
        let descriptors = ChatToolRegistry.descriptors(canEditImage: false)
        return builtInToolNames.compactMap { name in
            descriptors.first { $0.definition.function.name == name }
        }
    }

    /// A one-line inventory of what the kit contains.
    var inventory: String {
        var parts: [String] = []
        let tools = builtInToolNames.count
        let servers = mcpEntries.count
        if tools > 0 { parts.append("\(tools) tool\(tools == 1 ? "" : "s")") }
        if servers > 0 { parts.append("\(servers) MCP server\(servers == 1 ? "" : "s")") }
        if !skills.isEmpty { parts.append("\(skills.count) skill\(skills.count == 1 ? "" : "s")") }
        if !extensionIDs.isEmpty { parts.append("\(extensionIDs.count) extension\(extensionIDs.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// The abilities a person gets when every part of this kit is installed.
    var capabilityNames: [String] {
        builtInTools.map { descriptor in
            descriptor.configuration?.displayName ?? descriptor.definition.function.name
        } + mcpEntries.map(\.name) + skills.map(\.name) + extensionIDs
    }
}

private extension NativSkill {
    /// A kit skill with a stable identity so setup never duplicates it.
    static func kit(_ uuid: String, _ name: String, _ instructions: String) -> NativSkill {
        NativSkill(id: UUID(uuidString: uuid)!, name: name, instructions: instructions, isEnabled: true)
    }
}

extension NativKit {
    /// The curated kits shown at the top of the Extensions hub.
    static let all: [NativKit] = [
        NativKit(
            id: "engineering",
            name: "Engineering",
            summary: "Read code, work with Git and GitHub, and pull in docs while you build.",
            symbol: "chevron.left.forwardslash.chevron.right",
            tint: .indigo,
            builtInToolNames: [],
            mcpServerIDs: ["git", "github", "filesystem", "fetch"],
            extensionIDs: [],
            skills: [
                .kit(
                    "A1000000-0000-4000-8000-000000000001",
                    "Working in a codebase",
                    """
                    You're helping with software. Ground every answer in the actual \
                    repository, not assumptions.

                    - Use the Git and filesystem tools to read real files, history, and \
                    diffs before proposing changes; cite concrete paths and symbols.
                    - When you touch GitHub, prefer read-only queries (issues, PRs, code \
                    search) and summarize findings precisely.
                    - Match the project's existing style and conventions. Keep changes \
                    minimal and explain the reasoning.
                    - Fetch documentation when an API or library detail is uncertain \
                    rather than guessing.
                    """
                )
            ]
        ),
        NativKit(
            id: "research",
            name: "Research",
            summary: "Search the web, read primary sources, and synthesize cited findings.",
            symbol: "magnifyingglass",
            tint: .purple,
            builtInToolNames: [
                ChatWebSearchToolRegistry.toolName,
                ChatWebReadToolRegistry.toolName,
            ],
            mcpServerIDs: [],
            extensionIDs: [],
            skills: [.deepResearch]
        ),
    ]
}

// MARK: - Setup

enum NativKitSetupState: Equatable {
    case needsSetup
    case ready
}

@MainActor
enum NativKitSetup {
    static func installMissing(
        kit: NativKit,
        model: NativModel,
        manager: NativExtensionManager
    ) {
        let catalog = MCPServerCatalog.bundled
        var servers = model.settings.mcpServers
        for entry in kit.mcpEntries {
            catalog.setEnabled(true, for: entry, in: &servers)
        }
        model.settings.mcpServers = servers

        for skill in kit.skills where !skill.isChatBuiltIn {
            if !model.settings.skills.contains(where: { $0.id == skill.id }) {
                model.settings.skills.append(skill)
            }
        }

        for extensionID in kit.extensionIDs {
            if !manager.isEnabled(extensionID: extensionID) {
                manager.setEnabled(true, extensionID: extensionID)
            }
        }
    }

    static func state(
        of kit: NativKit,
        model: NativModel,
        manager: NativExtensionManager
    ) -> NativKitSetupState {
        missingPartNames(of: kit, model: model, manager: manager).isEmpty
            ? .ready
            : .needsSetup
    }

    static func missingPartNames(
        of kit: NativKit,
        model: NativModel,
        manager: NativExtensionManager
    ) -> [String] {
        var names: [String] = []

        for entry in kit.mcpEntries
            where matchingServerIndex(for: entry, in: model.settings.mcpServers) == nil {
            names.append(entry.name)
        }
        for skill in kit.skills
            where !skill.isChatBuiltIn
                && !model.settings.skills.contains(where: { $0.id == skill.id }) {
            names.append(skill.name)
        }
        for extensionID in kit.extensionIDs where !manager.isEnabled(extensionID: extensionID) {
            let name = manager.records.first { $0.id == extensionID }?.manifest.displayName ?? extensionID
            names.append(name)
        }

        return names
    }

    /// Matches a catalog entry to a configured server by launch identity
    /// (command + arguments), so a kit never toggles an unrelated server that
    /// merely shares a name.
    private static func matchingServerIndex(
        for entry: MCPCatalogEntry,
        in servers: [MCPServerConfig]
    ) -> Int? {
        servers.firstIndex { $0.command == entry.command && $0.arguments == entry.arguments }
    }
}
