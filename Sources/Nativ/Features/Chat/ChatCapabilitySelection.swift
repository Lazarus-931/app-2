import Foundation

struct ChatCapabilityID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func builtInTool(_ toolName: String) -> Self {
        Self(rawValue: "tool:built-in:\(toolName)")
    }

    static func customTool(_ id: UUID) -> Self {
        Self(rawValue: "tool:custom:\(id.uuidString.lowercased())")
    }

    static func skill(_ id: UUID) -> Self {
        Self(rawValue: "skill:\(id.uuidString.lowercased())")
    }

    static func mcpServer(_ id: UUID) -> Self {
        Self(rawValue: "mcp:\(id.uuidString.lowercased())")
    }

    var builtInToolName: String? {
        value(after: "tool:built-in:")
    }

    var customToolID: UUID? {
        uuid(after: "tool:custom:")
    }

    var skillID: UUID? {
        uuid(after: "skill:")
    }

    var mcpServerID: UUID? {
        uuid(after: "mcp:")
    }

    private func value(after prefix: String) -> String? {
        guard rawValue.hasPrefix(prefix) else { return nil }
        let value = String(rawValue.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    private func uuid(after prefix: String) -> UUID? {
        value(after: prefix).flatMap(UUID.init(uuidString:))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ChatKitSelection: Codable, Equatable, Hashable, Sendable {
    let id: String
    let capabilityIDs: Set<ChatCapabilityID>

    init(id: String, capabilityIDs: Set<ChatCapabilityID>) {
        self.id = id
        self.capabilityIDs = capabilityIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case capabilityIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        capabilityIDs = Set(
            try container.decodeIfPresent([ChatCapabilityID].self, forKey: .capabilityIDs) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(
            capabilityIDs.sorted { $0.rawValue < $1.rawValue },
            forKey: .capabilityIDs
        )
    }
}

enum ChatCapabilityReference: Hashable, Sendable {
    case capability(ChatCapabilityID)
    case kit(ChatKitSelection)
}

struct ChatCapabilitySelection: Codable, Equatable, Sendable {
    var included: Set<ChatCapabilityID>
    var kits: [ChatKitSelection]

    static let empty = Self()

    init(
        included: Set<ChatCapabilityID> = [],
        kits: [ChatKitSelection] = []
    ) {
        self.included = included
        self.kits = Self.deduplicatedKits(kits)
    }

    var effectiveCapabilityIDs: Set<ChatCapabilityID> {
        kits.reduce(into: included) { result, kit in
            result.formUnion(kit.capabilityIDs)
        }
    }

    func contains(_ reference: ChatCapabilityReference) -> Bool {
        switch reference {
        case .capability(let id):
            included.contains(id)
        case .kit(let kit):
            kits.contains { $0.id == kit.id }
        }
    }

    mutating func toggle(_ reference: ChatCapabilityReference) {
        switch reference {
        case .capability(let id):
            if included.contains(id) {
                included.remove(id)
            } else {
                included.insert(id)
            }
        case .kit(let kit):
            if let index = kits.firstIndex(where: { $0.id == kit.id }) {
                kits.remove(at: index)
            } else {
                kits.append(kit)
                kits.sort { $0.id < $1.id }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case included
        case kits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        included = Set(
            try container.decodeIfPresent([ChatCapabilityID].self, forKey: .included) ?? []
        )
        kits = Self.deduplicatedKits(
            try container.decodeIfPresent([ChatKitSelection].self, forKey: .kits) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            included.sorted { $0.rawValue < $1.rawValue },
            forKey: .included
        )
        try container.encode(kits.sorted { $0.id < $1.id }, forKey: .kits)
    }

    private static func deduplicatedKits(
        _ kits: [ChatKitSelection]
    ) -> [ChatKitSelection] {
        var seen = Set<String>()
        return kits
            .sorted { $0.id < $1.id }
            .filter { seen.insert($0.id).inserted }
    }
}
