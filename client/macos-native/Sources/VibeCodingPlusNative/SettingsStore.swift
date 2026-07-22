import Foundation

struct SettingsStore {
    let configDirectory: URL

    init() {
        configDirectory = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/vibecoding-plus", isDirectory: true)
    }

    var configURL: URL { configDirectory.appendingPathComponent("config.env") }
    var desktopSettingsURL: URL { configDirectory.appendingPathComponent("desktop-settings.json") }

    func loadConfig() -> AppConfig {
        let values = readEnv()
        var config = AppConfig()
        config.openaiApiKey = values["OPENAI_API_KEY"] ?? ""
        config.openaiModel = values["OPENAI_TRANSCRIBE_MODEL"] ?? config.openaiModel
        config.openaiBaseUrl = values["OPENAI_BASE_URL"] ?? values["OPENAI_API_BASE"] ?? ""
        config.volcengineAppKey = values["VOLCENGINE_APP_KEY"] ?? ""
        config.volcengineAccessKey = values["VOLCENGINE_ACCESS_KEY"] ?? ""
        config.whisperCppModelPath = values["WHISPER_CPP_MODEL_PATH"] ?? ""
        config.whisperCppLanguage = values["WHISPER_CPP_LANGUAGE"] ?? config.whisperCppLanguage
        config.whisperCppThreads = values["WHISPER_CPP_THREADS"] ?? config.whisperCppThreads
        config.whisperCppCommand = values["WHISPER_CPP_COMMAND"] ?? config.whisperCppCommand
        config.whisperCppExtraArgs = values["WHISPER_CPP_EXTRA_ARGS"] ?? ""
        config.qwenAsrApiKey = values["QWEN_ASR_API_KEY"] ?? ""
        config.qwenAsrModel = values["QWEN_ASR_MODEL"] ?? config.qwenAsrModel
        config.qwenAsrLanguage = values["QWEN_ASR_LANGUAGE"] ?? config.qwenAsrLanguage
        config.qwenAsrPrompt = values["QWEN_ASR_PROMPT"] ?? ""
        config.qwenAsrSampleRate = values["QWEN_ASR_SAMPLE_RATE"] ?? config.qwenAsrSampleRate
        config.qwenAsrRealtimeBaseUrl = values["QWEN_ASR_REALTIME_BASE_URL"] ?? config.qwenAsrRealtimeBaseUrl
        config.lanSharedSecret = values["LAN_SHARED_SECRET"] ?? ""
        config.deepSeekApiKey = values["DEEPSEEK_API_KEY"] ?? ""
        config.deepSeekModel = values["DEEPSEEK_MODEL"] ?? "deepseek-chat"
        config.deepSeekBaseUrl = values["DEEPSEEK_BASE_URL"] ?? "https://api.deepseek.com"
        config.mockTranscript = values["MOCK_TRANSCRIPT"] ?? ""
        config.port = Int(values["PORT"] ?? "") ?? 8765
        config.discoveryHostId = values["LAN_DISCOVERY_HOST_ID"] ?? "VibeServer"
        config.discoveryPort = Int(values["LAN_DISCOVERY_PORT"] ?? "") ?? 8766
        config.displayTodoRefreshMs = Int(values["DISPLAY_TODO_REFRESH_MS"] ?? "") ?? 2000
        config.displayStyle = values["DISPLAY_STYLE"] ?? "light"
        config.ticktickToken = values["TICKTICK_TOKEN"] ?? ""

        // Auto-detect CLI commands (find full path if not explicitly set)
        config.whisperCppCommand = values["WHISPER_CPP_COMMAND"] ?? autoDetect("whisper-cli")

        // Auto-detect STT provider
        config.sttProvider = STTProvider(rawValue: values["STT_PROVIDER"] ?? "") ?? inferredProvider(values)

        return config
    }

