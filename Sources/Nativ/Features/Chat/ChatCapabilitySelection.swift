import Foundation

struct ChatToolID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    static func builtIn(_ toolName: String) -> Self {
        Self(rawValue: "builtin:\(toolName)")
    }

    static func custom(_ id: UUID) -> Self {
        Self(rawValue: "custom:\(id.uuidString.lowercased())")
    }
}

enum ChatCapabilityReference: Codable, Hashable, Sendable {
    case tool(ChatToolID)
    case skill(UUID)
    case mcpServer(UUID)
    case extensionPackage(String)
    case kit(String)
}

struct ChatCapabilitySelection: Codable, Equatable, Sendable {
    var included: Set<ChatCapabilityReference>

    static let empty = Self()

    init(included: Set<ChatCapabilityReference> = []) {
        self.included = included
    }

    mutating func toggle(_ reference: ChatCapabilityReference) {
        if included.contains(reference) {
            included.remove(reference)
        } else {
            included.insert(reference)
        }
    }
}
