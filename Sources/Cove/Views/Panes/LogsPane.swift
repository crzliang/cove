import SwiftUI
import AppKit

/// 日志：解析 mihomo 行，按级别 / 分类 / 搜索筛选，结构化列表展示。
struct LogsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            logBody
        }
        .onAppear { model.refreshLog() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("日志").font(.system(size: 22, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    model.refreshLog()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(copyText, forType: .string)
                    model.banner = AppModel.Banner(text: "日志已复制到剪贴板", isError: false)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([Paths.kernelLog])
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        let visible = model.visibleLogEntries.count
        let total = model.logEntries.count
        if total == 0 { return "内核 stdout + stderr · 超过 4 MB 自动轮转" }
        if visible == total { return "最近 \(total) 条" }
        return "显示 \(visible) / \(total) 条"
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.logLevelFilter) {
                ForEach(KernelLogFilter.levels, id: \.self) { level in
                    Text(KernelLogFilter.levelTitle(level)).tag(level)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            Picker("", selection: $model.logCategoryFilter) {
                ForEach(KernelLogFilter.categories, id: \.self) { category in
                    Text(KernelLogFilter.categoryTitle(category)).tag(category)
                }
            }
            .labelsHidden()
            .frame(width: 100)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索 | Regex", text: $model.logSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !model.logSearch.isEmpty {
                    Button {
                        model.logSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private var logBody: some View {
        let entries = model.visibleLogEntries
        return ZStack {
            Color(nsColor: .windowBackgroundColor)
            if model.logEntries.isEmpty {
                VStack {
                    EmptyHint(systemImage: "doc.text",
                              message: "还没有日志。\n启动一次内核后，输出会出现在这里。")
                    Spacer()
                }
                .padding(.top, 60)
            } else if entries.isEmpty {
                VStack {
                    EmptyHint(systemImage: "line.3.horizontal.decrease.circle",
                              message: "没有匹配的日志。\n试试换级别、分类，或清空搜索。")
                    Spacer()
                }
                .padding(.top, 60)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { offset, entry in
                            logRow(entry, index: entries.count - offset)
                            if offset + 1 < entries.count {
                                Divider().padding(.leading, 52)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private func logRow(_ entry: KernelLogEntry, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(format: "%02d.", index))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 28, alignment: .trailing)

            Text(entry.timeText.isEmpty ? "--:--:--" : entry.timeText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.purple.opacity(0.85))
                .frame(width: 64, alignment: .leading)

            Text(entry.levelLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(levelForeground(entry.level))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(levelBackground(entry.level), in: Capsule())

            Text(entry.message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Button("复制此行") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(entry.raw, forType: .string)
            }
        }
    }

    private var copyText: String {
        let entries = model.visibleLogEntries
        if entries.isEmpty { return model.logTail }
        return entries.map(\.raw).joined(separator: "\n")
    }

    private func levelForeground(_ level: String) -> Color {
        switch level {
        case "error": return .red
        case "warning": return .orange
        case "debug": return .secondary
        default: return Color.accentColor
        }
    }

    private func levelBackground(_ level: String) -> Color {
        switch level {
        case "error": return Color.red.opacity(0.12)
        case "warning": return Color.orange.opacity(0.14)
        case "debug": return Color(nsColor: .separatorColor).opacity(0.35)
        default: return Color.accentColor.opacity(0.14)
        }
    }
}
