import XCTest

final class ChatCapabilitySelectionTests: XCTestCase {
    func testSelectionRoundTripsEveryCapabilitySource() throws {
        let references: Set<ChatCapabilityReference> = [
            .tool(.builtIn("system_stats")),
            .tool(.custom(UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)),
            .skill(UUID(uuidString: "00000000-0000-4000-8000-000000000002")!),
            .mcpServer(UUID(uuidString: "00000000-0000-4000-8000-000000000003")!),
            .extensionPackage("dev.nativ.audio"),
            .kit("engineering"),
        ]
        let selection = ChatCapabilitySelection(included: references)

        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(ChatCapabilitySelection.self, from: data)

        XCTAssertEqual(decoded, selection)
    }

    func testToggleOnlyChangesTheRequestedReference() {
        let tool: ChatCapabilityReference = .tool(.builtIn("system_stats"))
        let skill: ChatCapabilityReference = .skill(UUID())
        var selection = ChatCapabilitySelection(included: [skill])

        selection.toggle(tool)
        XCTAssertEqual(selection.included, [skill, tool])

        selection.toggle(tool)
        XCTAssertEqual(selection.included, [skill])
    }
}
