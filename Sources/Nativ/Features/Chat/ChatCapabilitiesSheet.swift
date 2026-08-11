import SwiftUI

struct ChatCapabilitiesSheet: View {
    @ObservedObject var model: NativModel
    @ObservedObject var chat: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var items: [ChatCapabilityItem] {
        let all = ChatCapabilityCatalog.items(settings: model.settings)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.title.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add to chat")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                NativHoverCloseButton { dismiss() }
            }

            TextField("Search capabilities", text: $query)
                .textFieldStyle(.roundedBorder)

            ScrollView {
                LazyVStack(spacing: 0) {
                    if items.isEmpty {
                        Text(query.isEmpty ? "No capabilities are available." : "No matching capabilities.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 44)
                    } else {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            capabilityRow(item)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 520)
    }

    private func capabilityRow(_ item: ChatCapabilityItem) -> some View {
        Button {
            chat.toggleCapability(item.reference)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(item.isAvailable ? item.detail : "\(item.detail) · Needs setup")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if chat.isCapabilitySelected(item.reference) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!item.isAvailable)
    }
}

struct ChatKitsPickerSheet: View {
    @ObservedObject var model: NativModel
    @ObservedObject var chat: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Kits")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                NativHoverCloseButton { dismiss() }
            }

            Text("Add a ready-made set of capabilities to this chat.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                ForEach(
                    Array(ChatCapabilityCatalog.kits(settings: model.settings).enumerated()),
                    id: \.element.id
                ) { index, kit in
                    if index > 0 { Divider() }
                    Button {
                        chat.toggleCapability(kit.reference)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: kit.systemImage)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(kit.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(kit.isAvailable ? kit.detail : "\(kit.detail) · Set up in Extensions")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 12)
                            if chat.isCapabilitySelected(kit.reference) {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.vertical, 12)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!kit.isAvailable)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
