#include "lan_mic_app.h"
#include "lan_mic_app_internal.h"

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

const char* LanMicApp::GetNetworkLabel() const {
    if (offline_todo_mode_ && network_state_ != NetworkState::Server) {
        return "离线";
    }
    switch (network_state_) {
        case NetworkState::Server:
            return "在线";
        case NetworkState::Wifi:
            return "无服务器";
        case NetworkState::Config:
            return "配网";
        case NetworkState::Offline:
        default:
            return "离线";
    }
}

const char* LanMicApp::GetModeLabel() const {
    return "待办";
}

std::string LanMicApp::GetPhaseLabel() const {
    switch (phase_) {
        case Phase::Recording:
            return "● 录音";
        case Phase::Transcribing:
            return "... 转写";
        case Phase::Upgrading:
            return "↑ 升级中";
        case Phase::Error:
            return "! 错误";
        case Phase::Idle:
        default:
            return "";
    }
}

bool LanMicApp::ShouldShowIdleTodoPage() const {
    return offline_todo_mode_ &&
           phase_ == Phase::Idle &&
           active_page_ != Page::Log &&
           active_page_ != Page::Settings &&
           !todo_menu_open_;
}

void LanMicApp::ShowIdleTodoPage() {
    if (ShouldShowIdleTodoPage()) {
        active_page_ = Page::Todo;
    }
}

std::string LanMicApp::GetFooterText() const {
    if (phase_ == Phase::Recording) {
        return "松开 BOOT 停止";
    }
    if (network_state_ == NetworkState::Config) {
        return "连接 AP 后打开 192.168.4.1";
    }
    if (todo_menu_open_) {
        return "↑/↓ 菜单 | BOOT 确认";
    }
    if (active_page_ == Page::Settings) {
        return settings_editing_volume_ ? "↑/↓ ±10 | BOOT 保存"
                                        : "↑/↓ 导航 | BOOT 确认 | 长按↑返回";
    }
    if (active_page_ == Page::Todo) {
        return IsServerConnected()
            ? "长按↑菜单 | 长按添加/短按完成"
            : "长按↑菜单 | ↑/↓ 选择";
    }
    return "↑/↓ 滚动 | 长按↑ | 长按↓设置";
}

std::vector<std::string> LanMicApp::WrapText(const std::string& text, size_t max_chars) const {
    return WrapUtf8Lines(text, max_chars, 0);
}

std::vector<std::string> LanMicApp::SliceLines(const std::vector<std::string>& lines, int offset, size_t max_lines) const {
    std::vector<std::string> visible;
    if (lines.empty()) {
        return visible;
    }

    const int clamped_offset = std::max(0, offset);
    const size_t start = static_cast<size_t>(clamped_offset);
    const size_t end = std::min(lines.size(), start + max_lines);
    for (size_t i = start; i < end; ++i) {
        visible.push_back(lines[i]);
    }
    return visible;
}

void LanMicApp::UpdateLed() {
    switch (phase_) {
        case Phase::Recording:
            ZectrixSetFactoryLedOverride(true, true);   // blink only while actively recording
            break;
        case Phase::Error:
            ZectrixSetFactoryLedOverride(true, false);  // keep LED off; error is shown on e-paper
            break;
        case Phase::Transcribing:
        case Phase::Upgrading:
            ZectrixSetFactoryLedOverride(true, false);  // keep LED off; status is shown on e-paper
            break;
        case Phase::Idle:
        default:
            ZectrixSetFactoryLedOverride(true, false);  // suppress distracting charge blink
            break;
    }
}

void LanMicApp::PlayBeep(int freq_hz, int duration_ms) {
    if (codec_ == nullptr || freq_hz <= 0 || duration_ms <= 0) {
        return;
    }
    const int sample_rate = codec_->output_sample_rate() > 0 ? codec_->output_sample_rate() : 16000;
    const int num_samples = sample_rate * duration_ms / 1000;
    if (num_samples <= 0) {
        return;
    }
    const int fade = std::min(num_samples / 4, sample_rate * 8 / 1000);
    const double step = 2.0 * M_PI * freq_hz / sample_rate;
    constexpr double kAmplitude = 10000.0;

    std::vector<int16_t> pcm(num_samples);
    for (int i = 0; i < num_samples; i++) {
        double s = std::sin(step * i) * kAmplitude;
        if (i < fade) {
            s *= static_cast<double>(i) / fade;
        } else if (i > num_samples - fade) {
            s *= static_cast<double>(num_samples - i) / fade;
        }
        pcm[i] = static_cast<int16_t>(s);
    }
    codec_->EnableOutput(true);
    codec_->OutputData(pcm);
}

