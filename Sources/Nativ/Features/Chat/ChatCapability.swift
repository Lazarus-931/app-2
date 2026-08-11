import Foundation
import NativServerKit

extension ChatCapabilitySelection {
    static func legacySnapshot(settings: NativSettings) -> Self {
        var references = Set<ChatCapabilityReference>()

        for descriptor in ChatToolRegistry.descriptors(canEditImage: true) {
            let name = descriptor.definition.function.name
            if !settings.disabledToolNames.contains(name), !descriptor.isAutomatic {
                references.insert(.tool(.builtIn(name)))
            }
        }
        for tool in settings.customTools where !settings.disabledToolNames.contains(tool.toolName) {
            references.insert(.tool(.custom(tool.id)))
        }
        for skill in settings.skills where skill.isEnabled {
            references.insert(.skill(skill.id))
        }
        for server in settings.mcpServers where server.isEnabled {
            references.insert(.mcpServer(server.id))
        }

        return Self(included: references)
    }
}

enum ChatCapabilityKind: String, Sendable {
    case tool = "Tool"
    case skill = "Skill"
    case connection = "MCP"
    case extensionPackage = "Extension"
    case kit = "Kit"
}

struct ChatCapabilityItem: Identifiable, Sendable {
    let reference: ChatCapabilityReference
    let title: String
    let detail: String
    let kind: ChatCapabilityKind
    let systemImage: String
    let isAvailable: Bool

    var id: ChatCapabilityReference { reference }
}

enum ChatCapabilityCatalog {
    static func items(settings: NativSettings) -> [ChatCapabilityItem] {
        var items = nativeToolItems
        items += settings.customTools.map {
            ChatCapabilityItem(
                reference: .tool(.custom($0.id)),
                title: $0.name,
                detail: "\(ChatCapabilityKind.tool.rawValue) · Custom",
                kind: .tool,
                systemImage: $0.kind == .script ? "terminal" : "point.3.connected.trianglepath.dotted",
                isAvailable: true
            )
        }
        items += settings.skills.map {
            ChatCapabilityItem(
                reference: .skill($0.id),
                title: $0.name.isEmpty ? "Untitled skill" : $0.name,
                detail: ChatCapabilityKind.skill.rawValue,
                kind: .skill,
                systemImage: "sparkles",
                isAvailable: true
            )
        }
        items += settings.mcpServers
            .filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                ChatCapabilityItem(
                    reference: .mcpServer($0.id),
                    title: $0.name.isEmpty ? "Untitled server" : $0.name,
                    detail: "MCP connection",
                    kind: .connection,
                    systemImage: "server.rack",
                    isAvailable: true
                )
            }

        return items.sorted {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    static func kits(settings: NativSettings) -> [ChatCapabilityItem] {
        NativKit.all.map {
            ChatCapabilityItem(
                reference: .kit($0.id),
                title: $0.name,
                detail: $0.summary,
                kind: .kit,
                systemImage: $0.symbol,
                isAvailable: kitIsInstalled($0, settings: settings)
            )
        }
    }

    private static func kitIsInstalled(_ kit: NativKit, settings: NativSettings) -> Bool {
        let hasServers = kit.mcpEntries.allSatisfy { entry in
            settings.mcpServers.contains {
                $0.command == entry.command && $0.arguments == entry.arguments
            }
        }
        let hasSkills = kit.skills.allSatisfy { skill in
            settings.skills.contains { $0.id == skill.id }
        }
        return hasServers && hasSkills
    }

    private static var nativeToolItems: [ChatCapabilityItem] {
        ChatToolRegistry.descriptors(canEditImage: false).compactMap { descriptor in
            guard !descriptor.isAutomatic else { return nil }
            let name = descriptor.definition.function.name
            return ChatCapabilityItem(
                reference: .tool(.builtIn(name)),
                title: descriptor.configuration?.displayName ?? humanized(name),
                detail: "\(ChatCapabilityKind.tool.rawValue) · Built-in",
                kind: .tool,
                systemImage: descriptor.configuration == .webSearch ? "globe" : "wrench.and.screwdriver",
                isAvailable: descriptor.configuration != .webSearch || ChatWebSearchToolRegistry.isConfigured()
            )
        }
    }

    private static func humanized(_ name: String) -> String {
        name.split(separator: "_")
            .map { String($0).capitalized }
            .joined(separator: " ")
    }
}

struct ResolvedChatCapabilities {
    let toolDefinitions: [MLXChatToolDefinition]
    let skillInstructions: [String]
    let mcpServerIDs: Set<UUID>
    let extensionPackageIDs: Set<String>
}

enum ChatCapabilityResolver {
    static func selectedMCPServerIDs(
        selection: ChatCapabilitySelection,
        settings: NativSettings
    ) -> Set<UUID> {
        expanded(selection: selection, settings: settings).mcpServerIDs
    }

