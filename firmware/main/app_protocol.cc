#include "lan_mic_app.h"
#include "lan_mic_app_internal.h"
#include "app_ota.h"
#include "protocol_messages.h"

#include <esp_app_desc.h>
#include <cJSON.h>
#include <driver/gpio.h>
#include <esp_log.h>
#include <esp_random.h>
#include <esp_system.h>
#include <esp_timer.h>
#include <lwip/inet.h>
#include <lwip/sockets.h>
#include <mbedtls/md.h>

#include <algorithm>
#include <cmath>
#include <cerrno>
#include <fcntl.h>
#include <cstring>
#include <cstdio>
#include <ctime>
#include <cctype>
#include <string>
#include <vector>

#include <esp_sleep.h>
#include <esp_wifi.h>
#include <esp_netif.h>

#include "board.h"
#include "boards/zectrix-s3-epaper-4.2/config.h"
#include "boards/zectrix-s3-epaper-4.2/rtc_pcf8563.h"

#include "boards/zectrix/zectrix_nfc.h"
extern "C" void ZectrixSetFactoryLedOverride(bool enabled, bool blink);
extern "C" ZectrixNfc* __attribute__((weak)) ZectrixGetNfc();
extern "C" RtcPcf8563* __attribute__((weak)) ZectrixGetRtc();
#include "display.h"
#include "network_interface.h"
#include "settings.h"
#include "ssid_manager.h"
#include "wifi_manager.h"
#include "web_socket.h"

#ifndef CONFIG_LAN_MIC_SERVER_URI
#define CONFIG_LAN_MIC_SERVER_URI ""
#endif
#ifndef CONFIG_LAN_DISCOVERY_ENABLED
#define CONFIG_LAN_DISCOVERY_ENABLED 1
#endif
#ifndef CONFIG_LAN_DISCOVERY_PORT
#define CONFIG_LAN_DISCOVERY_PORT 8766
#endif
#ifndef CONFIG_LAN_DISCOVERY_HOST_ID
#define CONFIG_LAN_DISCOVERY_HOST_ID ""
#endif
#ifndef CONFIG_LAN_SHARED_SECRET
#define CONFIG_LAN_SHARED_SECRET ""
#endif

bool LanMicApp::SendJson(const char* json) {
    if (ws_ == nullptr || !ws_->IsConnected()) {
        return false;
    }
    if (!ws_->Send(json)) {
        ESP_LOGW(kLanMicTag, "Failed to send json: %s", json);
        DisconnectWebSocket();
        return false;
    }
    return true;
}

bool LanMicApp::SendJsonObject(cJSON* root) {
    if (root == nullptr) {
        return false;
    }
    char* printed = cJSON_PrintUnformatted(root);
    if (printed == nullptr) {
        cJSON_Delete(root);
        return false;
    }
    const bool ok = SendJson(printed);
    cJSON_free(printed);
    cJSON_Delete(root);
    return ok;
}

namespace {

int64_t NowMs() {
    return static_cast<int64_t>(esp_timer_get_time() / 1000);
}

} // namespace

bool LanMicApp::SendHello() {
    if (hello_sent_) {
        return true;
    }

    const std::string auth_nonce = MakeAuthNonce();
    std::string auth_sig;
    if (!GetSharedSecret().empty()) {
        if (!auth_challenge_received_ || auth_server_nonce_.empty()) {
            return false;
        }
        auth_sig = HmacSha256Hex({
            "hello",
            board_.GetUuid(),
            board_.GetBoardType(),
            auth_server_nonce_,
            auth_nonce
        });
    }

    cJSON* root = cJSON_CreateObject();
    if (root == nullptr) {
        return false;
    }
    cJSON_AddStringToObject(root, "type", LAN_MSG_DEVICE_HELLO);
    cJSON_AddStringToObject(root, "deviceId", board_.GetUuid().c_str());
    cJSON_AddStringToObject(root, "boardType", board_.GetBoardType().c_str());
    if (!auth_sig.empty()) {
        cJSON_AddStringToObject(root, "authServerNonce", auth_server_nonce_.c_str());
        cJSON_AddStringToObject(root, "authNonce", auth_nonce.c_str());
        cJSON_AddStringToObject(root, "authSig", auth_sig.c_str());
    }
    hello_sent_ = SendJsonObject(root);
    return hello_sent_;
}

bool LanMicApp::SendPttStart() {
    cJSON* root = cJSON_CreateObject();
    if (root == nullptr) {
        return false;
    }
    cJSON_AddStringToObject(root, "type", LAN_MSG_DEVICE_PTT_START);
    cJSON_AddNumberToObject(root, "ts", static_cast<double>(NowMs()));
    return SendJsonObject(root);
}

