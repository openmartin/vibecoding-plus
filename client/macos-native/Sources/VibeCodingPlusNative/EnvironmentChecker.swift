import AppKit
import Foundation
#if canImport(AVFoundation)
import AVFoundation
import AVFAudio
#endif

struct EnvironmentChecker {
    func check(config: AppConfig) async -> EnvironmentReport {
        let provider = config.sttProvider
        let commands = [
            "brew": "brew",
            "whisper_cpp": config.whisperCppCommand.isEmpty ? "whisper-cli" : config.whisperCppCommand
        ]

        async let brewVersion = version(command: commands["brew"] ?? "brew", args: ["--version"])
        async let whisperVersion = version(command: commands["whisper_cpp"] ?? "whisper-cli", args: ["--help"])

        let versions = await [
            "brew": brewVersion,
            "whisper_cpp": whisperVersion
        ]

        let checks = [
            tool(
                id: "brew",
                label: "Homebrew",
                command: commands["brew"] ?? "brew",
                required: false,
                installLabel: "安装 Homebrew",
                purpose: "安装 whisper.cpp 等 macOS 工具",
                note: "没有 Homebrew 时会先安装 Homebrew",
                version: versions["brew"] ?? ""
            ),
            tool(
                id: "whisper_cpp",
                label: "whisper.cpp",
                command: commands["whisper_cpp"] ?? "whisper-cli",
                required: provider == .whisperCpp,
                installLabel: "安装 whisper.cpp",
                purpose: "本地语音识别",
                note: provider == .whisperCpp ? "当前 STT provider 需要 whisper-cli 和模型文件" : "仅选择 whisper.cpp 时需要",
                version: versions["whisper_cpp"] ?? ""
            ),
            sttCheck(config: config),
            macosPermissionsCheck(config: config)
        ]

        return EnvironmentReport(
            ok: checks.allSatisfy { $0.status != "missing" },
            path: Shell.toolPath(),
            provider: provider.rawValue,
            checks: checks
        )
    }

    private func macosPermissionsCheck(config: AppConfig) -> EnvironmentCheck {
        let micGranted = MicrophonePermission.isGranted

        var missing: [String] = []
        if !micGranted { missing.append("麦克风") }

        let allRequired = micGranted
        let anyMissing = !missing.isEmpty

        var status = "optional"
        if allRequired && !anyMissing {
            status = "ok"
        } else if anyMissing {
            status = "missing"
        }

        let version = "麦克风: \(MicrophonePermission.statusText)"

        let note: String
        if anyMissing {
            note = "缺少: \(missing.joined(separator: "、"))"
        } else {
            note = "已授权所需权限"
        }

        return EnvironmentCheck(
            id: "macos_permissions",
            label: "macOS 权限",
            type: "permission",
            status: status,
            required: true,
            installable: false,
            installLabel: "",
            command: "",
            path: "",
            version: version,
            purpose: "麦克风访问",
            note: note
        )
    }

    func installScript(for toolId: String) -> String {
        let brewInstall = """
        if ! command -v brew >/dev/null 2>&1; then
          echo "Installing Homebrew..."
          NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        fi
        if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
        if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
        """

        switch toolId {
        case "brew":
            return """
            set -e
            if command -v brew >/dev/null 2>&1; then
              brew --version
              exit 0
            fi
            NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
            if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
            if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
            brew --version
            """
        case "whisper_cpp":
            return "set -e\n\(brewInstall)\nbrew install whisper-cpp\nwhisper-cli --help >/dev/null || true\necho \"whisper.cpp installed\""
        default:
            return ""
        }
    }

    func openPermissions() {
        MicrophonePermission.openSettings()
    }

    private func tool(id: String, label: String, command: String, required: Bool, installLabel: String, purpose: String, note: String, version: String) -> EnvironmentCheck {
        let found = Shell.findExecutable(command)
        let ok = !found.isEmpty
        return EnvironmentCheck(
            id: id,
            label: label,
            type: "tool",
            status: ok ? "ok" : required ? "missing" : "optional",
            required: required,
            installable: !ok,
            installLabel: installLabel,
            command: command,
            path: found,
            version: version,
            purpose: purpose,
            note: note
        )
    }

    private func sttCheck(config: AppConfig) -> EnvironmentCheck {
        let missing: String
        switch config.sttProvider {
        case .volcengine:
            missing = config.volcengineAppKey.isEmpty || config.volcengineAccessKey.isEmpty ? "Volcengine App Key / Access Key 未填写" : ""
        case .openai:
            missing = config.openaiApiKey.isEmpty ? "OpenAI API Key 未填写" : ""
        case .whisperCpp:
            missing = config.whisperCppModelPath.isEmpty ? "whisper.cpp 模型路径未填写" : ""
        case .qwenAsr:
            missing = config.qwenAsrApiKey.isEmpty ? "Qwen ASR API Key 未填写" : ""
        }

        return EnvironmentCheck(
            id: "stt_config",
            label: "STT 密钥 / 模型",
            type: "config",
            status: missing.isEmpty ? "ok" : "missing",
            required: true,
            installable: false,
            installLabel: "",
            command: "",
            path: SettingsStore().configURL.path,
            version: "",
            purpose: "语音转文字",
            note: missing.isEmpty ? "语音识别配置完整" : missing
        )
    }

    private func version(command: String, args: [String]) async -> String {
        let executable = Shell.findExecutable(command)
        guard !executable.isEmpty else { return "" }
        let result = await Shell.run(executable, arguments: args, timeout: 4)
        return result.output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
    }
}