    @MainActor
    static func resolve(
        selection: ChatCapabilitySelection,
        settings: NativSettings,
        mcpHost: MCPHostManager?,
        canEditImage: Bool
    ) -> ResolvedChatCapabilities {
        let expansion = expanded(selection: selection, settings: settings)
        var definitions: [MLXChatToolDefinition] = []

        for descriptor in ChatToolRegistry.descriptors(canEditImage: canEditImage) {
            let name = descriptor.definition.function.name
            let id = ChatToolID.builtIn(name)
            guard descriptor.isAutomatic || expansion.toolIDs.contains(id) else { continue }
            if descriptor.configuration == .webSearch, !ChatWebSearchToolRegistry.isConfigured() {
                continue
            }
            definitions.append(descriptor.definition)
        }

        for tool in settings.customTools where expansion.toolIDs.contains(.custom(tool.id)) {
            guard let definition = try? tool.definition() else { continue }
            definitions.append(definition)
        }

        if let mcpHost {
            let mcpDefinitions = mcpHost.toolDefinitions(serverIDs: expansion.mcpServerIDs)
            definitions += mcpDefinitions
        }

        var skillInstructions: [String] = []
        var seenSkillIDs = Set<UUID>()
        let kitSkills = Dictionary(
            NativKit.all.flatMap(\.skills).map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let configuredSkills = Dictionary(
            settings.skills.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let orderedSkillIDs = expansion.skillIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        for id in orderedSkillIDs where seenSkillIDs.insert(id).inserted {
            let instructions = configuredSkills[id]?.instructions ?? kitSkills[id]?.instructions
            if let instructions, !instructions.isEmpty {
                skillInstructions.append(instructions)
            }
        }

        return ResolvedChatCapabilities(
            toolDefinitions: deduplicated(definitions),
            skillInstructions: skillInstructions,
            mcpServerIDs: expansion.mcpServerIDs,
            extensionPackageIDs: expansion.extensionPackageIDs
        )
    }

    private struct Expansion {
        var toolIDs = Set<ChatToolID>()
        var skillIDs = Set<UUID>()
        var mcpServerIDs = Set<UUID>()
        var extensionPackageIDs = Set<String>()
    }

    private static func expanded(
        selection: ChatCapabilitySelection,
        settings: NativSettings
    ) -> Expansion {
        var result = Expansion()

        for reference in selection.included {
            switch reference {
            case .tool(let id):
                result.toolIDs.insert(id)
            case .skill(let id):
                result.skillIDs.insert(id)
            case .mcpServer(let id):
                if settings.mcpServers.contains(where: { $0.id == id }) {
                    result.mcpServerIDs.insert(id)
                }
            case .extensionPackage(let id):
                result.extensionPackageIDs.insert(id)
            case .kit(let id):
                guard let kit = NativKit.all.first(where: { $0.id == id }) else { continue }
                result.skillIDs.formUnion(kit.skills.map(\.id))
                result.extensionPackageIDs.formUnion(kit.extensionIDs)
                for entry in kit.mcpEntries {
                    guard let server = settings.mcpServers.first(where: {
                        $0.command == entry.command && $0.arguments == entry.arguments
                    }) else { continue }
                    result.mcpServerIDs.insert(server.id)
                }
            }
        }

        return result
    }

    private static func deduplicated(
        _ definitions: [MLXChatToolDefinition]
    ) -> [MLXChatToolDefinition] {
        var names = Set<String>()
        return definitions.filter { names.insert($0.function.name).inserted }
    }
}
