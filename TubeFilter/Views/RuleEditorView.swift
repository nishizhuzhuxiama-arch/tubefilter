import SwiftUI

// MARK: - 规则编辑器

/// 通用规则编辑器。四类规则共用同一套增删改界面，只是匹配方式与提示不同。
struct RuleEditorView: View {

    let kind: RuleKind

    @EnvironmentObject private var store: SettingsStore

    @State private var showEditor = false
    @State private var editingRule: BlockRule?
    @State private var keywordFilter = ""

    private var rules: [BlockRule] {
        let list = store.settings.rules(of: kind)
        let keyword = keywordFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = keyword.isEmpty
            ? list
            : list.filter { $0.pattern.localizedCaseInsensitiveContains(keyword) || $0.note.localizedCaseInsensitiveContains(keyword) }
        return filtered.sorted { lhs, rhs in
            if lhs.hitCount != rhs.hitCount { return lhs.hitCount > rhs.hitCount }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private var totalHits: Int {
        store.settings.rules(of: kind).reduce(0) { $0 + $1.hitCount }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if rules.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(rules) { rule in
                        Button(action: {
                            editingRule = rule
                            showEditor = true
                        }) {
                            RuleRow(rule: rule)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                    .onDelete(perform: delete)
                }
                .listStyle(PlainListStyle())
            }
        }
        .navigationBarTitle(kind.title, displayMode: .inline)
        .navigationBarItems(trailing: addButton)
        .sheet(isPresented: $showEditor) {
            RuleEditSheet(kind: kind, existing: editingRule) { rule in
                if editingRule == nil {
                    store.addRule(rule)
                } else {
                    store.updateRule(rule)
                }
                editingRule = nil
            }
            .environmentObject(store)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind.subtitle)
                .font(.footnote)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Label("\(store.settings.rules(of: kind).count) 条规则", systemImage: "list.bullet")
                Label("累计命中 \(totalHits)", systemImage: "target")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            TextField("在规则里筛选", text: $keywordFilter)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .font(.footnote)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.tfSurface)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("还没有\(kind.title)规则")
                .font(.headline)
            Text("点右上角加号添加。\(kind.subtitle)")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addButton: some View {
        Button(action: {
            editingRule = nil
            showEditor = true
        }) {
            Image(systemName: "plus")
        }
    }

    private func delete(at offsets: IndexSet) {
        let ordered = rules
        var ids: [UUID] = []
        for index in offsets where index < ordered.count {
            ids.append(ordered[index].id)
        }
        for id in ids {
            store.removeRule(id: id)
        }
    }
}

// MARK: - 规则行

struct RuleRow: View {

    let rule: BlockRule

