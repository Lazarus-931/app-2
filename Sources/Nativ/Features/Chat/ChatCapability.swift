import Foundation
import NativServerKit

extension ChatCapabilitySelection {
    static func legacySnapshot(settings: NativSettings) -> Self {
        var capabilityIDs = Set<ChatCapabilityID>()

        for descriptor in ChatToolRegistry.descriptors(canEditImage: true) {
            let name = descriptor.definition.function.name
            if !settings.disabledToolNames.contains(name), descriptor.isUserSelectable {
                capabilityIDs.insert(.builtInTool(name))
            }
        }
        for tool in settings.customTools where !settings.disabledToolNames.contains(tool.toolName) {
            capabilityIDs.insert(.customTool(tool.id))
        }
        for skill in settings.skills where skill.isEnabled {
            capabilityIDs.insert(.skill(skill.id))
        }
        for server in settings.mcpServers where server.isEnabled {
            capabilityIDs.insert(.mcpServer(server.id))
        }

        return Self(included: capabilityIDs)
    }
}

enum ChatCapabilityKind: String, Sendable {
    case tool = "Tool"
    case skill = "Skill"
    case connection = "MCP"
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
                reference: .capability(.customTool($0.id)),
                title: $0.name,
                detail: "\(ChatCapabilityKind.tool.rawValue) · Custom",
                kind: .tool,
                systemImage: $0.kind == .script ? "terminal" : "point.3.connected.trianglepath.dotted",
                isAvailable: true
            )
        }
        items += ChatSkillCatalog.skills(overrides: settings.skills).map {
            ChatCapabilityItem(
                reference: .capability(.skill($0.id)),
                title: $0.name.isEmpty ? "Untitled skill" : $0.name,
                detail: ChatCapabilityKind.skill.rawValue,
                kind: .skill,
                systemImage: "sparkles",
                isAvailable: ChatToolRegistry.areConfigured($0.requiredBuiltInToolNames)
            )
        }
        items += settings.mcpServers
            .filter { !$0.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                ChatCapabilityItem(
                    reference: .capability(.mcpServer($0.id)),
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
            let snapshot = kitSnapshot($0, settings: settings)
            return ChatCapabilityItem(
                reference: .kit(snapshot),
                title: $0.name,
                detail: $0.summary,
                kind: .kit,
                systemImage: $0.symbol,
                isAvailable: kitIsAvailable($0, snapshot: snapshot)
            )
        }
    }

    private static func kitSnapshot(
        _ kit: NativKit,
        settings: NativSettings
    ) -> ChatKitSelection {
        var capabilityIDs = Set(kit.builtInToolNames.map(ChatCapabilityID.builtInTool))
        capabilityIDs.formUnion(
            kit.skills.compactMap { skill in
                skill.isChatBuiltIn || settings.skills.contains { $0.id == skill.id }
                    ? ChatCapabilityID.skill(skill.id)
                    : nil
            }
        )
        for entry in kit.mcpEntries {
            guard let server = settings.mcpServers.first(where: {
                $0.command == entry.command && $0.arguments == entry.arguments
            }) else { continue }
            capabilityIDs.insert(.mcpServer(server.id))
        }
        return ChatKitSelection(id: kit.id, capabilityIDs: capabilityIDs)
    }

    private static func kitIsAvailable(
        _ kit: NativKit,
        snapshot: ChatKitSelection
    ) -> Bool {
        let expectedCount = kit.builtInToolNames.count + kit.mcpEntries.count + kit.skills.count
        return kit.extensionIDs.isEmpty
            && snapshot.capabilityIDs.count == expectedCount
            && ChatToolRegistry.areConfigured(Set(kit.builtInToolNames))
    }

    private static var nativeToolItems: [ChatCapabilityItem] {
        ChatToolRegistry.descriptors(canEditImage: false).compactMap { descriptor in
            guard descriptor.isUserSelectable else { return nil }
            let name = descriptor.definition.function.name
            return ChatCapabilityItem(
                reference: .capability(.builtInTool(name)),
                title: descriptor.configuration?.displayName ?? humanized(name),
                detail: "\(ChatCapabilityKind.tool.rawValue) · Built-in",
                kind: .tool,
                systemImage: descriptor.configuration?.systemImage ?? "wrench.and.screwdriver",
                isAvailable: descriptor.configuration?.isConfigured ?? true
            )
        }
    }

    private static func humanized(_ name: String) -> String {
        name.split(separator: "_")
            .map { String($0).capitalized }
            .joined(separator: " ")
    }
}

