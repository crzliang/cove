import SwiftUI
import AppKit

/// 日志：整页展示内核输出。
///
/// 刻意不用 `@State` —— 仅装 Command Line Tools 时 SwiftUI 宏插件缺失，
/// `@State` 无法编译。需要状态时一律放进 `AppModel`。
struct LogsPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            logBody
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("日志").font(.system(size: 20, weight: .semibold))
                Text("内核 stdout + stderr 合并写入 · 超过 4 MB 自动轮转")
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
                    pb.setString(model.logTail, forType: .string)
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

    private var logBody: some View {
        let text = model.logTail
        let isPlaceholder = text.contains("还没有日志")
        return ZStack {
            Color(nsColor: .textBackgroundColor)
            if isPlaceholder {
                VStack {
                    EmptyHint(systemImage: "doc.text",
                              message: "还没有日志。\n启动一次内核后，输出会出现在这里。")
                    Spacer()
                }
                .padding(.top, 60)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // 自动滚到底：用一个不可见的锚点，比 defaultScrollAnchor 兼容性好
                        Color.clear.frame(height: 1)
                            .id("log-bottom")
                    }
                }
            }
        }
    }
}