    @EnvironmentObject private var store: SettingsStore

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button(action: { store.toggleRule(id: rule.id) }) {
                Image(systemName: rule.enabled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(rule.enabled ? .green : .secondary)
            }
            .buttonStyle(PlainButtonStyle())

            VStack(alignment: .leading, spacing: 3) {
                Text(rule.pattern)
                    .font(.subheadline)
                    .foregroundColor(rule.enabled ? .primary : .secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    tag(rule.matchMode.title)
                    if rule.caseSensitive {
                        tag("区分大小写")
                    }
                    if rule.hitCount > 0 {
                        Text("命中 \(rule.hitCount)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                if !rule.note.isEmpty {
                    Text(rule.note)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if !rule.regexIsValid {
                    Label("正则语法错误，规则暂不生效", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.tfSurfaceElevated)
            .cornerRadius(4)
    }
}

// MARK: - 新增 / 编辑

struct RuleEditSheet: View {

    let kind: RuleKind
    let existing: BlockRule?
    var onCommit: (BlockRule) -> Void

    @Environment(\.presentationMode) private var presentationMode

    @State private var pattern: String = ""
    @State private var mode: MatchMode
    @State private var caseSensitive: Bool = false
    @State private var note: String = ""
    @State private var enabled: Bool = true
    @State private var sampleText: String = ""

    init(kind: RuleKind, existing: BlockRule?, onCommit: @escaping (BlockRule) -> Void) {
        self.kind = kind
        self.existing = existing
        self.onCommit = onCommit
        _mode = State(initialValue: existing?.matchMode ?? kind.defaultMode)
        _pattern = State(initialValue: existing?.pattern ?? "")
        _caseSensitive = State(initialValue: existing?.caseSensitive ?? false)
        _note = State(initialValue: existing?.note ?? "")
        _enabled = State(initialValue: existing?.enabled ?? true)
    }

    private var trimmedPattern: String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCommit: Bool {
        !trimmedPattern.isEmpty && syntaxIsValid
    }

    private var syntaxIsValid: Bool {
        guard mode == .regex else { return true }
        return (try? NSRegularExpression(pattern: trimmedPattern)) != nil
    }

    /// 试算结果：把当前模式与关键词直接套到示例文本上。
    private var sampleResult: String? {
        let sample = sampleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sample.isEmpty, !trimmedPattern.isEmpty, syntaxIsValid else { return nil }

        switch mode {
        case .literal:
            let haystack = caseSensitive ? sample : sample.lowercased()
            let needle = caseSensitive ? trimmedPattern : trimmedPattern.lowercased()
            return haystack.contains(needle) ? "命中" : "未命中"
        case .regex:
            var options: NSRegularExpression.Options = []
            if !caseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: trimmedPattern, options: options) else { return nil }
            let range = NSRange(sample.startIndex..<sample.endIndex, in: sample)
            if let match = regex.firstMatch(in: sample, options: [], range: range) {
                return "命中「\((sample as NSString).substring(with: match.range))」"
            }
            return "未命中"
        case .similarity:
            let result = SemanticVectorizer.shared.similarity(sample, trimmedPattern)
            let threshold = SemanticVectorizer.shared.effectiveThreshold(
                base: currentSemanticThreshold,
                space: result.space
            )
            let score = Int((result.score * 100).rounded())
            let limit = Int((threshold * 100).rounded())
            let space = result.space == .embedding ? "系统句向量" : "本地 n-gram"
            return "相似度 \(score)% / 阈值 \(limit)%（\(space)）→ \(result.score >= threshold ? "命中" : "未命中")"
        }
    }

    private var currentSemanticThreshold: Double {
        store.settings.filter.semanticThreshold
    }

    var body: some View {
        NavigationView {
            Form {
                Section(
                    header: Text(kind.title),
                    footer: Text(kind.subtitle)
                ) {
                    TextField(placeholder, text: $pattern)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    if !syntaxIsValid {
                        Label("正则语法错误", systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                if kind.allowedModes.count > 1 {
                    Section(header: Text("匹配方式")) {
                        Picker("匹配方式", selection: $mode) {
                            ForEach(kind.allowedModes) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                    }
                }

                Section(header: Text("附加条件")) {
                    if mode != .similarity {
                        Toggle("区分大小写", isOn: $caseSensitive)
                    }
                    Toggle("启用这条规则", isOn: $enabled)
                }

                Section(header: Text("备注")) {
                    TextField("可选，写给自己看", text: $note)
                }

                Section(
                    header: Text("试算"),
                    footer: Text("填一段示例文本，立即看到这条规则会不会命中，避免写完规则才发现写错。")
                ) {
                    TextField("示例标题或频道名", text: $sampleText)
                    if let result = sampleResult {
                        Text(result)
                            .font(.footnote)
                            .foregroundColor(result.contains("未命中") ? .secondary : .green)
                    }
                }

                if existing != nil {
                    Section {
                        Text("已累计命中 \(existing?.hitCount ?? 0) 次")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationBarTitle(existing == nil ? "新增\(kind.title)" : "编辑\(kind.title)", displayMode: .inline)
            .navigationBarItems(
                leading: Button("取消") { presentationMode.wrappedValue.dismiss() },
                trailing: Button("保存") { commit() }
                    .disabled(!canCommit)
            )
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private var placeholder: String {
        switch mode {
        case .literal: return "要屏蔽的文本"
        case .regex: return "正则表达式，例如 震惊|必看"
        case .similarity: return "参照短语，语义相近即命中"
        }
    }

    private func commit() {
        guard canCommit else { return }
        let rule = BlockRule(
            id: existing?.id ?? UUID(),
            kind: kind,
            pattern: trimmedPattern,
            matchMode: mode,
            caseSensitive: caseSensitive,
            enabled: enabled,
            note: note,
            createdAt: existing?.createdAt ?? Date(),
            hitCount: existing?.hitCount ?? 0
        )
        onCommit(rule)
        presentationMode.wrappedValue.dismiss()
    }
}
