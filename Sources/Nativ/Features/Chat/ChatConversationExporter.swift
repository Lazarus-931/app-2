import Foundation

enum ChatConversationExporter {
    static func text(for session: ChatSession) -> String {
        var lines = [session.displayTitle]
        let assistantMessages = session.messages.filter { $0.role == .assistant }
        let models = unique(assistantMessages.compactMap(\.modelID))
        if !models.isEmpty {
            lines.append("Models: \(models.joined(separator: ", "))")
        }
        let recordedTotalTokens = assistantMessages.compactMap(\.responseMetrics?.totalTokens)
        let recordedGeneratedTokens = assistantMessages.compactMap(\.responseMetrics?.generatedTokens)
        if !recordedTotalTokens.isEmpty || !recordedGeneratedTokens.isEmpty {
            var usage: [String] = []
            if !recordedTotalTokens.isEmpty {
                usage.append("\(recordedTotalTokens.reduce(0, +)) total tokens")
            }
            if !recordedGeneratedTokens.isEmpty {
                usage.append("\(recordedGeneratedTokens.reduce(0, +)) generated")
            }
            lines.append("Recorded usage: \(usage.joined(separator: " · "))")
        }
        lines.append("")
        for message in session.messages {
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty
                    || !message.imageAttachments.isEmpty
                    || message.toolArguments?.isEmpty == false else {
                continue
            }

            lines.append("\(speaker(for: message)):")
            if let metrics = metricsLine(for: message) {
                lines.append(metrics)
            }
            if let thinkingDuration = message.thinkingDuration {
                lines.append("Thinking: \(decimal(thinkingDuration)) s")
            }
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

    private static func metricsLine(for message: ChatTranscriptMessage) -> String? {
        guard let metrics = message.responseMetrics else { return nil }
        var values: [String] = []
        if let totalTokens = metrics.totalTokens {
            values.append("\(totalTokens) total tokens")
        }
        if let generatedTokens = metrics.generatedTokens {
            values.append("\(generatedTokens) generated")
        }
        if let decodeTokensPerSecond = metrics.decodeTokensPerSecond {
            values.append("\(decimal(decodeTokensPerSecond)) tok/s")
        }
        if let peakMemoryGB = metrics.peakMemoryGB {
            values.append("\(decimal(peakMemoryGB)) GB peak memory")
        }
        if let specAcceptanceRate = metrics.specAcceptanceRate {
            values.append("\(decimal(specAcceptanceRate * 100))% draft acceptance")
        }
        return values.isEmpty ? nil : "Metrics: \(values.joined(separator: " · "))"
    }

    private static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0 ... 2)))
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
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
