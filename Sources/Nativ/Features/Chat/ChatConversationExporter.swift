import Foundation

enum ChatConversationExporter {
    static func text(for session: ChatSession) -> String {
        var lines = [session.displayTitle, ""]
        for message in session.messages {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty
                    || !message.imageAttachments.isEmpty
                    || message.toolArguments?.isEmpty == false else {
                continue
            }

            lines.append("\(speaker(for: message)):")
            if let arguments = message.toolArguments,
               !arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Arguments: \(arguments)")
            }
            if !message.imageAttachments.isEmpty {
                let count = message.imageAttachments.count
                lines.append("[\(count) attachment\(count == 1 ? "" : "s")]")
            }
            if !content.isEmpty {
                if message.role == .tool {
                    lines.append("Result:")
                }
                lines.append(content)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func speaker(for message: ChatTranscriptMessage) -> String {
        switch message.role {
        case .user:
            "You"
        case .assistant:
            message.modelID.map { NativFormatting.truncateModelName($0, maxLength: 60) }
                ?? "Assistant"
        case .tool:
            toolName(message.toolName)
        case .error:
            "Error"
        }
    }

    private static func toolName(_ name: String?) -> String {
        switch name {
        case ChatWebSearchToolRegistry.toolName:
            "Web Search"
        case ChatWebReadToolRegistry.toolName:
            "Web Read"
        case ChatImageToolRegistry.generateToolName:
            "Image Generation"
        case ChatImageToolRegistry.editToolName:
            "Image Edit"
        case .some(let name):
            name.split(separator: "_")
                .map { String($0).capitalized }
                .joined(separator: " ")
        case nil:
            "Tool"
        }
    }
}
