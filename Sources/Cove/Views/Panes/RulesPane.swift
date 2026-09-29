import SwiftUI
import AppKit

/// 规则：自定义规则可增删；下方展示内核当前生效的完整规则列表。
///
/// 不用 `@State`：仅装 Command Line Tools 时 SwiftUI 宏插件缺失。
struct RulesPane: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if !model.canEditCustomRules {
                customConfigBanner
                Divider()
            }
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    customSection
                    liveSection
                }
                .padding(.vertical, 12)
            }
        }
        .task(id: model.status.isRunning) {
            guard model.status.isRunning else { return }
            await model.refreshRules()
        }
        .sheet(isPresented: $model.showingAddRuleSheet) {
            AddCustomRuleSheet(model: model)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("规则").font(.system(size: 22, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button {
                    model.beginAddCustomRule()
                } label: {
                    Label("添加规则", systemImage: "plus")
                }
                .disabled(!model.canEditCustomRules)
                .help(model.canEditCustomRules
                      ? "添加自定义分流规则"
                      : "正在使用自定义配置文件，无法在此编辑")

                Button {
                    Task { await model.refreshRules() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(!model.status.isRunning || model.busy)
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        let custom = model.settings.customRules.count
        if model.status.isRunning {
            return "自定义 \(custom) 条 · 生效 \(model.visibleRules.count) / \(model.rules.count) 条"
        }
        return "自定义 \(custom) 条 · 内核未运行"
    }

    private var customConfigBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("当前使用自定义配置文件，规则请直接在该 YAML 中编辑。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("筛选类型 / payload / 出站", text: Binding(
                    get: { model.ruleSearch },
                    set: { model.updateRuleSearch($0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !model.ruleSearch.isEmpty {
                    Button {
                        model.updateRuleSearch("")
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 6))
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    // MARK: - 自定义

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("自定义规则", detail: "优先匹配，保存后自动写入配置并重载")
            let items = filteredCustomRules
            if items.isEmpty {
                Text(model.settings.customRules.isEmpty
                   ? "还没有自定义规则。点右上角「添加规则」开始。"
                   : "没有匹配筛选条件的自定义规则。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { rule in
                        customRuleRow(rule)
                        Divider().padding(.leading, 20)
                    }
                }
            }
        }
    }

    private var filteredCustomRules: [CustomRule] {
        let keyword = model.ruleSearch.trimmingCharacters(in: .whitespaces).lowercased()
        let all = model.settings.customRules
        guard !keyword.isEmpty else { return all }
        return all.filter {
            [$0.type, $0.payload, $0.proxy]
                .joined(separator: " ")
                .lowercased()
                .contains(keyword)
        }
    }

    private func customRuleRow(_ rule: CustomRule) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { rule.enabled },
                set: { _ in Task { await model.toggleCustomRule(id: rule.id) } }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!model.canEditCustomRules)
                .help(rule.enabled ? "禁用" : "启用")

            Text(rule.type)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)

            Text(rule.type == "MATCH" ? "—" : (rule.payload.isEmpty ? "—" : rule.payload))
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(rule.enabled ? .primary : .tertiary)
                .textSelection(.enabled)

            Text(rule.proxy)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .trailing)

            Button(role: .destructive) {
                Task { await model.deleteCustomRule(id: rule.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .disabled(!model.canEditCustomRules)
            .help("删除")
            .frame(width: 22)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .opacity(rule.enabled ? 1 : 0.55)
    }

    // MARK: - 生效列表

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("当前生效",
                         detail: model.status.isRunning
                         ? "内核 /rules 实时列表（含内置 GEOIP / MATCH）"
                         : "启动内核后显示")
            if !model.status.isRunning {
                Text("内核未运行。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else if model.visibleRules.isEmpty {
                Text(model.rules.isEmpty
                     ? "当前没有规则。"
                     : "没有匹配「\(model.ruleSearch)」的规则")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.visibleRules) { rule in
                        liveRuleRow(rule)
                        Divider().padding(.leading, 20)
                    }
                }
            }
        }
    }

    private func liveRuleRow(_ rule: CtlClient.Rule) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(rule.type)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)

            Text(rule.payload?.isEmpty == false ? rule.payload! : "—")
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            Text(rule.proxy ?? "—")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .trailing)

            Color.clear.frame(width: 22)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - 添加规则

private struct AddCustomRuleSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加规则")
                .font(.system(size: 16, weight: .semibold))

            VStack(alignment: .leading, spacing: 12) {
                labeled("类型") {
                    Picker("", selection: $model.draftRuleType) {
                        ForEach(CustomRule.commonTypes, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                if model.draftRuleType != "MATCH" {
                    labeled("内容") {
                        TextField(payloadPlaceholder, text: $model.draftRulePayload)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                labeled("出站") {
                    Picker("", selection: $model.draftRuleProxy) {
                        ForEach(model.ruleProxyOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                if model.draftRuleType.contains("IP") || model.draftRuleType == "GEOIP" {
                    Toggle("no-resolve（不解析域名）", isOn: $model.draftRuleNoResolve)
                }
            }

            Text(previewLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack {
                Spacer()
                Button("取消") {
                    model.showingAddRuleSheet = false
                    model.resetRuleDraft()
                }
                .keyboardShortcut(.cancelAction)
                Button("添加") {
                    Task { await model.submitDraftCustomRule() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func labeled<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var payloadPlaceholder: String {
        switch model.draftRuleType {
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD": return "例如 google.com"
        case "GEOSITE": return "例如 youtube / google"
        case "GEOIP": return "例如 CN / LAN"
        case "IP-CIDR", "IP-CIDR6": return "例如 1.1.1.1/32"
        case "PROCESS-NAME": return "例如 curl"
        case "PROCESS-PATH": return "进程完整路径"
        default: return "匹配内容"
        }
    }

    private var previewLine: String {
        CustomRule.make(type: model.draftRuleType,
                        payload: model.draftRulePayload,
                        proxy: model.draftRuleProxy,
                        noResolve: model.draftRuleNoResolve)
            .clashLine.map { "预览：\($0)" } ?? "预览：请补全字段"
    }

    private var canSubmit: Bool {
        CustomRule.make(type: model.draftRuleType,
                        payload: model.draftRulePayload,
                        proxy: model.draftRuleProxy,
                        noResolve: model.draftRuleNoResolve)
            .clashLine != nil
    }
}