void LanMicApp::DrawHorizontalLine(int y, int thickness) {
    if (display_ == nullptr || thickness <= 0) {
        return;
    }

    const int width = display_->width();
    const int bytes_per_row = (width + 7) >> 3;
    std::vector<uint8_t> buffer(bytes_per_row * thickness, 0xFF);
    display_->WriteRaw1bpp(0, y, width, thickness, buffer.data(), buffer.size());
}

void LanMicApp::DrawTodoDashLine(int y, int x_start, int x_end) {
    if (display_ == nullptr || y < 0 || y >= display_->height()) {
        return;
    }
    if (x_end <= x_start) {
        return;
    }
    const int width = x_end - x_start;
    if (width <= 0) {
        return;
    }
    const int bytes_per_row = (width + 7) / 8;
    std::vector<uint8_t> row_bytes(bytes_per_row, 0x00);
    for (int x = 0; x < width; ++x) {
        const bool draw = (x % 8) < 5;
        if (!draw) {
            continue;
        }
        const int bit_index = x;
        row_bytes[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
    }
    display_->WriteRaw1bpp(x_start, y, width, 1, row_bytes.data(), row_bytes.size());
}

void LanMicApp::DrawTodoHeaderIcon(int x, int y) {
    if (display_ == nullptr) {
        return;
    }
    constexpr int w = 24;
    constexpr int h = 28;
    constexpr int bytes_per_row = (w + 7) / 8;
    std::vector<uint8_t> buffer(bytes_per_row * h, 0x00);

    auto set_pixel = [&](int px, int py) {
        if (px < 0 || px >= w || py < 0 || py >= h) {
            return;
        }
        const int bit_index = py * w + px;
        buffer[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
    };

    // 主体外框
    for (int px = 3; px <= 20; ++px) {
        set_pixel(px, 3);
        set_pixel(px, 26);
    }
    for (int py = 4; py <= 25; ++py) {
        set_pixel(3, py);
        set_pixel(20, py);
    }

    // 顶部夹子
    for (int px = 8; px <= 15; ++px) {
        set_pixel(px, 1);
        set_pixel(px, 2);
    }
    set_pixel(8, 3);
    set_pixel(15, 3);

    // 内部横线（模拟列表行）
    for (int py = 8; py <= 22; py += 3) {
        for (int px = 7; px <= 16; ++px) {
            set_pixel(px, py);
        }
    }

    display_->WriteRaw1bpp(x, y, w, h, buffer.data(), buffer.size());
}

void LanMicApp::DrawWifiIcon(int x, int y) {
    if (display_ == nullptr) {
        return;
    }
    display_->WriteRaw1bpp(x, y, 12, 12, kWifiIcon12x12, kWifiIcon12x12Size);
}

void LanMicApp::DrawBatteryIcon(int x, int y, int level, bool charging) {
    if (display_ == nullptr) {
        return;
    }

    const int clamped_level = std::clamp(level, 0, 100);
    std::vector<uint8_t> buffer(kBatteryIcon14x8, kBatteryIcon14x8 + kBatteryIcon14x8Size);
    int fill_columns = (clamped_level + 5) / 10;
    if (clamped_level > 0 && fill_columns == 0) {
        fill_columns = 1;
    }
    fill_columns = std::clamp(fill_columns, 0, 10);

    for (int row = 1; row <= 6; ++row) {
        for (int col = 1; col <= fill_columns; ++col) {
            const int bit_index = row * 16 + col;
            buffer[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
        }
    }
    if (charging) {
        for (int row = 2; row <= 5; ++row) {
            const int bit_index = row * 16 + 5;
            buffer[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
        }
        for (int col = 4; col <= 6; ++col) {
            const int bit_index = 4 * 16 + col;
            buffer[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
        }
    }
    display_->WriteRaw1bpp(x, y, 14, 8, buffer.data(), buffer.size());
}

// =======================================================
// 大号数字时钟：3x5 像素字体，可缩放
// =======================================================

// 3x5 像素数字字模（0-9），每数字 15 bit，按行存储
static const uint8_t kDigitFont3x5[10][5] = {
    {0b111, 0b101, 0b101, 0b101, 0b111},  // 0
    {0b010, 0b110, 0b010, 0b010, 0b111},  // 1
    {0b111, 0b001, 0b111, 0b100, 0b111},  // 2
    {0b111, 0b001, 0b111, 0b001, 0b111},  // 3
    {0b101, 0b101, 0b111, 0b001, 0b001},  // 4
    {0b111, 0b100, 0b111, 0b001, 0b111},  // 5
    {0b111, 0b100, 0b111, 0b101, 0b111},  // 6
    {0b111, 0b001, 0b010, 0b010, 0b010},  // 7
    {0b111, 0b101, 0b111, 0b101, 0b111},  // 8
    {0b111, 0b101, 0b111, 0b001, 0b111},  // 9
};

void LanMicApp::DrawBigDigit(int x, int y, int digit, int scale) {
    if (display_ == nullptr || digit < 0 || digit > 9 || scale <= 0) {
        return;
    }
    const int w = 3 * scale;
    const int h = 5 * scale;
    const int bytes_per_row = (w + 7) / 8;
    std::vector<uint8_t> buf(bytes_per_row * h, 0x00);

    for (int row = 0; row < 5; ++row) {
        const uint8_t bits = kDigitFont3x5[digit][row];
        for (int col = 0; col < 3; ++col) {
            if (!((bits >> (2 - col)) & 1)) continue;
            // 填充 scale x scale 的块
            for (int sy = 0; sy < scale; ++sy) {
                for (int sx = 0; sx < scale; ++sx) {
                    const int px = col * scale + sx;
                    const int py = row * scale + sy;
                    const int bit_index = py * w + px;
                    buf[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
                }
            }
        }
    }
    display_->WriteRaw1bpp(x, y, w, h, buf.data(), buf.size());
}

void LanMicApp::DrawBigColon(int x, int y, int scale) {
    if (display_ == nullptr || scale <= 0) {
        return;
    }
    const int w = scale;
    const int h = 5 * scale;
    const int bytes_per_row = (w + 7) / 8;
    std::vector<uint8_t> buf(bytes_per_row * h, 0x00);

    // 两个点：第1行和第3行
    for (int sy = 0; sy < scale; ++sy) {
        for (int sx = 0; sx < scale; ++sx) {
            // 上点 (row=1)
            {
                const int px = sx;
                const int py = 1 * scale + sy;
                const int bit_index = py * w + px;
                buf[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
            }
            // 下点 (row=3)
            {
                const int px = sx;
                const int py = 3 * scale + sy;
                const int bit_index = py * w + px;
                buf[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
            }
        }
    }
    display_->WriteRaw1bpp(x, y, w, h, buf.data(), buf.size());
}

void LanMicApp::DrawBigClock(int x, int y, int hour, int minute) {
    if (display_ == nullptr) {
        return;
    }
    constexpr int scale = 8;   // 每个像素放大8倍 → 数字 24x40 px
    constexpr int digit_w = 3 * scale;  // 24
    constexpr int colon_w = scale;      // 8
    constexpr int spacing = 2;          // 字符间距

    const int h_tens = hour / 10;
    const int h_ones = hour % 10;
    const int m_tens = minute / 10;
    const int m_ones = minute % 10;

    int cx = x;
    DrawBigDigit(cx, y, h_tens, scale);
    cx += digit_w + spacing;
    DrawBigDigit(cx, y, h_ones, scale);
    cx += digit_w + spacing;
    DrawBigColon(cx, y, scale);
    cx += colon_w + spacing;
    DrawBigDigit(cx, y, m_tens, scale);
    cx += digit_w + spacing;
    DrawBigDigit(cx, y, m_ones, scale);
}

void LanMicApp::DrawCheckbox(int x, int y, bool checked, bool inverted) {
    if (display_ == nullptr) {
        return;
    }
    constexpr int w = 16;
    constexpr int h = 16;
    constexpr int bytes_per_row = (w + 7) / 8;
    std::vector<uint8_t> buf(bytes_per_row * h, 0x00);

    auto set_pixel = [&](int px, int py) {
        if (px < 0 || px >= w || py < 0 || py >= h) return;
        const int bit_index = py * w + px;
        buf[bit_index >> 3] |= static_cast<uint8_t>(1U << (7 - (bit_index & 7)));
    };

    // 外框 (1px 宽，更清晰)
    for (int px = 0; px < w; ++px) {
        set_pixel(px, 0);
        set_pixel(px, h - 1);
    }
    for (int py = 0; py < h; ++py) {
        set_pixel(0, py);
        set_pixel(w - 1, py);
    }

    if (checked) {
        // 绘制对勾✔图案（更直观的完成标记）
        // 对勾路径：左中 → 底部中心 → 右上
        const int cx = w / 2;  // 8
        const int cy = h / 2;  // 8
        // 左半段：从(3, cy)到(cx, h-4)
        for (int i = 0; i <= cx - 3; ++i) {
            const int px = 3 + i;
            const int py = cy - 1 + i * (cy - 3) / (cx - 3);
            set_pixel(px, py);
            set_pixel(px, py + 1);  // 加粗
        }
        // 右半段：从(cx, h-4)到(w-3, 3)
        for (int i = 0; i <= (w - 3) - cx; ++i) {
            const int px = cx + i;
            const int py = (h - 4) - i * (h - 7) / ((w - 3) - cx);
            set_pixel(px, py);
            set_pixel(px, py + 1);  // 加粗
        }
    }

    // 对于黑底白字的选中行，需要绘制白色复选框。
    // WriteRaw1bpp 输入格式：bit=1 表示黑色，bit=0 表示白色。
    // 选中行使用负片：整个区域 bit=1（黑色背景），复选框线条 bit=0（白色线条）。
    if (inverted) {
        // 先填充整个区域为黑色（bit=1）
        for (auto& byte : buf) {
            byte = 0xFF;
        }
        // 然后清除复选框线条的 bit（设为白色 bit=0）
        auto clear_pixel = [&](int px, int py) {
            if (px < 0 || px >= w || py < 0 || py >= h) return;
            const int bit_index = py * w + px;
            buf[bit_index >> 3] &= static_cast<uint8_t>(~(1U << (7 - (bit_index & 7))));
        };
        // 外框 (1px) - 白色线条
        for (int px = 0; px < w; ++px) {
            clear_pixel(px, 0);
            clear_pixel(px, h - 1);
        }
        for (int py = 0; py < h; ++py) {
            clear_pixel(0, py);
            clear_pixel(w - 1, py);
        }
        if (checked) {
            // 对勾图案 - 白色
            const int cx = w / 2;
            const int cy = h / 2;
            for (int i = 0; i <= cx - 3; ++i) {
                const int px = 3 + i;
                const int py = cy - 1 + i * (cy - 3) / (cx - 3);
                clear_pixel(px, py);
                clear_pixel(px, py + 1);
            }
            for (int i = 0; i <= (w - 3) - cx; ++i) {
                const int px = cx + i;
                const int py = (h - 4) - i * (h - 7) / ((w - 3) - cx);
                clear_pixel(px, py);
                clear_pixel(px, py + 1);
            }
        }
    }

    display_->WriteRaw1bpp(x, y, w, h, buf.data(), buf.size());
}

void LanMicApp::UpdateDisplay() {
    UpdateLed();

    if (display_ == nullptr) {
        return;
    }

    display_->SetSampleIntervalMs(display_todo_refresh_ms_);
    display_->SetInverted(display_dark_style_);

    const Page render_page = active_page_;

    std::vector<Display::TextItem> texts;
    auto single_line = [](const std::string& value, size_t max_chars) -> std::string {
        const auto lines = WrapUtf8Lines(value, max_chars, 1);
        return lines.empty() ? std::string() : lines.front();
    };

    if (render_page == Page::Todo) {
        if (todo_menu_open_) {
            // 菜单模式保持原有布局
            std::string battery_text = "--";
            if (battery_known_) {
                battery_text = std::to_string(std::clamp(battery_level_, 0, 100));
                if (battery_charging_) {
                    battery_text += "+";
                }
            }
            texts.push_back({GetNetworkLabel(), 28, 9, 16});
            texts.push_back({"待办", 96, 9, 16});
            texts.push_back({GetPhaseLabel(), 166, 9, 16});
            texts.push_back({battery_text, 346, 9, 16});

            texts.push_back({"待办菜单", 12, kLogTitleY, 16});
            std::string todo_status = todo_last_action_text_.empty() ? GetModeLabel() : todo_last_action_text_;
            if (!pending_todo_ops_.empty()) {
                todo_status = "待同步 " + std::to_string(pending_todo_ops_.size());
            }
            texts.push_back({single_line(todo_status, 16), 228, kLogTitleY, 16});

            std::vector<std::string> rows;
            if (todo_menu_kind_ == TodoMenuKind::ReconnectStuck) {
                rows.push_back("重连卡住");
            } else if (todo_menu_kind_ == TodoMenuKind::TodoAction) {
                rows.push_back("待办操作");
            } else if (!IsServerConnected()) {
                rows.push_back("离线待办");
            } else {
                rows.push_back(GetModeLabel());
            }
            const int count = GetTodoMenuItemCount();
            for (int index = 0; index < count; ++index) {
                std::string row = (index == todo_menu_selected_item_) ? "> " : "  ";
                row += GetTodoMenuItemLabel(index);
                rows.push_back(single_line(row, kBodyCharsPerLine));
            }

            int y = kLogBodyY;
            for (const auto& line : rows) {
                texts.push_back({line, 12, y, 16});
                y += kLineHeight;
            }

            texts.push_back({GetFooterText(), 12, kFooterTextY, 16});
            display_->DrawTexts(texts, true);
            DrawHorizontalLine(kStatusBarBottomY);
            DrawHorizontalLine(kHeaderLineY);
            DrawHorizontalLine(kFooterTopY);
            DrawWifiIcon(10, 8);
            DrawBatteryIcon(382, 12, battery_known_ ? battery_level_ : 0, battery_charging_);
        } else {
            // ===== 目标图片风格布局 =====
            // Header: 大时钟(位图) + 日期 + WiFi/电池图标
            // 列表: 5行待办，复选框(位图)+标题+右侧时间
            // 底部: 分页指示器

            constexpr int kTodoHeaderBottomY = 68;
            constexpr int kTodoRowStartY = 78;
            constexpr int kTodoRowHeight = 40;
            constexpr int kTodoCheckboxX = 14;
            constexpr int kTodoTitleX = 40;
            constexpr int kTodoTimeX = 230;
            constexpr int kTodoRowsVisible = 5;
            constexpr int kTodoTitleMaxChars = 10;

            // 获取时间：优先 RTC，若 RTC 数据无效则回退到系统时间（SNTP 同步后正确）
            tm todo_tm = {};
            bool has_time = false;
            RtcPcf8563* rtc = ZectrixGetRtc();
            if (rtc != nullptr) {
                has_time = rtc->GetTime(todo_tm);
            }
            // RTC 年份不在 2020~2099 范围视为无效，回退到系统时间
            if (!has_time || todo_tm.tm_year < 120 || todo_tm.tm_year > 199) {
                time_t now = time(nullptr);
                if (now > 1577836800) {  // 2020-01-01 00:00:00 UTC
                    localtime_r(&now, &todo_tm);
                    has_time = true;
                } else {
                    has_time = false;
                }
            }

            // ---- 第1步：收集所有文本项 ----
            // Header 右侧: 日期 + 星期 (右对齐，位于 WiFi/电池图标下方)
            {
                std::string date_text = has_time ? FormatTodoDateText(todo_tm) : "--/-- --";
                int text_width = 0;
                for (size_t i = 0; i < date_text.size(); ) {
                    unsigned char ch = static_cast<unsigned char>(date_text[i]);
                    if ((ch & 0xE0) == 0xC0) { text_width += 8; i += 2; }
                    else if ((ch & 0xF0) == 0xE0) { text_width += 16; i += 3; }
                    else if ((ch & 0xF8) == 0xF0) { text_width += 16; i += 4; }
                    else { text_width += 8; i += 1; }
                }
                texts.push_back({date_text, 388 - text_width, 44, 16});
            }

            if (todo_items_.empty()) {
                texts.push_back({"暂无待办", 14, 90, 24});
                texts.push_back({IsServerConnected() ? "长按\u2193打开菜单" : "离线缓存为空", 14, 130, 16});
            } else {
                const int max_start = std::max(0, static_cast<int>(todo_items_.size()) - kTodoRowsVisible);
                const int start_index = std::clamp(
                    todo_selected_index_ < 0 ? 0 : todo_selected_index_ - (kTodoRowsVisible / 2),
                    0,
                    max_start);
                const int end_index = std::min(
                    static_cast<int>(todo_items_.size()),
                    start_index + kTodoRowsVisible);

                int row_slot = 0;
                for (int index = start_index; index < end_index; ++index, ++row_slot) {
                    const auto& item = todo_items_[index];
                    const int row_y = kTodoRowStartY + (row_slot * kTodoRowHeight);
                    const bool selected = index == todo_selected_index_;

                    std::string title = single_line(item.title, selected ? kTodoTitleMaxChars - 1 : kTodoTitleMaxChars);
                    texts.push_back({title, kTodoTitleX, row_y, 24, selected});

                    // 右侧时间（人性化格式）
                    const tm* now_ptr = has_time ? &todo_tm : nullptr;
                    std::string right_text = FormatTodoRightTimeText(item.due_at, now_ptr);
                    texts.push_back({right_text, kTodoTimeX, row_y, 16, selected});
                }

                // 分页指示器（右下角）
                const int total_pages = (static_cast<int>(todo_items_.size()) + kTodoRowsVisible - 1) / kTodoRowsVisible;
                const int current_page = start_index / kTodoRowsVisible + 1;
                texts.push_back({std::to_string(current_page) + "-" + std::to_string(total_pages), 350, 280, 16});
            }

            // ---- 第2步：绘制文本（清空帧缓冲） ----
            display_->DrawTexts(texts, true);

            // ---- 第3步：绘制位图元素（在 DrawTexts 之后，避免被清空） ----
            // Header: 待办图标(24x28) + 大号时钟
            DrawTodoHeaderIcon(12, 10);
            if (has_time) {
                DrawBigClock(44, 8, todo_tm.tm_hour, todo_tm.tm_min);
            } else {
                DrawBigClock(44, 8, 0, 0);
            }

            // Header 右上角: 电池 + WiFi 图标（紧贴屏幕右边缘）
            DrawBatteryIcon(384, 10, battery_known_ ? battery_level_ : 0, battery_charging_);
            DrawWifiIcon(366, 8);

            // Header 底部分隔线（粗线）
            DrawHorizontalLine(kTodoHeaderBottomY, 2);

            // 待办列表：复选框位图 + 行间分隔线
            if (!todo_items_.empty()) {
                const int max_start = std::max(0, static_cast<int>(todo_items_.size()) - kTodoRowsVisible);
                const int start_index = std::clamp(
                    todo_selected_index_ < 0 ? 0 : todo_selected_index_ - (kTodoRowsVisible / 2),
                    0,
                    max_start);
                const int end_index = std::min(
                    static_cast<int>(todo_items_.size()),
                    start_index + kTodoRowsVisible);

                int row_slot = 0;
                for (int index = start_index; index < end_index; ++index, ++row_slot) {
                    const auto& item = todo_items_[index];
                    const int row_y = kTodoRowStartY + (row_slot * kTodoRowHeight);
                    const bool selected = index == todo_selected_index_;

                    // 复选框位图（垂直居中对齐24号文字，16px checkbox）
                    // inverted 需同时考虑全局暗色模式和行选中状态
                    const bool checkbox_inverted = display_dark_style_ != selected;
                    DrawCheckbox(kTodoCheckboxX, row_y + 4, item.completed, checkbox_inverted);

                    // 行间分隔线（每行下方都绘制，包括第5行）
                    DrawHorizontalLine(row_y + kTodoRowHeight - 4, 1);
                }
            }
        }
    } else if (render_page == Page::Log) {
        // 非 Todo 页面保持原有布局
        std::string battery_text = "--";
        if (battery_known_) {
            battery_text = std::to_string(std::clamp(battery_level_, 0, 100));
            if (battery_charging_) {
                battery_text += "+";
            }
        }
        texts.push_back({GetNetworkLabel(), 28, 9, 16});
        texts.push_back({"待办", 96, 9, 16});
        texts.push_back({GetPhaseLabel(), 166, 9, 16});
        texts.push_back({battery_text, 346, 9, 16});

        const char* page_label = "日志";
        texts.push_back({single_line(page_label, 18), 12, kContentHeaderY, 16});
        texts.push_back({page_label, 316, kContentHeaderY, 16});

        texts.push_back({"日志", 12, kLogTitleY, 16});

        std::vector<std::string> wrapped;
        wrapped.push_back("暂无日志");

        const int log_offset = std::clamp(
            log_scroll_offset_,
            0,
            std::max(0, static_cast<int>(wrapped.size()) - static_cast<int>(kLogVisibleLines)));
        int y = kLogBodyY;
        for (const auto& line : SliceLines(wrapped, log_offset, kLogVisibleLines)) {
            texts.push_back({line, 12, y, 16});
            y += kLineHeight;
        }

        texts.push_back({GetFooterText(), 12, kFooterTextY, 16});
        display_->DrawTexts(texts, true);
        DrawHorizontalLine(kStatusBarBottomY);
        DrawHorizontalLine(kHeaderLineY);
        DrawHorizontalLine(kFooterTopY);
        DrawWifiIcon(10, 8);
        DrawBatteryIcon(382, 12, battery_known_ ? battery_level_ : 0, battery_charging_);
    } else {
        // Settings page 保持原有布局
        std::string battery_text = "--";
        if (battery_known_) {
            battery_text = std::to_string(std::clamp(battery_level_, 0, 100));
            if (battery_charging_) {
                battery_text += "+";
            }
        }
        texts.push_back({GetNetworkLabel(), 28, 9, 16});
        texts.push_back({"待办", 96, 9, 16});
        texts.push_back({GetPhaseLabel(), 166, 9, 16});
        texts.push_back({battery_text, 346, 9, 16});

        const char* page_label = "设置";
        texts.push_back({single_line(page_label, 18), 12, kContentHeaderY, 16});
        texts.push_back({page_label, 316, kContentHeaderY, 16});

        texts.push_back({"设置", 12, kLogTitleY, 16});
        if (settings_editing_volume_) {
            texts.push_back({"\u2191/\u2193 \u00B110 BOOT 确认", 180, kLogTitleY, 14});
        }

        const std::string vol_label = "音量: " + std::to_string(volume_) + "%";
        const char* items[kSettingsItemCount] = {
            vol_label.c_str(),
            "重置网络",
            "重启",
            "关机"
        };

        int y = kLogBodyY;
        for (int i = 0; i < kSettingsItemCount; ++i) {
            std::string row = (i == settings_selected_item_) ? "> " : "  ";
            row += items[i];
            if (i == kSettingsItemVolume && settings_editing_volume_) {
                row += " *";
            }
            texts.push_back({row, 12, y, 16});
            y += kLineHeight * 2;
        }

        texts.push_back({GetFooterText(), 12, kFooterTextY, 16});
        display_->DrawTexts(texts, true);
        DrawHorizontalLine(kStatusBarBottomY);
        DrawHorizontalLine(kHeaderLineY);
        DrawHorizontalLine(kFooterTopY);
        DrawWifiIcon(10, 8);
        DrawBatteryIcon(382, 12, battery_known_ ? battery_level_ : 0, battery_charging_);
    }

    display_->RequestUrgentRefresh();
}