bool LanMicApp::SendPttStop() {
    cJSON* root = cJSON_CreateObject();
    if (root == nullptr) {
        return false;
    }
    cJSON_AddStringToObject(root, "type", LAN_MSG_DEVICE_PTT_STOP);
    cJSON_AddNumberToObject(root, "ts", static_cast<double>(NowMs()));
    return SendJsonObject(root);
}

bool LanMicApp::SendTodoCommand(const char* action, int index, int completed, const char* id) {
    if (action == nullptr) {
        return false;
    }
    cJSON* root = cJSON_CreateObject();
    if (root == nullptr) {
        return false;
    }
    cJSON_AddStringToObject(root, "type", LAN_MSG_DEVICE_TODO_COMMAND);
    cJSON_AddStringToObject(root, "action", action);
    if (index > 0) {
        cJSON_AddNumberToObject(root, "index", index);
    }
    if (completed >= 0) {
        cJSON_AddBoolToObject(root, "completed", completed != 0);
    }
    if (id != nullptr && id[0] != '\0') {
        cJSON_AddStringToObject(root, "id", id);
    }
    return SendJsonObject(root);
}

bool LanMicApp::SendFirmwareProgress(const char* phase, int pct, const char* error) {
    cJSON* root = cJSON_CreateObject();
    if (root == nullptr) {
        return false;
    }
    cJSON_AddStringToObject(root, "type", LAN_MSG_DEVICE_FIRMWARE_PROGRESS);
    cJSON_AddStringToObject(root, "phase", phase != nullptr ? phase : "");
    cJSON_AddNumberToObject(root, "pct", pct);
    if (error != nullptr && error[0] != '\0') {
        cJSON_AddStringToObject(root, "error", error);
    }
    return SendJsonObject(root);
}

bool LanMicApp::SendFirmwareResult(bool ok, const char* version, const char* message) {
    cJSON* root = cJSON_CreateObject();
    if (root == nullptr) {
        return false;
    }
    cJSON_AddStringToObject(root, "type", LAN_MSG_DEVICE_FIRMWARE_RESULT);
    cJSON_AddBoolToObject(root, "ok", ok);
    if (version != nullptr && version[0] != '\0') {
        cJSON_AddStringToObject(root, "version", version);
    }
    if (message != nullptr && message[0] != '\0') {
        cJSON_AddStringToObject(root, "message", message);
    }
    return SendJsonObject(root);
}

bool LanMicApp::SendFirmwareCheckResult(bool need_upgrade, const char* current_version) {
    cJSON* root = cJSON_CreateObject();
    if (root == nullptr) {
        return false;
    }
    cJSON_AddStringToObject(root, "type", LAN_MSG_DEVICE_FIRMWARE_CHECK_RESULT);
    cJSON_AddBoolToObject(root, "needUpgrade", need_upgrade);
    if (current_version != nullptr && current_version[0] != '\0') {
        cJSON_AddStringToObject(root, "version", current_version);
    }
    return SendJsonObject(root);
}

void LanMicApp::HandleFirmwareCheck(cJSON* root) {
    const char* version = GetJsonString(root, "version");
    const esp_app_desc_t* app = esp_app_get_description();
    const char* current = (app != nullptr) ? app->version : "";
    bool need_upgrade = true;
    if (version != nullptr && version[0] != '\0' && current[0] != '\0') {
        need_upgrade = strcmp(version, current) != 0;
    }
    SendFirmwareCheckResult(need_upgrade, current);
}

void LanMicApp::HandleFirmwareOffer(cJSON* root) {
    if (IsFirmwareOtaRunning()) {
        return;
    }
    const char* url = GetJsonString(root, "url");
    const char* version = GetJsonString(root, "version");
    const char* sha256 = GetJsonString(root, "sha256");
    cJSON* size_item = cJSON_GetObjectItemCaseSensitive(root, "size");
    const size_t size = cJSON_IsNumber(size_item) ? static_cast<size_t>(size_item->valueint) : 0;
    if (url == nullptr || url[0] == '\0') {
        return;
    }

    phase_ = Phase::Upgrading;
    status_text_ = "固件升级";
    hint_text_ = "准备下载...";
    UpdateDisplay();

    FirmwareOtaOffer offer;
    offer.url = url;
    if (version != nullptr) {
        offer.version = version;
    }
    if (sha256 != nullptr) {
        offer.sha256_hex = sha256;
    }
    offer.size = size;

    StartFirmwareOta(offer, [this, offer](const char* phase, int pct, const char* error) {
        if (phase != nullptr && strcmp(phase, "result") == 0) {
            SendFirmwareResult(error == nullptr, offer.version.c_str(), error != nullptr ? error : "ok");
            return;
        }
        SendFirmwareProgress(phase, pct, error);
        if (error != nullptr && error[0] != '\0') {
            phase_ = Phase::Error;
            status_text_ = "升级失败";
            hint_text_ = error;
            UpdateDisplay();
        } else if (phase != nullptr) {
            hint_text_ = phase;
            UpdateDisplay();
        }
    });
}

