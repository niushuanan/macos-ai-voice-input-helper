import Combine
import SwiftUI

private let mailAddressBookDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter
}()

enum MailAddressBookPanelOutcome: Equatable {
    case none
    case validationFailed(String)
    case created(String)
    case updated(String)
    case deleted(String)

    var toastText: String? {
        switch self {
        case .none:
            return nil
        case let .validationFailed(message),
            let .created(message),
            let .updated(message),
            let .deleted(message):
            return message
        }
    }
}

@MainActor
final class MailAddressBookPanelModel: ObservableObject {
    @Published var searchQuery = ""
    @Published private(set) var selectedEntryID: UUID?
    @Published private(set) var isCreatingEntry = false
    @Published var displayNameDraft = ""
    @Published var emailDraft = ""
    @Published var aliasesDraft = ""
    @Published var noteDraft = ""

    let store: MailAddressBookStore
    private var cancellables = Set<AnyCancellable>()

    init(store: MailAddressBookStore) {
        self.store = store

        store.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        if let first = store.entries.first {
            select(first)
        } else {
            beginCreate()
        }
    }

    var filteredEntries: [MailAddressBookEntry] {
        let query = MailAddressBookStore.normalizedLookupKey(searchQuery)
        guard !query.isEmpty else {
            return store.entries
        }
        return store.entries.filter { entry in
            let haystack = [
                entry.displayName,
                entry.email,
                entry.note
            ] + entry.aliases
            return haystack.contains {
                MailAddressBookStore.normalizedLookupKey($0).contains(query)
            }
        }
    }

    var aliasPreview: [String] {
        MailAddressBookStore.normalizeAliases(from: aliasesDraft)
    }

    var selectedEntry: MailAddressBookEntry? {
        guard let selectedEntryID else {
            return nil
        }
        return store.entries.first(where: { $0.id == selectedEntryID })
    }

    func beginCreate() {
        isCreatingEntry = true
        selectedEntryID = nil
        displayNameDraft = ""
        emailDraft = ""
        aliasesDraft = ""
        noteDraft = ""
    }

    func select(_ entry: MailAddressBookEntry) {
        isCreatingEntry = false
        selectedEntryID = entry.id
        displayNameDraft = entry.displayName
        emailDraft = entry.email
        aliasesDraft = entry.aliases.joined(separator: ", ")
        noteDraft = entry.note
    }

    func saveDraft() -> MailAddressBookPanelOutcome {
        let displayName = displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = emailDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasCreatingEntry = isCreatingEntry

        guard !displayName.isEmpty else {
            return .validationFailed("请先填写显示名。")
        }
        guard isValidEmail(email) else {
            return .validationFailed("请填写完整邮箱地址。")
        }

        let entry = store.save(
            id: selectedEntryID,
            displayName: displayName,
            email: email,
            aliases: MailAddressBookStore.normalizeAliases(from: aliasesDraft),
            note: noteDraft
        )
        select(entry)

        if wasCreatingEntry {
            return .created("已加入邮箱名库。")
        }
        return .updated("邮箱名库已更新。")
    }

    func deleteSelected() -> MailAddressBookPanelOutcome {
        guard let entry = selectedEntry else {
            return .none
        }
        store.delete(id: entry.id)
        if let first = store.entries.first {
            select(first)
        } else {
            beginCreate()
        }
        return .deleted("已删除 \(entry.displayName)。")
    }

    private func isValidEmail(_ value: String) -> Bool {
        Self.emailRegex.firstMatch(
            in: value,
            options: [],
            range: NSRange(location: 0, length: (value as NSString).length)
        ) != nil
    }

    private static let emailRegex = try! NSRegularExpression(
        pattern: #"^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#,
        options: [.caseInsensitive]
    )
}

struct MailAddressBookManagementSheetView: View {
    @ObservedObject var model: MailAddressBookPanelModel
    let onOutcome: (MailAddressBookPanelOutcome) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            HStack(alignment: .top, spacing: 18) {
                listColumn
                    .frame(width: 300)

                editorColumn
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(24)
        .frame(width: 940, height: 560)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.96),
                    Color(nsColor: .windowBackgroundColor).opacity(0.94)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                Image(systemName: "tray.full")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 5) {
                Text("邮箱名库")
                    .font(.title2.weight(.bold))
                Text("系统会先查名库，再在必要时用文本模型推断新地址。地址不够明确时，只打开 Mail 编辑窗口，不会直接发送。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("完成") {
                onClose()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label("联系人", systemImage: "person.2")
                    .font(.headline)
                Spacer()
                Button {
                    model.beginCreate()
                } label: {
                    Label("新增", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("查名字、邮箱或别名", text: $model.searchQuery)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.72))
            )

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.filteredEntries) { entry in
                        Button {
                            model.select(entry)
                        } label: {
                            MailAddressBookEntryRow(
                                entry: entry,
                                isSelected: model.selectedEntryID == entry.id
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .pulseCard(cornerRadius: 18)
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.isCreatingEntry ? "新增联系人" : "编辑联系人")
                        .font(.headline)
                    Text("支持昵称、数字片段和常用别名。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let entry = model.selectedEntry {
                    Text(entry.lastUsedAt.map(mailAddressBookDateFormatter.string(from:)) ?? "未使用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                MailAddressBookField(title: "显示名", text: $model.displayNameDraft, placeholder: "例如：小庄")
                MailAddressBookField(title: "完整邮箱", text: $model.emailDraft, placeholder: "name@example.com")
                MailAddressBookField(title: "别名", text: $model.aliasesDraft, placeholder: "逗号分隔，例如：小庄, 1379804870, 谷歌邮箱")

                VStack(alignment: .leading, spacing: 6) {
                    Text("备注")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $model.noteDraft)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white.opacity(0.76))
                        )
                }
            }

            if !model.aliasPreview.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("别名预览")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    FlowTagList(tags: model.aliasPreview)
                }
            }

            Spacer()

            HStack {
                Button("删除") {
                    onOutcome(model.deleteSelected())
                }
                .buttonStyle(.bordered)
                .disabled(model.selectedEntry == nil || model.isCreatingEntry)

                Spacer()

                Button("新建空白") {
                    model.beginCreate()
                }
                .buttonStyle(.bordered)

                Button("保存") {
                    onOutcome(model.saveDraft())
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .pulseCard(cornerRadius: 18)
    }

}

private struct MailAddressBookEntryRow: View {
    let entry: MailAddressBookEntry
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.displayName)
                    .font(.headline)
                Spacer()
                if let lastUsedAt = entry.lastUsedAt {
                    Text(mailAddressBookDateFormatter.string(from: lastUsedAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Text(entry.email)
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.82))

            if !entry.aliases.isEmpty {
                Text(entry.aliases.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.78), lineWidth: 1)
        )
    }
}

private struct MailAddressBookField: View {
    let title: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.76))
                )
        }
    }
}

private struct FlowTagList: View {
    let tags: [String]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 84), alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                    )
            }
        }
    }
}
