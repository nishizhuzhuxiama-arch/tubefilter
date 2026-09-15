import SwiftUI

// MARK: - 过滤统计

struct FilterStatsView: View {

    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var browser: BrowserController

    var body: some View {
        List {
            Section(header: Text("总体")) {
                statRow("累计扫描内容", "\(store.stats.totalScanned)")
                statRow("累计屏蔽", "\(store.stats.totalBlocked)")
                statRow("屏蔽率", rateText)
                statRow("本次会话屏蔽", "\(browser.sessionBlocked)")
                statRow("扫描轮次", "\(browser.scanCount)")
                statRow("最近一次扫描", "\(browser.lastScanTotal) 条中挡下 \(browser.lastScanBlocked) 条")
            }

            Section(
                header: Text("按原因分布"),
                footer: Text("命中次数最多的原因排在前面，可以据此判断哪类规则在起主要作用。")
            ) {
                if store.stats.rankedReasons.isEmpty {
                    Text("还没有命中记录")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.stats.rankedReasons, id: \.reason) { entry in
                        HStack {
                            Text(entry.reason.title)
                            Spacer()
                            Text("\(entry.count)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section(
                header: Text("规则热度"),
                footer: Text("只列出有命中记录的规则，按命中次数排序。")
            ) {
                let hotRules = store.settings.rules
                    .filter { $0.hitCount > 0 }
                    .sorted { $0.hitCount > $1.hitCount }
                    .prefix(20)

                if hotRules.isEmpty {
                    Text("还没有规则命中过")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(Array(hotRules)) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.pattern)
                                    .lineLimit(1)
                                Text("\(rule.kind.title) · \(rule.matchMode.title)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(rule.hitCount)")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section {
                Button("重置过滤统计") {
                    store.resetStats()
                }
                .foregroundColor(.red)

                Button("重置全部规则的命中次数") {
                    store.resetHitCounts()
                }
                .foregroundColor(.red)
            }
        }
        .listStyle(GroupedListStyle())
        .navigationBarTitle("过滤统计", displayMode: .inline)
    }

    private var rateText: String {
        guard store.stats.totalScanned > 0 else { return "—" }
        return String(format: "%.1f%%", store.stats.blockRate * 100)
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 屏蔽历史

struct BlockHistoryView: View {

    @EnvironmentObject private var store: SettingsStore

    @State private var reasonFilter: FilterReason?
    @State private var showClearConfirm = false

    private var filtered: [BlockHistoryEntry] {
        guard let reasonFilter = reasonFilter else { return store.history }
        return store.history.filter { $0.reason == reasonFilter }
    }

    private var availableReasons: [FilterReason] {
        let present = Set(store.history.map { $0.reason })
        return FilterReason.allCases.filter { present.contains($0) }
    }

    var body: some View {
        Group {
            if store.history.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("还没有屏蔽记录")
                        .font(.headline)
                    Text("每次扫描命中的内容都会记在这里，含命中原因与规则依据。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if let reasonFilter = reasonFilter {
                        HStack {
                            Text("当前筛选：\(reasonFilter.title)")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button("清除筛选") { self.reasonFilter = nil }
                                .font(.footnote)
                        }
                    }
                    ForEach(filtered) { entry in
                        entryRow(entry)
                    }
                }
                .listStyle(PlainListStyle())
            }
        }
        .navigationBarTitle("屏蔽历史", displayMode: .inline)
        .navigationBarItems(trailing: trailingItems)
        .actionSheet(isPresented: $showClearConfirm) {
            ActionSheet(
                title: Text("清空屏蔽历史？"),
                message: Text("过滤统计不会被清空，只有记录列表会被删除。"),
                buttons: [
                    .destructive(Text("清空")) { store.clearHistory() },
                    .cancel(Text("取消"))
                ]
            )
        }
    }

    private var trailingItems: some View {
        HStack(spacing: 14) {
            Menu {
                Button("全部原因") { reasonFilter = nil }
                ForEach(availableReasons, id: \.self) { reason in
                    Button(reason.title) { reasonFilter = reason }
                }
            } label: {
                Image(systemName: "line.horizontal.3.decrease.circle")
            }

            Button(action: { showClearConfirm = true }) {
                Image(systemName: "trash")
            }
        }
    }

    private func entryRow(_ entry: BlockHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.title.isEmpty ? entry.videoID : entry.title)
                .font(.subheadline)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(entry.reason.title)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.tfSurfaceElevated)
                    .cornerRadius(4)

                if !entry.channelName.isEmpty {
                    Text(entry.channelName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(Self.relative(entry.date))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if !entry.detail.isEmpty {
                Text(entry.detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter
    }()

    private static func relative(_ date: Date) -> String {
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
