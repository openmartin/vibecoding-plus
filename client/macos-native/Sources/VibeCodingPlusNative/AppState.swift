import AppKit
import Combine
import Foundation
import ServiceManagement
import UserNotifications
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    @Published var config: AppConfig
    @Published var desktopSettings: DesktopSettings
    @Published var environmentReport: EnvironmentReport?
    @Published var devices: [DeviceInfo] = []
    @Published var todos: [TodoItem] = []
    @Published var archivedTodos: [TodoItem] = []
    @Published var serviceStatus: ServiceStatusPayload?
    @Published var displayConfig = DisplayConfig()
    @Published var liveActivity = LiveActivity()
    @Published var installLog = ""
    @Published var inlineStatus = ""
    @Published var isBusy = false
    @Published var serviceRunning = false
    @Published var pairingCode = ""
    @Published var otaProgress: [String: (phase: String, pct: Int)] = [:]

    private var nativeServer: NativeServer?
    private let settingsStore = SettingsStore()
    private let checker = EnvironmentChecker()

    init() {
        config = settingsStore.loadConfig()
        desktopSettings = settingsStore.loadDesktopSettings()
    }

    // MARK: - ServerConfig Bridge

    private func makeServerConfig() -> ServerConfig {
        var sc = ServerConfig.load()
        sc.sttProvider = config.sttProvider.rawValue
        sc.port = config.port
        sc.discoveryHostId = config.discoveryHostId
        sc.discoveryPort = config.discoveryPort
        sc.lanSharedSecret = config.lanSharedSecret
        sc.deepSeekApiKey = config.deepSeekApiKey
        sc.deepSeekModel = config.deepSeekModel
        sc.deepSeekBaseUrl = config.deepSeekBaseUrl
        sc.openaiApiKey = config.openaiApiKey
        sc.openaiModel = config.openaiModel
        sc.openaiBaseUrl = config.openaiBaseUrl
        sc.volcengineAppKey = config.volcengineAppKey
        sc.volcengineAccessKey = config.volcengineAccessKey
        sc.whisperCppModelPath = config.whisperCppModelPath
        sc.whisperCppLanguage = config.whisperCppLanguage
        sc.whisperCppThreads = Int(config.whisperCppThreads) ?? 4
        sc.whisperCppCommand = config.whisperCppCommand
        sc.whisperCppExtraArgs = config.whisperCppExtraArgs
        sc.qwenAsrApiKey = config.qwenAsrApiKey
        sc.qwenAsrModel = config.qwenAsrModel
        sc.qwenAsrLanguage = config.qwenAsrLanguage
        sc.qwenAsrSampleRate = Int(config.qwenAsrSampleRate) ?? 16000
        sc.qwenAsrRealtimeBaseUrl = config.qwenAsrRealtimeBaseUrl
        sc.qwenAsrPrompt = config.qwenAsrPrompt
        sc.mockTranscript = config.mockTranscript
        sc.displayTodoRefreshMs = config.displayTodoRefreshMs
        sc.displayStyle = config.displayStyle
        sc.ticktickToken = config.ticktickToken
        return sc
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        await refreshEnvironment()
        if serviceRunning {
            await refreshRuntime()
        }
    }

    func startService() async {
        do {
            let sc = makeServerConfig()
            let server = NativeServer(config: sc)
            nativeServer = server

            // Wire all NativeServer callbacks directly (replaces old WebSocketClient loopback)
            server.onStatusChange = { [weak self] status, message in
                Task { @MainActor in
                    self?.inlineStatus = message
                    self?.serviceRunning = (status == .running)
                }
            }
            server.onTranscript = { [weak self] text in
                Task { @MainActor in self?.liveActivity.lastTranscript = text }
            }
            server.onServiceLog = { [weak self] lines in
                Task { @MainActor in self?.liveActivity.serviceLogLines = lines }
            }
            server.onDeviceEvent = { [weak self] event, deviceId, boardType in
                Task { @MainActor in
                    await self?.refreshRuntime()
                    if event == "disconnected" {
                        let content = UNMutableNotificationContent()
                        content.title = "设备断开"
                        content.body = "设备 \(deviceId) 已断开连接"
                        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                        try? await UNUserNotificationCenter.current().add(request)
                    }
                }
            }
            server.onTodoStateChange = { [weak self] json in
                Task { @MainActor in
                    guard let self else { return }
                    if let items = json["items"] as? [[String: Any]],
                       let data = try? JSONSerialization.data(withJSONObject: items),
                       let decoded = try? JSONDecoder().decode([TodoItem].self, from: data) {
                        self.todos = decoded
                    }
                    if let archiveItems = json["archiveItems"] as? [[String: Any]],
                       let data = try? JSONSerialization.data(withJSONObject: archiveItems),
                       let decoded = try? JSONDecoder().decode([TodoItem].self, from: data) {
                        self.archivedTodos = decoded
                    }
                }
            }

            try await server.start()
            serviceRunning = true
            inlineStatus = "原生服务运行中 (port \(sc.port))"
            await refreshRuntime()
        } catch {
            print("[AppState] startService error: \(error)")
            inlineStatus = "启动失败：\(error.localizedDescription)"
            serviceRunning = false
        }
    }

    func stopService() async {
        await nativeServer?.stop()
        nativeServer = nil
        serviceRunning = false
        inlineStatus = "服务已停止"
    }

    func restartService() async {
        await stopService()
        await startService()
    }

    func toggleService() async {
        if serviceRunning {
            await stopService()
        } else {
            await startService()
        }
    }

    func saveSettings(restart: Bool = true) async {
        do {
            try settingsStore.saveConfig(config)
            try settingsStore.saveDesktopSettings(desktopSettings)
            syncLoginItem()
            inlineStatus = restart ? "已保存；后台服务会重启，通常几秒内生效" : "已保存"
            if restart, serviceRunning {
                await restartService()
            }
            await refreshEnvironment()
        } catch {
            inlineStatus = "保存失败：\(error.localizedDescription)"
        }
    }

    func refreshEnvironment() async {
        environmentReport = await checker.check(config: config)
    }

    func install(toolId: String) async {
        let script = checker.installScript(for: toolId)
        guard !script.isEmpty else { return }
        isBusy = true
        installLog = "开始安装 \(toolId)...\n"
        inlineStatus = "正在安装 \(toolId)"
        let result = await Shell.runBash(script) { [weak self] text in
            Task { @MainActor in self?.installLog += text }
        }
        isBusy = false
        inlineStatus = result.code == 0 ? "\(toolId) 安装完成，请重新检测" : "\(toolId) 安装失败，退出码 \(result.code)"
        if installLog.isEmpty {
            installLog = result.output
        }
        await refreshEnvironment()
    }

    func openPermissions() {
        checker.openPermissions()
        inlineStatus = "已打开权限设置并定位当前应用；如弹出麦克风授权，请选择允许"
        Task {
            let micGranted = await MicrophonePermission.requestIfNeeded()
            if !micGranted {
                MicrophonePermission.openSettings()
            }
            for _ in 0..<8 {
                try? await Task.sleep(for: .seconds(3))
                await refreshEnvironment()
            }
        }
    }

    func openConfigFolder() {
        NSWorkspace.shared.open(settingsStore.configDirectory)
    }

    func refreshRuntime() async {
        guard let server = nativeServer, serviceRunning else { return }

        let devices = await server.getDevices()
        let status = await server.getServiceStatus()
        let todoSnap = await server.getTodoSnapshot()
        let dc = await server.getDisplayConfig()

        self.devices = devices.map { dict in
            DeviceInfo(
                connId: dict["connId"] as? String,
                deviceId: dict["deviceId"] as? String ?? "unknown",
                boardType: dict["boardType"] as? String,
                remoteAddress: dict["remoteAddress"] as? String,
                connectedAt: dict["connectedAt"] as? Double,
                isProvisioned: dict["isProvisioned"] as? Bool ?? false
            )
        }
        self.serviceStatus = ServiceStatusPayload(
            ok: status["ok"] as? Bool ?? false,
            clientCount: status["clientCount"] as? Int,
            sttProvider: status["sttProvider"] as? String,
            discoveryEnabled: status["discoveryEnabled"] as? Bool,
            port: status["port"] as? Int
        )
        applyTodoSnapshot(todoSnap)
        self.displayConfig = dc
        self.pairingCode = await server.getPairingCode()
        self.otaProgress = await server.getAllFirmwareOtaProgress()
    }

    func discoverDevices() async {
        nativeServer?.triggerDiscovery(config: makeServerConfig())
        inlineStatus = "已发送发现请求"
        try? await Task.sleep(for: .seconds(2))
        await refreshRuntime()
    }

    // MARK: - Device pairing / OTA

    func provisionDevice(_ device: DeviceInfo) async {
        guard let server = nativeServer else { inlineStatus = "请先启动服务"; return }
        if device.isProvisioned {
            inlineStatus = "设备已下发密钥，无需重复操作"
            return
        }
        guard !config.lanSharedSecret.isEmpty else {
            inlineStatus = "当前为无密钥模式，无需下发密钥"
            return
        }
        let ok = await server.provisionSecret(forDeviceId: device.deviceId)
        inlineStatus = ok
            ? "LAN 密钥已发送到 \(device.deviceId)"
            : "下发密钥失败：设备未连接或未通过认证"
        await refreshRuntime()
    }

    func offerBuiltFirmware(to device: DeviceInfo) async {
        let repoRoot = ProcessInfo.processInfo.environment["VIBE_REPO_ROOT"]
            ?? FileManager.default.currentDirectoryPath
        let bin = URL(fileURLWithPath: repoRoot)
            .appendingPathComponent("firmware/build/xiaozhi.bin")
        guard FileManager.default.fileExists(atPath: bin.path) else {
            inlineStatus = "未找到 firmware/build/xiaozhi.bin，请先编译固件"
            return
        }
        await offerFirmware(to: device, binURL: bin)
    }

    func chooseFirmwareFile(for device: DeviceInfo) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        panel.prompt = "选择固件"
        if panel.runModal() == .OK, let url = panel.url {
            guard url.pathExtension.lowercased() == "bin" else {
                inlineStatus = "请选择 .bin 固件文件"
                return
            }
            Task { await offerFirmware(to: device, binURL: url) }
        }
    }

    private func offerFirmware(to device: DeviceInfo, binURL: URL) async {
        guard let server = nativeServer else { inlineStatus = "请先启动服务"; return }
        do {
            try await server.offerFirmware(forDeviceId: device.deviceId, binURL: binURL)
            inlineStatus = "固件 OTA 已推送到 \(device.deviceId)：\(binURL.lastPathComponent)"
        } catch NativeServerError.firmwareUpToDate {
            inlineStatus = "固件已是最新版本"
        } catch {
            inlineStatus = "固件 OTA 失败: \(error.localizedDescription)"
        }
    }

    // MARK: - Todo

    func addTodo(_ title: String, dueAt: String? = nil) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inlineStatus = "请输入待办内容"
            return
        }
        guard let server = nativeServer else {
            inlineStatus = "请先启动服务"
            return
        }
        let snapshot = await server.createTodo(title: trimmed, dueAt: dueAt)
        applyTodoSnapshot(snapshot)
        inlineStatus = "待办已添加"
    }

    func setTodo(_ item: TodoItem, completed: Bool) async {
        guard let server = nativeServer else { inlineStatus = "请先启动服务"; return }
        let snapshot = await server.updateTodo(id: item.id, index: nil, title: nil, dueAt: nil, completed: completed)
        applyTodoSnapshot(snapshot)
        inlineStatus = completed ? "待办已完成" : "待办已恢复"
    }

    func editTodo(_ item: TodoItem, title: String, dueAt: String?) async {
        guard let server = nativeServer else { inlineStatus = "请先启动服务"; return }
        let snapshot = await server.updateTodo(id: item.id, index: nil, title: title, dueAt: dueAt, completed: nil)
        applyTodoSnapshot(snapshot)
        inlineStatus = "待办已更新"
    }

    func deleteTodo(_ item: TodoItem) async {
        guard let server = nativeServer else { inlineStatus = "请先启动服务"; return }
        let snapshot = await server.deleteTodo(id: item.id, index: nil)
        applyTodoSnapshot(snapshot)
        inlineStatus = "待办已删除"
    }

    private func applyTodoSnapshot(_ snapshot: TodoSnapshot) {
        todos = snapshot.items
        archivedTodos = snapshot.archiveItems
    }

    // MARK: - Display Config

    func fetchDisplayConfig() async {
        guard let server = nativeServer else { return }
        displayConfig = await server.getDisplayConfig()
    }

    func saveDisplayConfig() async {
        await nativeServer?.updateDisplayConfig(displayConfig)
        config.displayTodoRefreshMs = displayConfig.todoRefreshMs
        config.displayStyle = displayConfig.style
        try? settingsStore.saveConfig(config)
        inlineStatus = "显示配置已保存并推送到设备"
        await refreshRuntime()
    }

    func forceDisplayRefresh() async {
        await nativeServer?.forceDisplayRefresh()
        inlineStatus = "已请求设备立即刷新屏幕"
    }

    // MARK: - TickTick Sync

    func triggerTickTickSync() async {
        guard let server = nativeServer else {
            inlineStatus = "请先启动服务"
            return
        }
        inlineStatus = "TickTick 同步中..."
        await server.triggerTickTickSync()
        await refreshRuntime()
        inlineStatus = "TickTick 同步完成"
    }

    // MARK: - Server Restart

    func restartServer() async {
        inlineStatus = "服务正在重启..."
        await restartService()
    }

    // MARK: - Login Item (Auto-Launch)

    private func syncLoginItem() {
        if #available(macOS 13.0, *) {
            do {
                if desktopSettings.autoLaunch {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("[LoginItem] \(error.localizedDescription)")
            }
        }
    }

}
