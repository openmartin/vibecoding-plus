import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageHeader(eyebrow: "CONFIG", title: "设置", subtitle: state.inlineStatus)

            InkPanel(title: "macOS 权限状态", symbol: "checkmark.shield", accent: true) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 20) {
                        permIndicator("麦克风", granted: MicrophonePermission.isGranted, needed: true)
                        Spacer()
                        Button { state.openPermissions() } label: {
                            Label("打开权限", systemImage: "lock.open")
                        }
                        .inkButton()
                        Button { Task { await state.refreshEnvironment() } } label: {
                            Label("重新检测", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .inkButton()
                    }
                }
            }

            InkPanel(title: "运行模式", symbol: "switch.2", accessory: AnyView(sectionHint("语音识别结果仅用于 TODO 管理"))) {
                VStack(spacing: 14) {
                    PickerRow(label: "语音识别", hint: "选择语音转文字的 provider，下方会显示对应参数") {
                        InkSegmentedPicker(
                            selection: $state.config.sttProvider,
                            options: STTProvider.allCases,
                            label: { $0.label }
                        )
                    }

                    InkFormRow("LAN Secret") {
                        SecureField("留空=不鉴权", text: $state.config.lanSharedSecret)
                            .textFieldStyle(.plain)
                    }
                }
            }

            usageGuidePanel

            InkPanel(title: "TickTick 同步", symbol: "arrow.triangle.2.circlepath", accessory: AnyView(sectionHint("同步今日待办：今天到期 + 已过期未完成"))) {
                VStack(spacing: 12) {
                    InkFormRow("Token") {
                        SecureField("tp_...", text: $state.config.ticktickToken)
                            .textFieldStyle(.plain)
                    }
                    HStack(spacing: 10) {
                        Button { Task { await state.triggerTickTickSync() } } label: {
                            Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .inkButton()
                        .disabled(state.config.ticktickToken.isEmpty)

                        if state.config.ticktickToken.isEmpty {
                            Text("填入 Token 后保存并重启服务即可自动同步")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            providerSettings

            InkPanel(title: "应用行为", symbol: "gearshape") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("开机启动", isOn: $state.desktopSettings.autoLaunch)
                    Toggle("隐藏启动", isOn: $state.desktopSettings.launchToTray)
                    Toggle("关闭时保留菜单栏运行", isOn: $state.desktopSettings.closeToTray)
                }
                .toggleStyle(InkCheckboxToggleStyle())
            }

            PageActionBar {
                Button { Task { await state.saveSettings() } } label: {
                    Label("保存并应用", systemImage: "checkmark.circle.fill")
                }
                .inkProminentButton()
                Button { state.openConfigFolder() } label: {
                    Label("打开配置目录", systemImage: "folder")
                }
                .inkButton()
                Spacer()
                Text(SettingsStore().configURL.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .onAppear {
            Task { await state.refreshEnvironment() }
        }
    }

    private func permIndicator(_ name: String, granted: Bool, needed: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: granted ? "checkmark.circle.fill" : (needed ? "exclamationmark.triangle.fill" : "circle"))
                .foregroundStyle(granted ? InkTheme.ink : (needed ? InkTheme.warning : .secondary))
            Text(name)
                .font(.callout.weight(.medium))
            if !granted && needed {
                Text("未授权")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(InkTheme.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(InkTheme.warning.opacity(0.15), in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var providerSettings: some View {
        InkPanel(title: "\(state.config.sttProvider.label) 参数", symbol: "waveform.path.ecg") {
            VStack(spacing: 12) {
                switch state.config.sttProvider {
                case .volcengine:
                    InkFormRow("App Key") { TextField("", text: $state.config.volcengineAppKey).textFieldStyle(.plain) }
                    InkFormRow("Access Key") { SecureField("", text: $state.config.volcengineAccessKey).textFieldStyle(.plain) }
                case .openai:
                    InkFormRow("API Key") { SecureField("", text: $state.config.openaiApiKey).textFieldStyle(.plain) }
                    InkFormRow("模型") { TextField("", text: $state.config.openaiModel).textFieldStyle(.plain) }
                    VStack(alignment: .leading, spacing: 6) {
                        InkFormRow("API 地址") {
                            TextField("https://api.openai.com/v1", text: $state.config.openaiBaseUrl)
                                .textFieldStyle(.plain)
                        }
                        sectionHint("兼容 OpenAI 的第三方接口地址，留空则使用官方 https://api.openai.com/v1")
                            .padding(.leading, 146)
                    }
                case .whisperCpp:
                    InkFormRow("模型路径") { TextField("", text: $state.config.whisperCppModelPath).textFieldStyle(.plain) }
                    InkFormRow("命令") { TextField("", text: $state.config.whisperCppCommand).textFieldStyle(.plain) }
                    InkFormRow("语言") { TextField("", text: $state.config.whisperCppLanguage).textFieldStyle(.plain) }
                    InkFormRow("线程") { TextField("", text: $state.config.whisperCppThreads).textFieldStyle(.plain) }
                    InkFormRow("额外参数") { TextField("", text: $state.config.whisperCppExtraArgs).textFieldStyle(.plain) }
                case .qwenAsr:
                    InkFormRow("API Key") { SecureField("", text: $state.config.qwenAsrApiKey).textFieldStyle(.plain) }
                    InkFormRow("模型") { TextField("", text: $state.config.qwenAsrModel).textFieldStyle(.plain) }
                    InkFormRow("语言") { TextField("", text: $state.config.qwenAsrLanguage).textFieldStyle(.plain) }
                    InkFormRow("采样率") { TextField("", text: $state.config.qwenAsrSampleRate).textFieldStyle(.plain) }
                    InkFormRow("Realtime URL") { TextField("", text: $state.config.qwenAsrRealtimeBaseUrl).textFieldStyle(.plain) }
                    InkFormRow("提示词") { TextField("", text: $state.config.qwenAsrPrompt).textFieldStyle(.plain) }
                }
            }
        }
    }

    @ViewBuilder
    private var usageGuidePanel: some View {
        InkPanel(title: "使用说明", symbol: "book.pages",
                 accessory: AnyView(sectionHint("语音输入后自动解析为待办操作"))) {
            VStack(alignment: .leading, spacing: 10) {
                UsageKeyRow(symbol: "rectangle.roundedtop.fill", action: "长按 BOOT",
                            detail: "开始录音，松开后自动识别并解析为待办指令")
                UsageKeyRow(symbol: "checkmark.square", action: "短按 BOOT",
                            detail: "完成或删除当前选中的待办")
                UsageKeyRow(symbol: "arrow.up.arrow.down", action: "上 / 下 键",
                            detail: "移动待办选择或滚动日志")

                Divider().opacity(0.4).padding(.top, 2)

                Text("录音结束后，服务端通过 TodoAssistant 将语音转写解析为 add/toggle/delete 等待办操作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct UsageKeyRow: View {
    let symbol: String
    let action: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(InkTheme.accent)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(action)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