    func saveConfig(_ config: AppConfig) throws {
        var values = readEnv()
        values["STT_PROVIDER"] = config.sttProvider.rawValue
        values["OPENAI_API_KEY"] = nilIfEmpty(config.openaiApiKey)
        values["OPENAI_TRANSCRIBE_MODEL"] = nilIfEmpty(config.openaiModel)
        values["OPENAI_BASE_URL"] = nilIfEmpty(config.openaiBaseUrl)
        values["VOLCENGINE_APP_KEY"] = nilIfEmpty(config.volcengineAppKey)
        values["VOLCENGINE_ACCESS_KEY"] = nilIfEmpty(config.volcengineAccessKey)
        values["WHISPER_CPP_MODEL_PATH"] = nilIfEmpty(config.whisperCppModelPath)
        values["WHISPER_CPP_LANGUAGE"] = nilIfEmpty(config.whisperCppLanguage)
        values["WHISPER_CPP_THREADS"] = nilIfEmpty(config.whisperCppThreads)
        values["WHISPER_CPP_COMMAND"] = nilIfEmpty(config.whisperCppCommand)
        values["WHISPER_CPP_EXTRA_ARGS"] = nilIfEmpty(config.whisperCppExtraArgs)
        values["QWEN_ASR_API_KEY"] = nilIfEmpty(config.qwenAsrApiKey)
        values["QWEN_ASR_MODEL"] = nilIfEmpty(config.qwenAsrModel)
        values["QWEN_ASR_LANGUAGE"] = nilIfEmpty(config.qwenAsrLanguage)
        values["QWEN_ASR_PROMPT"] = nilIfEmpty(config.qwenAsrPrompt)
        values["QWEN_ASR_SAMPLE_RATE"] = nilIfEmpty(config.qwenAsrSampleRate)
        values["QWEN_ASR_REALTIME_BASE_URL"] = nilIfEmpty(config.qwenAsrRealtimeBaseUrl)
        values["LAN_SHARED_SECRET"] = nilIfEmpty(config.lanSharedSecret)
        values["DEEPSEEK_API_KEY"] = nilIfEmpty(config.deepSeekApiKey)
        values["DEEPSEEK_MODEL"] = config.deepSeekModel != "deepseek-chat" ? config.deepSeekModel : nil
        values["DEEPSEEK_BASE_URL"] = config.deepSeekBaseUrl != "https://api.deepseek.com" ? config.deepSeekBaseUrl : nil
        values["MOCK_TRANSCRIPT"] = nilIfEmpty(config.mockTranscript)
        values["LAN_DISCOVERY_HOST_ID"] = nilIfEmpty(config.discoveryHostId)
        values["LAN_DISCOVERY_PORT"] = config.discoveryPort != 8766 ? String(config.discoveryPort) : nil
        values["DISPLAY_TODO_REFRESH_MS"] = config.displayTodoRefreshMs != 2000 ? String(config.displayTodoRefreshMs) : nil
        values["DISPLAY_STYLE"] = config.displayStyle != "light" ? config.displayStyle : nil
        values["TICKTICK_TOKEN"] = nilIfEmpty(config.ticktickToken)
        try writeEnv(values)
    }

    func loadDesktopSettings() -> DesktopSettings {
        guard let data = try? Data(contentsOf: desktopSettingsURL),
              let settings = try? JSONDecoder().decode(DesktopSettings.self, from: data) else {
            return DesktopSettings()
        }
        return settings
    }

    func saveDesktopSettings(_ settings: DesktopSettings) throws {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(settings)
        try data.write(to: desktopSettingsURL, options: .atomic)
    }

    private func readEnv() -> [String: String] {
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let index = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(line[line.index(after: index)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }
        return values
    }

    private func writeEnv(_ values: [String: String]) throws {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let body = values
            .filter { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n") + "\n"
        try body.write(to: configURL, atomically: true, encoding: .utf8)
    }

    private func inferredProvider(_ values: [String: String]) -> STTProvider {
        if values["WHISPER_CPP_MODEL_PATH"]?.isEmpty == false { return .whisperCpp }
        if values["QWEN_ASR_API_KEY"]?.isEmpty == false { return .qwenAsr }
        if values["OPENAI_API_KEY"]?.isEmpty == false { return .openai }
        return .volcengine
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Auto-detect the full path of a CLI tool.
    private func autoDetect(_ command: String) -> String {
        let found = Shell.findExecutable(command)
        return found.isEmpty ? command : found
    }
}
