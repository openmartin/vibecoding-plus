#pragma once
#include <stdint.h>
#include <functional>

class GpioInputDriver {
public:
    using Callback = std::function<void(int)>;
    GpioInputDriver() = default;
    bool Initialize(int gpio_num, bool active_low, Callback callback) { return true; }
    void SetDebounceTime(uint32_t ms) {}
    void SetLongPressTime(uint32_t ms) {}
    void SetDoubleClickTime(uint32_t ms) {}
    void Poll() {}
};
