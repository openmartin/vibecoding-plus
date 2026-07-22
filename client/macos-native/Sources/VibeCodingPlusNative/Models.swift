import Foundation

enum ServiceStatus: String {
    case stopped
    case starting
    case running
    case needsSetup
    case error

    var label: String {
        switch self {
        case .stopped: "已停止"
        case .starting: "启动中"
        case .running: "运行中"
        case .needsSetup: "待配置"
        case .error: "异常"
        }
    }
}

enum STTProvider: String, CaseIterable, Identifiable {
    case volcengine
    case openai
    case whisperCpp = "whisper_cpp"
    case qwenAsr = "qwen_asr"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .volcengine: "Volcengine"
        case .openai: "OpenAI"
        case .whisperCpp: "whisper.cpp"
        case .qwenAsr: "Qwen3-ASR"
        }
    }
}

struct EnvironmentCheck: Identifiable, Codable {
    var id: String
    var label: String
    var type: String
    var status: String
    var required: Bool
    var installable: Bool
    var installLabel: String
    var command: String
    var path: String
    var version: String
    var purpose: String
    var note: String

    var statusLabel: String {
        switch status {
        case "ok": "正常"
        case "missing": "缺失"
        case "optional": "可选"
        default: "提示"
        }
    }
}

struct EnvironmentReport {
    var ok: Bool
    var path: String
    var provider: String
    var checks: [EnvironmentCheck]
}

struct DesktopSettings: Codable {
    var autoLaunch: Bool = false
    var launchToTray: Bool = false
    var closeToTray: Bool = false
}

struct AppConfig {
    var sttProvider: STTProvider = .volcengine
    var openaiApiKey: String = ""
    var openaiModel: String = "whisper-1"
    var openaiBaseUrl: String = ""
    var volcengineAppKey: String = ""
    var volcengineAccessKey: String = ""
    var whisperCppModelPath: String = ""
    var whisperCppLanguage: String = "zh"
    var whisperCppThreads: String = "4"
    var whisperCppCommand: String = "whisper-cli"
    var whisperCppExtraArgs: String = ""
    var qwenAsrApiKey: String = ""
    var qwenAsrModel: String = "Qwen/Qwen3-ASR-0.6B"
    var qwenAsrLanguage: String = "zh"
    var qwenAsrPrompt: String = ""
    var qwenAsrSampleRate: String = "16000"
    var qwenAsrRealtimeBaseUrl: String = "wss://dashscope.aliyuncs.com/api-ws/v1/realtime"
    var lanSharedSecret: String = ""
    var deepSeekApiKey: String = ""
    var deepSeekModel: String = "deepseek-chat"
    var deepSeekBaseUrl: String = "https://api.deepseek.com"
    var port: Int = 8765
    var setupPort: Int = 8768
    var discoveryHostId: String = "VibeServer"
    var discoveryPort: Int = 8766
    var displayTodoRefreshMs: Int = 2000
    var displayStyle: String = "light"
    var mockTranscript: String = ""
    var ticktickToken: String = ""
}

struct DeviceInfo: Identifiable, Decodable {
    var connId: String?
    var deviceId: String
    var boardType: String?
    var remoteAddress: String?
    var connectedAt: Double?
    var isProvisioned: Bool = false

    var id: String { deviceId }
}

struct TodoSnapshot: Decodable {
    var items: [TodoItem] = []
    var archiveItems: [TodoItem] = []
    var selectedIndex: Int = 0
    var lastActionText: String = ""
}

struct TodoItem: Identifiable, Decodable {
    var id: String
    var title: String
    var completed: Bool
    var dueAt: String?
    var ticktickId: String?
    var isAllDay: Bool?
    var timeZone: String?
}

struct ServiceStatusPayload: Decodable {
    var ok: Bool
    var uptime: Double?
    var clientCount: Int?
    var sttProvider: String?
    var discoveryEnabled: Bool?
    var port: Int?
}

struct DisplayConfig {
    var todoRefreshMs: Int = 2000
    var style: String = "light"
}

struct LiveActivity {
    var lastTranscript: String = ""
    var serviceLogLines: [String] = []
}

enum ServiceLogFilter: String, CaseIterable, Identifiable {
    case all
    case device
    case process

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "全部"
        case .device: "设备"
        case .process: "进程"
        }
    }
}
