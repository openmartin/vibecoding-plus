import Foundation

private let keepaliveIntervalMs: UInt64 = 30_000
private let keepaliveMissLimit = 2

// MARK: - Client State

/// Per-connection state for an authenticated ESP32 / desktop client.
struct ClientState {
    var deviceId: String = "unknown"
    var boardType: String = "unknown"
    var authenticated: Bool = false
    var connectedAt: Date = Date()
    var segmentActive: Bool = false
    var chunks: [Data] = []
    var audioBytes: Int = 0
    var missedPings: Int = 0
    var authChallengeNonce: String? = nil
    var provisionCompleted: Bool = false
}

// MARK: - NativeServer

/// Main orchestrator that replaces the Node.js `server.mjs`.
///
/// Coordinates WebSocket serving, UDP discovery, STT, and todo management.
/// Individual service implementations live in separate files; this actor wires them together.
actor NativeServer {

    // MARK: Sub-services

    private let wsServer = WebSocketServer()
    private let discoveryServer = DiscoveryServer()
    private let sttService: STTService
    private let todoAssistant: TodoAssistant
    private var todoService: TodoService!
    private var config: ServerConfig

    private var recentHelloNonces: [String: Date] = [:]
    private var clientStates: [UUID: ClientState] = [:]
    private var serviceLogLines: [String] = []
    private let maxServiceLogLines = 200
    private var isRunning = false
    private var keepaliveTask: Task<Void, Never>?
    private let firmwareOtaHost = FirmwareOtaHost()
    private let setupHttpHost = LanSetupHttpHost()
    private let setupPageSnapshot = SetupPageSnapshot()
    private var pairingCode: String = ""
    private var firmwareOtaProgress: [String: (phase: String, pct: Int)] = [:]
    private var streamingSttSessions: [UUID: QwenStreamingSTTSession] = [:]
    private var firmwareCheckContinuations: [String: CheckedContinuation<Bool, Never>] = [:]
    private var ticktickSync: TickTickSync?

    // MARK: Callbacks to UI layer (nonisolated for external wiring)

    nonisolated(unsafe) var onStatusChange: ((ServiceStatus, String) -> Void)?
    nonisolated(unsafe) var onDeviceEvent: ((String, String, String) -> Void)?
    nonisolated(unsafe) var onTodoStateChange: (([String: Any]) -> Void)?
    nonisolated(unsafe) var onServiceLog: (([String]) -> Void)?
    nonisolated(unsafe) var onTranscript: ((String) -> Void)?

    // MARK: Init

    init(config: ServerConfig) {
        self.config = config
        self.sttService = STTService(config: config)
        self.todoAssistant = TodoAssistant(config: config)
    }

    // MARK: - Lifecycle

    func start() async throws {
        guard !isRunning else { return }
        isRunning = true
        pairingCode = String(format: "%06d", Int.random(in: 0...999_999))
        config.pairingCode = pairingCode
        refreshSetupPageSnapshot()

        todoService = await .create(storagePath: config.todoListPath)
        await todoService.setOnChange { [weak self] in
            Task { await self?.broadcastTodoState() }
        }
        try await wsServer.start(port: UInt16(config.port))
        wireWebSocketCallbacks()
        startSetupHttpHost()

        // Start TickTick sync if token is configured
        if !config.ticktickToken.isEmpty {
            let sync = TickTickSync(token: config.ticktickToken, pollSec: config.ticktickSyncPollSec)
            ticktickSync = sync
            await sync.startPeriodicSync(todoService: todoService)
            appendServiceLog("TickTick 同步已启动 (间隔 \(config.ticktickSyncPollSec)s)")
        }

        discoveryServer.onLog = { [weak self] msg in
            Task { await self?.appendServiceLog(msg) }
        }

        startKeepalive()

        // Start UDP discovery server. Treat failure as fatal: the e-paper
        // device relies on this listener to replace stale .local/cache targets.
        try await discoveryServer.start(config: config)

        onStatusChange?(.running, "服务运行中 (port \(config.port))")
        appendServiceLog("服务启动 — port \(config.port), STT: \(config.resolvedSttProvider)")
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false

        stopKeepalive()
        await ticktickSync?.stopPeriodicSync()
        ticktickSync = nil
        await discoveryServer.stop()
        await wsServer.stop()
        setupHttpHost.stop()
        firmwareOtaHost.stop()
        clientStates.removeAll()
        recentHelloNonces.removeAll()

        onStatusChange?(.stopped, "服务已停止")
        appendServiceLog("服务停止")
    }

    func restart(with newConfig: ServerConfig) async throws {
        await stop()
        config = newConfig
        refreshSetupPageSnapshot()
        try await start()
    }

    // MARK: - Sleep / Wake Handling

    /// Called when the system is about to sleep.
    /// Gracefully closes all device connections and suspends keepalive.
    func handleSleep() async {
        guard isRunning else { return }
        appendServiceLog("系统即将睡眠，暂停服务...")
        stopKeepalive()

        // Close all active connections immediately
        let conns = await wsServer.allConnections()
        for conn in conns {
            conn.close()
        }
        clientStates.removeAll()
        streamingSttSessions.removeAll()
    }

    /// Called after the system wakes from sleep.
    /// Restarts the WebSocket listener, discovery server, and keepalive;
    /// then broadcasts a discovery ping so devices reconnect quickly.
    func handleWake() async {
        guard isRunning else { return }
        appendServiceLog("系统唤醒，恢复服务...")

        // Restart WebSocket listener (it may have entered .failed state)
        do {
            try await wsServer.restart(port: UInt16(config.port))
            wireWebSocketCallbacks()
            appendServiceLog("WebSocket 监听已恢复 (port \(config.port))")
        } catch {
            appendServiceLog("WebSocket 监听恢复失败: \(error.localizedDescription)")
        }

        // Restart UDP discovery (socket may be stale after network change)
        await discoveryServer.stop()
        do {
            try await discoveryServer.start(config: config)
            appendServiceLog("发现服务已恢复")
        } catch {
            appendServiceLog("发现服务恢复失败: \(error.localizedDescription)")
        }

        // Restart keepalive
        startKeepalive()

        // Send a discovery broadcast so devices know we're back
        await discoveryServer.sendBroadcast(config: config)
        appendServiceLog("已发送发现广播，等待设备重连")

        onStatusChange?(.running, "服务运行中 (port \(config.port))")
    }

    // MARK: - Direct Function Calls (replaces HTTP admin API)

    func getPairingCode() -> String { pairingCode }

    func getSetupPageURL(forRemoteIP remoteIP: String) async -> String? {
        guard let address = await discoveryServer.localAddress(forRemoteIP: remoteIP) else { return nil }
        return "http://\(address):\(config.setupPort)/pair"
    }

    private func startSetupHttpHost() {
        setupHttpHost.infoProvider = { [setupPageSnapshot] in
            setupPageSnapshot.asInfo()
        }
        do {
            try setupHttpHost.start(port: UInt16(config.setupPort))
            appendServiceLog("配对页 HTTP 服务: :\(config.setupPort)/pair")
        } catch {
            appendServiceLog("配对页 HTTP 启动失败: \(error.localizedDescription)")
        }
    }

    private func refreshSetupPageSnapshot() {
        setupPageSnapshot.hostId = config.discoveryHostId
        setupPageSnapshot.hostName = ProcessInfo.processInfo.hostName
        setupPageSnapshot.pairCode = pairingCode
        setupPageSnapshot.hasSharedSecret = !config.lanSharedSecret.isEmpty
    }

    func offerFirmware(to connId: UUID, binURL: URL) async throws {
        guard let conn = await wsServer.connection(id: connId) else {
            throw URLError(.cannotConnectToHost)
        }
        guard ensureAuthenticated(connId, conn: conn) else {
            throw URLError(.userAuthenticationRequired)
        }
        let state = clientStates[connId] ?? ClientState()
        let remoteIP = conn.remoteAddress.components(separatedBy: ":").first ?? "127.0.0.1"
        let localIP = await discoveryServer.localAddress(forRemoteIP: remoteIP) ?? "127.0.0.1"
        let (sha256, size) = try firmwareOtaHost.start(binURL: binURL)
        let version = resolveFirmwareVersion(binURL: binURL)
        firmwareOtaProgress[state.deviceId] = ("检查版本", 0)

        var checkPayload: [String: Any] = [
            "type": LANServerMessage.firmware_check,
            "sha256": sha256,
            "size": size,
        ]
        if let version, !version.isEmpty {
            checkPayload["version"] = version
        }
        sendJson(to: conn, checkPayload)

        let deviceId = state.deviceId
        let needUpgrade = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            firmwareCheckContinuations[deviceId] = cont
            Task {
                try? await Task.sleep(for: .seconds(3))
                if let pending = firmwareCheckContinuations.removeValue(forKey: deviceId) {
                    pending.resume(returning: true)
                }
            }
        }

        guard needUpgrade else {
            firmwareOtaProgress[deviceId] = ("已是最新", 100)
            appendServiceLog("固件已是最新: \(deviceId) (\(version ?? binURL.lastPathComponent))")
            throw NativeServerError.firmwareUpToDate
        }

        var offerPayload: [String: Any] = [
            "type": LANServerMessage.firmware_offer,
            "url": "http://\(localIP):8767/firmware.bin",
            "sha256": sha256,
            "size": size,
        ]
        if let version, !version.isEmpty {
            offerPayload["version"] = version
        }
        sendJson(to: conn, offerPayload)
        appendServiceLog("固件 OTA 提供: \(binURL.lastPathComponent) → \(localIP):8767")
    }

    func provisionSecret(to connId: UUID) async -> Bool {
        guard let conn = await wsServer.connection(id: connId) else { return false }
        guard !config.lanSharedSecret.isEmpty else {
            appendServiceLog("配对失败: 未配置 LAN_SHARED_SECRET")
            return false
        }
        sendJson(to: conn, [
            "type": LANServerMessage.provision_secret,
            "secret": config.lanSharedSecret,
            "hostId": config.discoveryHostId,
            "hostName": ProcessInfo.processInfo.hostName,
        ])
        if var state = clientStates[connId] {
            state.provisionCompleted = true
            clientStates[connId] = state
        }
        broadcastServerReady(to: conn)
        appendServiceLog("已发送配对密钥 → \(clientStates[connId]?.deviceId ?? "unknown")")
        return true
    }

    func getFirmwareOtaProgress(for deviceId: String) -> (phase: String, pct: Int)? {
        firmwareOtaProgress[deviceId]
    }

    func getAllFirmwareOtaProgress() -> [String: (phase: String, pct: Int)] {
        firmwareOtaProgress
    }

    func connId(for deviceId: String) -> UUID? {
        clientStates.first(where: { $0.value.deviceId == deviceId })?.key
    }

    func offerFirmware(forDeviceId deviceId: String, binURL: URL) async throws {
        guard let connId = connId(for: deviceId) else { throw URLError(.cannotFindHost) }
        try await offerFirmware(to: connId, binURL: binURL)
    }

    func provisionSecret(forDeviceId deviceId: String) async -> Bool {
        guard let connId = connId(for: deviceId) else { return false }
        return await provisionSecret(to: connId)
    }

    func getDevices() async -> [[String: Any]] {
        var devices: [[String: Any]] = []
        for (connId, state) in clientStates {
            var dict: [String: Any] = [
                "connId": connId.uuidString,
                "deviceId": state.deviceId,
                "boardType": state.boardType,
                "connectedAt": state.connectedAt.timeIntervalSince1970 * 1000
            ]
            if let conn = await wsServer.connection(id: connId) {
                dict["remoteAddress"] = conn.remoteAddress
            }
            dict["isProvisioned"] = !config.lanSharedSecret.isEmpty &&
                (state.authenticated || state.provisionCompleted)
            devices.append(dict)
        }
        return devices
    }

    func getServiceStatus() -> [String: Any] {
        return [
            "ok": isRunning,
            "clientCount": clientStates.count,
            "sttProvider": config.resolvedSttProvider,
            "port": config.port,
            "setupPort": config.setupPort,
            "discoveryEnabled": config.discoveryEnabled
        ]
    }

    func getTodoSnapshot() async -> TodoSnapshot {
        let snap = await todoService.getSnapshot()
        return convertSnapshot(snap)
    }

    func createTodo(title: String, dueAt: String?, reminderList: String? = nil) async -> TodoSnapshot {
        _ = await todoService.create(title: title, dueAt: dueAt, reminderList: reminderList)
        let snap = await todoService.getSnapshot()
        return convertSnapshot(snap)
    }

    func updateTodo(id: String?, index: Int?, title: String?, dueAt: String?, completed: Bool?) async -> TodoSnapshot {
        if let completed {
            await todoService.toggle(id: id, index: index, completed: completed)
            pushTickTickDirtyItems()
        }
        if title != nil || dueAt != nil {
            await todoService.update(id: id, index: index, title: title, dueAt: dueAt)
        }
        let snap = await todoService.getSnapshot()
        return convertSnapshot(snap)
    }

    func deleteTodo(id: String?, index: Int?) async -> TodoSnapshot {
        _ = await todoService.delete(id: id, index: index)
        let snap = await todoService.getSnapshot()
        return convertSnapshot(snap)
    }

    private func convertSnapshot(_ snap: TodoServiceSnapshot) -> TodoSnapshot {
        TodoSnapshot(
            items: snap.items.map { TodoItem(id: $0.id, title: $0.title, completed: $0.completed, dueAt: $0.dueAt, ticktickId: $0.ticktickId, isAllDay: $0.isAllDay, timeZone: $0.timeZone) },
            archiveItems: snap.archiveItems.map { TodoItem(id: $0.id, title: $0.title, completed: $0.completed, dueAt: $0.dueAt, ticktickId: $0.ticktickId, isAllDay: $0.isAllDay, timeZone: $0.timeZone) },
            selectedIndex: snap.selectedIndex,
            lastActionText: snap.lastActionText
        )
    }

    func getDisplayConfig() -> DisplayConfig {
        return DisplayConfig(
            todoRefreshMs: config.displayTodoRefreshMs,
            style: config.displayStyle
        )
    }

    // MARK: - TickTick Sync

    func getTickTickSyncStatus() async -> TickTickSyncStatus {
        guard let sync = ticktickSync else {
            return TickTickSyncStatus(enabled: false)
        }
        return await sync.getStatus()
    }

    func triggerTickTickSync() async {
        guard let sync = ticktickSync else { return }
        await sync.performSync(todoService: todoService)
        await broadcastTodoState()
        appendServiceLog("TickTick 手动同步完成")
    }

    /// Immediately push dirty items (e.g. after toggle/complete) to TickTick.
    private func pushTickTickDirtyItems() {
        guard let sync = ticktickSync else { return }
        Task {
            await sync.pushDirtyItems(todoService: todoService)
        }
    }

    func updateDisplayConfig(_ dc: DisplayConfig) {
        config.displayTodoRefreshMs = dc.todoRefreshMs
        config.displayStyle = dc.style
        broadcastDisplayConfig()
    }

    func forceDisplayRefresh() {
        broadcastJson(["type": LANServerMessage.force_refresh])
    }

    nonisolated func triggerDiscovery(config: ServerConfig) {
        Task { await discoveryServer.sendBroadcast(config: config) }
    }

    // MARK: - WebSocket Message Handling

    /// Main message router — direct port of the `switch(message.type)` block
    /// in `server.mjs` (line 2126).
    private func handleMessage(_ message: [String: Any], from connId: UUID) async {
        guard let type = message["type"] as? String else { return }
        guard let conn = await wsServer.connection(id: connId) else { return }
        let deviceId = clientStates[connId]?.deviceId ?? "unknown"

        // Log all message types except high-frequency ones
        if type != LANDeviceMessage.ping && type != LANDeviceMessage.ptt_start {
            appendServiceLog("消息: \(deviceId) → \(type)")
        }

        switch type {
        case LANDeviceMessage.hello:
            await handleHello(message, from: conn, connId: connId)

        case LANDeviceMessage.ptt_start:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handlePttStart(message, connId: connId)

        case LANDeviceMessage.ptt_stop:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handlePttStop(connId: connId)

        case LANDeviceMessage.todo_command:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            await handleTodoCommand(message, connId: connId)

        case LANDeviceMessage.ping:
            sendJson(to: conn, ["type": LANServerMessage.pong, "nowMs": Int(Date().timeIntervalSince1970 * 1000)])

        case LANDeviceMessage.firmware_progress:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            let phase = (message["phase"] as? String) ?? ""
            let pct = (message["pct"] as? Int) ?? 0
            firmwareOtaProgress[deviceId] = (phase, pct)
            appendServiceLog("OTA \(deviceId): \(phase) \(pct)%")

        case LANDeviceMessage.firmware_result:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            let ok = (message["ok"] as? Bool) ?? false
            let version = (message["version"] as? String) ?? ""
            let note = (message["message"] as? String) ?? ""
            let finalPct = ok ? 100 : (firmwareOtaProgress[deviceId]?.pct ?? 0)
            firmwareOtaProgress[deviceId] = (ok ? "完成" : "失败", finalPct)
            appendServiceLog("OTA 完成 \(deviceId): ok=\(ok) version=\(version) \(note)")

        case LANDeviceMessage.firmware_check_result:
            guard ensureAuthenticated(connId, conn: conn) else { return }
            let needUpgrade = (message["needUpgrade"] as? Bool) ?? true
            if let cont = firmwareCheckContinuations.removeValue(forKey: deviceId) {
                cont.resume(returning: needUpgrade)
            }

        default:
            sendJson(to: conn, ["type": LANServerMessage.warning, "warning": "unknown_message_type:\(type)"])
        }
    }

    // MARK: - Hello / Auth

    private func handleHello(_ message: [String: Any], from conn: WSConnection, connId: UUID) async {
        var state = clientStates[connId] ?? ClientState()
        state.deviceId = (message["deviceId"] as? String) ?? "unknown"
        state.boardType = (message["boardType"] as? String) ?? "unknown"

        // Validate auth when shared secret is configured; allow unauthenticated hello for first-time pairing.
        var authenticated = config.lanSharedSecret.isEmpty
        if !config.lanSharedSecret.isEmpty {
            let deviceId = state.deviceId
            let deviceNonce = (message["authNonce"] as? String) ?? ""
            let serverNonce = (message["authServerNonce"] as? String) ?? ""
            let sig = (message["authSig"] as? String) ?? ""
            let expectedServerNonce = clientStates[connId]?.authChallengeNonce ?? ""

            if deviceNonce.isEmpty || sig.isEmpty {
                appendServiceLog("待配对设备连接: \(deviceId)")
                authenticated = false
            } else {
                guard !expectedServerNonce.isEmpty, serverNonce == expectedServerNonce else {
                    closeWithAuthError(conn, connId: connId, error: "auth_challenge_mismatch")
                    return
                }

                let cacheKey = "\(deviceId):\(deviceNonce)"
                guard !recentHelloNonces.keys.contains(cacheKey) else {
                    closeWithAuthError(conn, connId: connId, error: "auth_replayed")
                    return
                }
                pruneRecentHelloNonces()
                recentHelloNonces[cacheKey] = Date()

                let secret = config.lanSharedSecret
                let expected = LANAuth.signHelloChallengePayload(
                    secret: secret,
                    deviceId: deviceId,
                    boardType: state.boardType,
                    serverNonce: serverNonce,
                    deviceNonce: deviceNonce
                )
                guard LANAuth.signaturesMatch(expected, sig) else {
                    closeWithAuthError(conn, connId: connId, error: "auth_invalid")
                    return
                }
                authenticated = true
            }
        }

        state.authenticated = authenticated
        clientStates[connId] = state
        var md = conn.metadata
        md["authenticated"] = authenticated
        conn.metadata = md

        sendJson(to: conn, ["type": LANServerMessage.hello_ack, "deviceId": state.deviceId, "protocolVersion": LANProtocol.version])
        emitServerReady(to: conn)
        broadcastDisplayConfig(to: conn)
        if authenticated {
            await emitTodoState(to: conn)
        }

        // Broadcast device_event to all other connected clients
        broadcastJson([
            "type": LANServerMessage.device_event,
            "event": "connected",
            "deviceId": state.deviceId,
            "boardType": state.boardType
        ], excluding: connId)

        onDeviceEvent?("connected", state.deviceId, state.boardType)
        appendServiceLog("设备连接: \(state.deviceId) (\(state.boardType))")
    }

    // MARK: - PTT Audio Pipeline

    private func handlePttStart(_ message: [String: Any], connId: UUID) async {
        var state = clientStates[connId] ?? ClientState()
        let source = (message["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        appendServiceLog("PTT开始: \(state.deviceId), source=\(source.isEmpty ? "firmware" : source)")
        state.segmentActive = true
        state.chunks = []
        state.audioBytes = 0
        clientStates[connId] = state

        if sttService.resolveProvider() == .qwenAsr && config.mockTranscript.isEmpty {
            do {
                let session = QwenStreamingSTTSession(config: config)
                try await session.start { [weak self] partial in
                    Task { await self?.sendTranscriptPartial(partial, connId: connId) }
                }
                streamingSttSessions[connId] = session
            } catch {
                appendServiceLog("流式 STT 启动失败: \(error.localizedDescription)")
            }
        }

        if let conn = await wsServer.connection(id: connId) {
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "recording"])
        }
    }

    private func handlePttStop(connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        var state = clientStates[connId] ?? ClientState()

        if let session = streamingSttSessions.removeValue(forKey: connId) {
            state.segmentActive = false
            clientStates[connId] = state
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "transcribing"])
            let startedAt = Date()
            let transcript: String
            if !config.mockTranscript.isEmpty {
                transcript = config.mockTranscript
            } else {
                do {
                    transcript = try await session.finish()
                } catch {
                    appendServiceLog("流式 STT 错误: \(error.localizedDescription)")
                    session.cancel()
                    sendJson(to: conn, ["type": LANServerMessage.status, "status": "transcript_empty"])
                    return
                }
            }
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            appendServiceLog("STT(流式) [\("\(latencyMs)ms")]: \(trimmed.prefix(60))")
            await deliverTranscript(trimmed, latencyMs: latencyMs, connId: connId, conn: conn)
            return
        }

        let pcmBuffer = state.chunks.reduce(into: Data(capacity: state.audioBytes)) { buffer, chunk in
            buffer.append(chunk)
        }
        let provider = sttService.resolveProvider()
        appendServiceLog("STT 实际提供商: \(provider.rawValue)")
        state.segmentActive = false
        state.chunks = []
        state.audioBytes = 0
        clientStates[connId] = state
        appendServiceLog("PTT停止: \(state.deviceId), bytes=\(pcmBuffer.count)")

        if pcmBuffer.isEmpty {
            sendJson(to: conn, ["type": LANServerMessage.status, "status": "empty_segment"])
            return
        }

        sendJson(to: conn, ["type": LANServerMessage.status, "status": "transcribing", "bytes": pcmBuffer.count])
        let startedAt = Date()

        let transcript: String
        if !config.mockTranscript.isEmpty {
            transcript = config.mockTranscript
        } else {
            do {
                transcript = try await sttService.transcribe(pcm16Data: pcmBuffer)
            } catch {
                appendServiceLog("STT错误: \(error.localizedDescription)")
                transcript = ""
            }
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        appendServiceLog("STT [\("\(latencyMs)ms")]: \(trimmed.prefix(60))")
        await deliverTranscript(trimmed, latencyMs: latencyMs, connId: connId, conn: conn)
    }

    private func sendTranscriptPartial(_ text: String, connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sendJson(to: conn, [
            "type": LANServerMessage.transcript_partial,
            "text": trimmed,
        ])
    }

    private func deliverTranscript(
        _ trimmed: String,
        latencyMs: Int,
        connId: UUID,
        conn: WSConnection
    ) async {
        guard !trimmed.isEmpty else {
            sendJson(to: conn, [
                "type": LANServerMessage.status,
                "status": "transcript_empty",
                "text": ""
            ])
            return
        }
        onTranscript?(trimmed)

        sendJson(to: conn, [
            "type": LANServerMessage.transcript_final,
            "text": trimmed,
            "latencyMs": latencyMs,
            "requiresAction": false
        ])

        await dispatchTodoPrompt(trimmed, connId: connId)
    }

    // MARK: - Todo Command

    private func handleTodoCommand(_ message: [String: Any], connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }
        guard let action = (message["action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !action.isEmpty else {
            sendTodoResult(to: conn, ok: false, action: "unknown", message: "缺少待办操作")
            return
        }

        _ = await todoService.getSnapshot()
        var ok = true
        var resultMsg = ""

        switch action {
        case "create", "add":
            let title = (message["text"] as? String) ?? ""
            guard !title.isEmpty else { ok = false; resultMsg = "请输入待办内容"; break }
            _ = await todoService.create(title: title, dueAt: message["dueAt"] as? String)
            resultMsg = "待办已添加"
        case "toggle", "complete":
            await todoService.toggle(id: message["id"] as? String, index: message["index"] as? Int, completed: message["completed"] as? Bool ?? true)
            resultMsg = "待办已更新"
            pushTickTickDirtyItems()
        case "delete", "remove":
            _ = await todoService.delete(id: message["id"] as? String, index: message["index"] as? Int)
            resultMsg = "待办已删除"
        case "update":
            await todoService.update(id: message["id"] as? String, index: message["index"] as? Int, title: message["text"] as? String, dueAt: message["dueAt"] as? String)
            resultMsg = "待办已更新"
        case "select_next":
            await todoService.selectNext()
            resultMsg = "已选择下一个"
        case "select_prev":
            await todoService.selectPrev()
            resultMsg = "已选择上一个"
        case "clear":
            await todoService.clearCompleted()
            resultMsg = "已清空已完成"
        default:
            ok = false
            resultMsg = "未知操作: \(action)"
        }

        await broadcastTodoState()
        sendTodoResult(to: conn, ok: ok, action: action, message: resultMsg)
    }

    // MARK: - Todo Prompt Dispatch

    private func dispatchTodoPrompt(_ text: String, connId: UUID) async {
        guard let conn = await wsServer.connection(id: connId) else { return }

        let deviceId = clientStates[connId]?.deviceId ?? "unknown"
        let snapshot = await todoService.getSnapshot()
        let itemDicts = snapshot.items.map { itemToDict($0) }
        let result = await todoAssistant.interpret(text, deviceId: deviceId, snapshot: itemDicts)

        if result.ok, let command = result.command {
            var resultMsg = ""
            var ok = true

            switch command.action {
            case "create":
                guard let title = command.text, !title.isEmpty else { ok = false; resultMsg = "请输入待办内容"; break }
                _ = await todoService.create(title: title, dueAt: command.dueAt)
                resultMsg = "待办已添加"
            case "toggle":
                await todoService.toggle(id: command.id, index: command.index, completed: command.completed ?? true)
                resultMsg = command.completed == true ? "待办已完成" : "待办已恢复"
                pushTickTickDirtyItems()
            case "delete":
                _ = await todoService.delete(id: command.id, index: command.index)
                resultMsg = "待办已删除"
            case "update":
                await todoService.update(id: command.id, index: command.index, title: command.text, dueAt: command.dueAt)
                resultMsg = "待办已更新"
            case "select_next":
                await todoService.selectNext()
                resultMsg = "已选择下一个"
            case "select_prev":
                await todoService.selectPrev()
                resultMsg = "已选择上一个"
            case "clear":
                await todoService.clearCompleted()
                resultMsg = "已清空已完成"
            case "list":
                resultMsg = "待办列表已刷新"
            default:
                ok = false
                resultMsg = "未识别的操作"
            }

            await broadcastTodoState()
            sendTodoResult(to: conn, ok: ok, action: command.action, message: resultMsg)
        } else if result.action == "ask", let message = result.message {
            sendJson(to: conn, [
                "type": LANServerMessage.status,
                "status": "awaiting_input",
                "text": message
            ])
        } else {
            // Fallback: treat as create
            _ = await todoService.create(title: text)
            await broadcastTodoState()
            sendTodoResult(to: conn, ok: true, action: "add", message: "待办已添加")
        }
    }

    // MARK: - Binary Audio Handling

    func handleBinary(_ data: Data, connId: UUID) async {
        var state = clientStates[connId] ?? ClientState()
        guard state.authenticated, state.segmentActive else { return }

        let nextBytes = state.audioBytes + data.count
        if nextBytes > config.lanAudioMaxBytes {
            state.segmentActive = false
            state.chunks = []
            state.audioBytes = 0
            clientStates[connId] = state
            streamingSttSessions.removeValue(forKey: connId)?.cancel()
            if let conn = await wsServer.connection(id: connId) {
                sendJson(to: conn, ["type": LANServerMessage.warning, "warning": "audio_too_large"])
                sendJson(to: conn, ["type": LANServerMessage.status, "status": "audio_too_large"])
            }
            return
        }

        if let session = streamingSttSessions[connId] {
            session.append(pcm16: data)
            state.audioBytes = nextBytes
            clientStates[connId] = state
            return
        }

        state.audioBytes = nextBytes
        state.chunks.append(data)
        clientStates[connId] = state
    }

    // MARK: - Broadcasting

    func broadcastServerReady(to conn: WSConnection) {
        sendJson(to: conn, serverReadyPayload())
    }

    private func serverReadyPayload() -> [String: Any] {
        [
            "type": LANServerMessage.server_ready,
            "protocolVersion": LANProtocol.version,
            "authRequired": !config.lanSharedSecret.isEmpty,
            "displayTodoRefreshMs": config.displayTodoRefreshMs,
            "displayStyle": config.displayStyle
        ]
    }

    func broadcastServerReady() {
        Task { [weak self] in
            guard let self else { return }
            await self.wsServer.broadcast(json: self.serverReadyPayload())
        }
    }

    func broadcastTodoState() async {
        let payload = await todoStatePayload()
        broadcastJson(payload)
        onTodoStateChange?(payload)
    }

    private func emitTodoState(to conn: WSConnection) async {
        let payload = await todoStatePayload()
        sendJson(to: conn, payload)
    }

    private func todoStatePayload() async -> [String: Any] {
        let snapshot = await getTodoSnapshot()
        return [
            "type": LANServerMessage.todo_state,
            "items": snapshot.items.map { itemToDict($0) },
            "archiveItems": snapshot.archiveItems.map { itemToDict($0) },
            "selectedIndex": snapshot.selectedIndex,
            "lastActionText": snapshot.lastActionText
        ]
    }

    func broadcastDisplayConfig(to conn: WSConnection? = nil) {
        let payload: [String: Any] = [
            "type": LANServerMessage.display_config,
            "todoRefreshMs": config.displayTodoRefreshMs,
            "style": config.displayStyle
        ]
        if let conn {
            sendJson(to: conn, payload)
        } else {
            broadcastJson(payload)
        }
    }

    func broadcastJson(_ json: [String: Any], excluding excludedId: UUID? = nil) {
        Task { await wsServer.broadcastAuthenticated(json: json, excludeId: excludedId) }
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: keepaliveIntervalMs * 1_000_000)
                guard let self else { break }
                let running = await self.isRunning
                guard running else { break }
                await self.runKeepalive()
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    private func runKeepalive() async {
        var toRemove: [UUID] = []
        for (connId, conn) in await wsServer.allConnections().map({ ($0.id, $0) }) {
            var state = clientStates[connId]
            let missed = (state?.missedPings ?? 0) + 1
            if missed >= keepaliveMissLimit {
                toRemove.append(connId)
                appendServiceLog("心跳超时: \(state?.deviceId ?? "unknown")")
                continue
            }
            state?.missedPings = missed
            if let state { clientStates[connId] = state }
            conn.sendPing()
        }
        for connId in toRemove {
            if let conn = await wsServer.connection(id: connId) {
                conn.close()
            }
            clientStates.removeValue(forKey: connId)
        }
    }

    // MARK: - WebSocket Wiring

    private func wireWebSocketCallbacks() {
        wsServer.onConnection = { [weak self] conn in
            Task { await self?.handleConnection(conn) }
        }
        wsServer.onDisconnect = { [weak self] conn in
            Task { await self?.handleDisconnect(conn.id) }
        }
    }

    func handleConnection(_ conn: WSConnection) {
        var state = ClientState()
        state.authenticated = config.lanSharedSecret.isEmpty
        clientStates[conn.id] = state
        appendServiceLog("WS连接: \(conn.remoteAddress)")

        if !config.lanSharedSecret.isEmpty {
            let serverNonce = UUID().uuidString.lowercased()
            state.authChallengeNonce = serverNonce
            clientStates[conn.id] = state
            sendJson(to: conn, ["type": LANServerMessage.auth_challenge, "serverNonce": serverNonce])
        }

        conn.onMessage = { [weak self] message in
            Task { await self?.handleWSMessage(message, connId: conn.id) }
        }
        conn.onPong = { [weak self] in
            Task { await self?.markConnectionAlive(conn.id) }
        }
    }

    func handleDisconnect(_ connId: UUID) {
        let state = clientStates.removeValue(forKey: connId)
        let deviceId = state?.deviceId ?? "unknown"
        let boardType = state?.boardType ?? "unknown"
        onDeviceEvent?("disconnected", deviceId, boardType)
        appendServiceLog("设备断开: \(deviceId)")
        broadcastJson([
            "type": LANServerMessage.device_event,
            "event": "disconnected",
            "deviceId": deviceId,
            "boardType": boardType
        ])
    }

    func handleTextMessage(_ text: String, connId: UUID) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        Task { await handleMessage(json, from: connId) }
    }

    private func handleWSMessage(_ message: WSMessage, connId: UUID) async {
        markConnectionAlive(connId)
        switch message {
        case .text(let text):
            handleTextMessage(text, connId: connId)
        case .binary(let data):
            await handleBinary(data, connId: connId)
        }
    }

    private func markConnectionAlive(_ connId: UUID) {
        guard var state = clientStates[connId] else { return }
        state.missedPings = 0
        clientStates[connId] = state
    }

    // MARK: - Private Helpers

    private func sendJson(to conn: WSConnection, _ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        conn.send(text: str)
    }

    private func sendTodoResult(to conn: WSConnection, ok: Bool, action: String, message: String) {
        sendJson(to: conn, [
            "type": LANServerMessage.todo_result,
            "ok": ok,
            "action": action,
            "message": message
        ])
    }

    private func emitServerReady(to conn: WSConnection) {
        broadcastServerReady(to: conn)
    }

    private func resolveFirmwareVersion(binURL: URL) -> String? {
        let metadataURL = binURL.deletingLastPathComponent().appendingPathComponent("project_description.json")
        guard let data = try? Data(contentsOf: metadataURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let candidates = ["project_version", "app_version", "version"]
        for key in candidates {
            if let raw = json[key] as? String {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func ensureAuthenticated(_ connId: UUID, conn: WSConnection) -> Bool {
        let state = clientStates[connId]
        if state?.authenticated == true { return true }
        closeWithAuthError(conn, connId: connId, error: "auth_required")
        return false
    }

    private func closeWithAuthError(_ conn: WSConnection, connId: UUID, error: String) {
        appendServiceLog("认证失败: \(error), addr=\(conn.remoteAddress)")
        sendJson(to: conn, ["type": LANServerMessage.error, "error": error])
        conn.close()
        clientStates.removeValue(forKey: connId)
    }

    private func pruneRecentHelloNonces() {
        let cutoff = Date().addingTimeInterval(-300)
        recentHelloNonces = recentHelloNonces.filter { $0.value > cutoff }
    }

    private func appendServiceLog(_ line: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        serviceLogLines.append("[\(ts)] \(line)")
        if serviceLogLines.count > maxServiceLogLines { serviceLogLines.removeFirst() }
        onServiceLog?(serviceLogLines)
    }

    private func itemToDict(_ item: TodoItem) -> [String: Any] {
        var dict: [String: Any] = [
            "id": item.id,
            "title": item.title,
            "completed": item.completed
        ]
        if let dueAt = item.dueAt { dict["dueAt"] = dueAt }
        if let ticktickId = item.ticktickId { dict["ticktickId"] = ticktickId }
        if let isAllDay = item.isAllDay { dict["isAllDay"] = isAllDay }
        if let timeZone = item.timeZone { dict["timeZone"] = timeZone }
        return dict
    }

    private func itemToDict(_ item: TodoItemData) -> [String: Any] {
        var dict: [String: Any] = [
            "id": item.id,
            "title": item.title,
            "completed": item.completed
        ]
        if let dueAt = item.dueAt { dict["dueAt"] = dueAt }
        if let ticktickId = item.ticktickId { dict["ticktickId"] = ticktickId }
        if let isAllDay = item.isAllDay { dict["isAllDay"] = isAllDay }
        if let timeZone = item.timeZone { dict["timeZone"] = timeZone }
        return dict
    }
}

// MARK: - Errors

enum NativeServerError: LocalizedError {
    case notRunning
    case firmwareUpToDate

    var errorDescription: String? {
        switch self {
        case .notRunning: "Server is not running"
        case .firmwareUpToDate: "Device firmware is already up to date"
        }
    }
}