enum ChatToolExecutionRoute: Equatable {
    case native
    case custom(UUID)
    case mcpServer(UUID)
}

struct ResolvedChatTool {
    let definition: MLXChatToolDefinition
    let route: ChatToolExecutionRoute
}

struct ResolvedChatCapabilities {
    let tools: [ResolvedChatTool]
    let skillInstructions: [String]
    let mcpServerIDs: Set<UUID>

    var toolDefinitions: [MLXChatToolDefinition] {
        tools.map(\.definition)
    }

    var executionRoutes: [String: ChatToolExecutionRoute] {
        Dictionary(
            uniqueKeysWithValues: tools.map {
                ($0.definition.function.name, $0.route)
            }
        )
    }
}

enum ChatCapabilityResolver {
    static func selectedMCPServerIDs(
        selection: ChatCapabilitySelection,
        settings: NativSettings
    ) -> Set<UUID> {
        selectedCapabilityIDs(selection: selection)
            .compactMap(\.mcpServerID)
            .filter { id in settings.mcpServers.contains { $0.id == id } }
            .reduce(into: Set<UUID>()) { $0.insert($1) }
    }

    @MainActor
    static func resolve(
        selection: ChatCapabilitySelection,
        settings: NativSettings,
        mcpHost: MCPHostManager?,
        canEditImage: Bool
    ) -> ResolvedChatCapabilities {
        let capabilityIDs = selectedCapabilityIDs(selection: selection)
        let mcpServerIDs = selectedMCPServerIDs(
            selection: selection,
            settings: settings
        )
        var tools: [ResolvedChatTool] = []
        let configuredSkills = Dictionary(
            ChatSkillCatalog.skills(overrides: settings.skills).map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let selectedSkillIDs = Set(capabilityIDs.compactMap(\.skillID))
        let requiredBuiltInToolNames = selectedSkillIDs.reduce(into: Set<String>()) { result, id in
            guard let toolNames = configuredSkills[id]?.requiredBuiltInToolNames,
                  ChatToolRegistry.areConfigured(toolNames) else { return }
            result.formUnion(toolNames)
        }
        let selectedBuiltInToolNames = Set(capabilityIDs.compactMap(\.builtInToolName))
            .union(requiredBuiltInToolNames)

        for descriptor in ChatToolRegistry.descriptors(canEditImage: canEditImage) {
            guard descriptor.isSelected(by: selectedBuiltInToolNames) else {
                continue
            }
            if let configuration = descriptor.configuration, !configuration.isConfigured {
                continue
            }
            tools.append(ResolvedChatTool(definition: descriptor.definition, route: .native))
        }

        for tool in settings.customTools where capabilityIDs.contains(.customTool(tool.id)) {
            guard let definition = try? tool.definition() else { continue }
            tools.append(ResolvedChatTool(definition: definition, route: .custom(tool.id)))
        }

        if let mcpHost {
            tools += mcpHost.hostedTools(serverIDs: mcpServerIDs).map {
                ResolvedChatTool(
                    definition: $0.definition,
                    route: .mcpServer($0.serverID)
                )
            }
        }

        var skillInstructions: [String] = []
        let orderedSkillIDs = selectedSkillIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        for id in orderedSkillIDs {
            guard let skill = configuredSkills[id],
                  ChatToolRegistry.areConfigured(skill.requiredBuiltInToolNames),
                  !skill.instructions.isEmpty else { continue }
            skillInstructions.append(skill.instructions)
        }

        return ResolvedChatCapabilities(
            tools: deduplicated(tools),
            skillInstructions: skillInstructions,
            mcpServerIDs: mcpServerIDs
        )
    }

    private static func selectedCapabilityIDs(
        selection: ChatCapabilitySelection
    ) -> Set<ChatCapabilityID> {
        selection.effectiveCapabilityIDs
    }

    private static func deduplicated(
        _ tools: [ResolvedChatTool]
    ) -> [ResolvedChatTool] {
        var names = Set<String>()
        return tools.filter { names.insert($0.definition.function.name).inserted }
    }
}