void LanMicApp::HandleServerMessage(const char* data, size_t len) {
    std::string text(data, len);
    ESP_LOGI(kLanMicTag, "Server: %s", text.c_str());

    cJSON* root = cJSON_ParseWithLength(data, len);
    if (root == nullptr) {
        ESP_LOGW(kLanMicTag, "Failed to parse server json");
        return;
    }

    const char* type = GetJsonString(root, "type");
    if (type == nullptr) {
        cJSON_Delete(root);
        return;
    }

    if (strcmp(type, LAN_MSG_SERVER_AUTH_CHALLENGE) == 0) {
        const char* server_nonce = GetJsonString(root, "serverNonce");
        if (server_nonce != nullptr && server_nonce[0] != '\0') {
            auth_server_nonce_ = server_nonce;
            auth_challenge_received_ = true;
            SendHello();
        }
    } else if (strcmp(type, LAN_MSG_SERVER_HELLO_ACK) == 0) {
        status_text_ = "就绪";
        offline_todo_mode_ = false;
        reconnect_stuck_prompt_ = false;
        todo_menu_open_ = false;
        phase_ = Phase::Idle;
        // 连上服务器：上升双音
        PlayBeep(600, 80);
        PlayBeep(900, 100);
    } else if (strcmp(type, LAN_MSG_SERVER_SERVER_READY) == 0) {
        status_text_ = "就绪";
        offline_todo_mode_ = false;
        reconnect_stuck_prompt_ = false;
        todo_menu_open_ = false;
        phase_ = Phase::Idle;
        cJSON* protocol_version = cJSON_GetObjectItemCaseSensitive(root, "protocolVersion");
        if (cJSON_IsNumber(protocol_version)) {
            const int remote = protocol_version->valueint;
            if (remote != kProtocolVersion) {
                ESP_LOGW(kLanMicTag,
                         "Protocol version mismatch: peer=%d local=%d",
                         remote,
                         kProtocolVersion);
            }
        }
        UpdateDisplay();
    } else if (strcmp(type, LAN_MSG_SERVER_DISPLAY_CONFIG) == 0) {
        cJSON* todo_refresh_ms = cJSON_GetObjectItemCaseSensitive(root, "todoRefreshMs");
        const char* style = GetJsonString(root, "style");

        if (cJSON_IsNumber(todo_refresh_ms)) {
            display_todo_refresh_ms_ = std::clamp(todo_refresh_ms->valueint, 200, 10000);
        }
        if (style != nullptr) {
            display_dark_style_ = std::strcmp(style, "dark") == 0;
        }

        if (display_ != nullptr) {
            display_->SetSampleIntervalMs(display_todo_refresh_ms_);
            display_->SetInverted(display_dark_style_);
        }
        UpdateDisplay();
    } else if (strcmp(type, LAN_MSG_SERVER_FORCE_REFRESH) == 0) {
        UpdateDisplay();
    } else if (strcmp(type, LAN_MSG_SERVER_TODO_STATE) == 0) {
        cJSON* items = cJSON_GetObjectItemCaseSensitive(root, "items");
        cJSON* selected_index = cJSON_GetObjectItemCaseSensitive(root, "selectedIndex");
        const char* last_action = GetJsonString(root, "lastActionText");
        todo_items_.clear();
        if (cJSON_IsArray(items)) {
            cJSON* item = nullptr;
            cJSON_ArrayForEach(item, items) {
                const char* id = GetJsonString(item, "id");
                const char* title = GetJsonString(item, "title");
                if (title == nullptr) {
                    continue;
                }
                todo_items_.push_back({
                    id != nullptr ? id : "",
                    title,
                    GetJsonBool(item, "completed", false),
                    GetJsonString(item, "dueAt") != nullptr ? GetJsonString(item, "dueAt") : ""
                });
            }
        }
        if (cJSON_IsNumber(selected_index)) {
            todo_selected_index_ = selected_index->valueint;
        } else {
            todo_selected_index_ = todo_items_.empty() ? -1 : 0;
        }
        if (todo_items_.empty()) {
            todo_selected_index_ = -1;
        } else {
            todo_selected_index_ = std::clamp(
                todo_selected_index_,
                0,
                static_cast<int>(todo_items_.size()) - 1);
        }
        if (last_action != nullptr) {
            todo_last_action_text_ = last_action;
        }
        SaveCachedTodoState();
        offline_todo_mode_ = false;
        reconnect_stuck_prompt_ = false;
        FlushPendingTodoOps();
        // 收到新的待办状态后立即刷新屏幕显示
        if (phase_ != Phase::Recording && phase_ != Phase::Transcribing) {
            active_page_ = Page::Todo;
            UpdateDisplay();
        }
    } else if (strcmp(type, LAN_MSG_SERVER_TODO_RESULT) == 0) {
        const char* message = GetJsonString(root, "message");
        const bool ok = GetJsonBool(root, "ok", false);
        phase_ = Phase::Idle;
        status_text_ = ok ? "待办" : "待办错误";
        hint_text_ = message != nullptr ? message : "";
        if (message != nullptr) {
            todo_last_action_text_ = message;
        }
        active_page_ = Page::Todo;
    } else if (strcmp(type, LAN_MSG_SERVER_STATUS) == 0) {
        const char* status = GetJsonString(root, "status");
        if (status != nullptr) {
            if (strcmp(status, "recording") == 0) {
                phase_ = Phase::Recording;
                status_text_ = "录音中";
                active_page_ = Page::Todo;
            } else if (strcmp(status, "transcribing") == 0) {
                phase_ = Phase::Transcribing;
                status_text_ = "转写中";
                active_page_ = Page::Todo;
                PlayBeep(660, 80);   // 停止录音/转录中：短低音
            } else if (strcmp(status, "empty_segment") == 0 || strcmp(status, "transcript_empty") == 0) {
                phase_ = Phase::Idle;
                status_text_ = "未检测到语音";
                hint_text_ = "请重试";
                ShowIdleTodoPage();
            } else if (strcmp(status, "no_pending") == 0) {
                phase_ = Phase::Idle;
                status_text_ = "无待处理内容";
                ShowIdleTodoPage();
            } else {
                status_text_ = status;
            }
        }
    } else if (strcmp(type, LAN_MSG_SERVER_TRANSCRIPT_PARTIAL) == 0) {
        phase_ = Phase::Transcribing;
        status_text_ = "转写中";
        active_page_ = Page::Todo;
    } else if (strcmp(type, LAN_MSG_SERVER_TRANSCRIPT_FINAL) == 0) {
        phase_ = Phase::Idle;
        status_text_ = "待办输入";
        active_page_ = Page::Todo;
    } else if (strcmp(type, LAN_MSG_SERVER_TRANSCRIPT_CLEARED) == 0) {
        phase_ = Phase::Idle;
        status_text_ = "已清除";
        ShowIdleTodoPage();
    } else if (strcmp(type, LAN_MSG_SERVER_ERROR) == 0) {
        const char* error = GetJsonString(root, "error");
        phase_ = Phase::Error;
        status_text_ = "错误";
        hint_text_ = (error != nullptr) ? error : "未知错误";
    } else if (strcmp(type, LAN_MSG_SERVER_WARNING) == 0) {
        const char* warning = GetJsonString(root, "warning");
        status_text_ = "警告";
        hint_text_ = (warning != nullptr) ? warning : "";
    } else if (strcmp(type, LAN_MSG_SERVER_FIRMWARE_CHECK) == 0) {
        HandleFirmwareCheck(root);
    } else if (strcmp(type, LAN_MSG_SERVER_FIRMWARE_OFFER) == 0) {
        HandleFirmwareOffer(root);
    } else if (strcmp(type, LAN_MSG_SERVER_PROVISION_SECRET) == 0) {
        const char* secret = GetJsonString(root, "secret");
        const char* host_id = GetJsonString(root, "hostId");
        const char* host_name = GetJsonString(root, "hostName");
        if (secret != nullptr && secret[0] != '\0') {
            SaveSharedSecret(secret);
            if (host_id != nullptr && host_id[0] != '\0') {
                SavePairedHost(host_id, host_name != nullptr ? host_name : "");
            }
            hint_text_ = "密钥已保存";
            if (IsServerConnected()) {
                status_text_ = "就绪";
            } else {
                status_text_ = "已配对";
            }
        }
    }

    cJSON_Delete(root);
    UpdateDisplay();
}
