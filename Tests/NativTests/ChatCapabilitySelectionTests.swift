import XCTest

final class ChatCapabilitySelectionTests: XCTestCase {
    func testSelectionRoundTripsStableCapabilityIDsAndKitSnapshot() throws {
        let customToolID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let skillID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let serverID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        let kit = ChatKitSelection(
            id: "engineering",
            capabilityIDs: [.skill(skillID), .mcpServer(serverID)]
        )
        let selection = ChatCapabilitySelection(
            included: [
                .builtInTool("system_stats"),
                .customTool(customToolID),
            ],
            kits: [kit]
        )

        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(ChatCapabilitySelection.self, from: data)

        XCTAssertEqual(decoded, selection)
        XCTAssertEqual(
            decoded.effectiveCapabilityIDs,
            selection.included.union(kit.capabilityIDs)
        )
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("tool:built-in:system_stats"))
    }

    func testUnknownCapabilityIDDoesNotBreakSelectionDecoding() throws {
        let data = Data(#"{"included":["future-provider:search"],"kits":[]}"#.utf8)
        let selection = try JSONDecoder().decode(ChatCapabilitySelection.self, from: data)

        XCTAssertEqual(
            selection.included,
            [ChatCapabilityID(rawValue: "future-provider:search")]
        )
    }

    func testToggleOnlyChangesTheRequestedDirectCapability() {
        let tool = ChatCapabilityReference.capability(.builtInTool("system_stats"))
        let skillID = ChatCapabilityID.skill(UUID())
        var selection = ChatCapabilitySelection(included: [skillID])

        selection.toggle(tool)
        XCTAssertEqual(selection.included, [skillID, .builtInTool("system_stats")])

        selection.toggle(tool)
        XCTAssertEqual(selection.included, [skillID])
    }

    func testKitSelectionKeepsItsOriginalCapabilitySnapshot() {
        let original = ChatKitSelection(
            id: "research",
            capabilityIDs: [.builtInTool("web_search")]
        )
        let updatedCatalogVersion = ChatKitSelection(
            id: "research",
            capabilityIDs: [
                .builtInTool("web_search"),
                .builtInTool("get_system_stats"),
            ]
        )
        var selection = ChatCapabilitySelection()

        selection.toggle(.kit(original))

        XCTAssertTrue(selection.contains(.kit(updatedCatalogVersion)))
        XCTAssertEqual(selection.effectiveCapabilityIDs, original.capabilityIDs)

        selection.toggle(.kit(updatedCatalogVersion))
        XCTAssertTrue(selection.kits.isEmpty)
    }

    func testResearchKitUsesNativeBrowsing() throws {
        let research = try XCTUnwrap(NativKit.all.first { $0.id == "research" })

        XCTAssertEqual(
            Set(research.builtInToolNames),
            [ChatWebSearchToolRegistry.toolName, ChatWebReadToolRegistry.toolName]
        )
        XCTAssertTrue(research.mcpServerIDs.isEmpty)
        XCTAssertEqual(research.skills.map(\.name), ["Deep Research"])
        XCTAssertEqual(research.skills[0].requiredBuiltInToolNames, Set(research.builtInToolNames))
    }

    func testSettingsUpgradeOnlyTheUneditedLegacyResearchSkill() {
        let legacyInstructions = """
        You're doing careful research. Prioritize accuracy and traceability.

        - Use the fetch tool to read primary sources; quote or paraphrase with a link back to where \
        each claim came from.
        - Record durable findings in the memory tool so they carry across the conversation, and \
        recall them before re-fetching.
        - Query the SQLite tool for anything in the user's own dataset instead of estimating.
        - Separate what the sources say from your own inference, and flag uncertainty plainly.
        """
        let legacy = NativSkill(
            id: NativSkill.deepResearchID,
            name: "Researching with sources",
            instructions: legacyInstructions,
            isEnabled: false
        )
        var edited = legacy
        edited.instructions += "\nKeep my custom instructions."

        let normalized = NativSettings(skills: [legacy, edited]).normalized()

        XCTAssertEqual(normalized.skills[0].name, NativSkill.deepResearch.name)
        XCTAssertEqual(normalized.skills[0].instructions, NativSkill.deepResearch.instructions)
        XCTAssertFalse(normalized.skills[0].isEnabled)
        XCTAssertEqual(normalized.skills[1], edited)
    }

    @MainActor
    func testResolverUsesOneRouteForEachAdvertisedTool() {
        let selectedName = ChatSystemMonitorToolRegistry.toolName
        let selection = ChatCapabilitySelection(
            included: [.builtInTool(selectedName)]
        )

        let resolved = ChatCapabilityResolver.resolve(
            selection: selection,
            settings: NativSettings(),
            mcpHost: nil,
            canEditImage: false
        )

        XCTAssertEqual(
            resolved.executionRoutes[selectedName],
            .native
        )
        XCTAssertNil(
            resolved.executionRoutes[ChatModelLibraryToolRegistry.toolName]
        )
        XCTAssertEqual(
            Set(resolved.toolDefinitions.map(\.function.name)),
            Set(resolved.executionRoutes.keys)
        )
    }
}
