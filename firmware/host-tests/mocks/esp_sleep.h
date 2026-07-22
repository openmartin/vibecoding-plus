#pragma once
#include <stdint.h>

typedef enum {
    ESP_SLEEP_WAKEUP_UNDEFINED = 0,
    ESP_SLEEP_WAKEUP_ALL,
    ESP_SLEEP_WAKEUP_EXT0,
    ESP_SLEEP_WAKEUP_EXT1,
    ESP_SLEEP_WAKEUP_TIMER,
    ESP_SLEEP_WAKEUP_TOUCHPAD,
    ESP_SLEEP_WAKEUP_ULP,
    ESP_SLEEP_WAKEUP_GPIO,
    ESP_SLEEP_WAKEUP_UART,
    ESP_SLEEP_WAKEUP_WIFI,
    ESP_SLEEP_WAKEUP_COCPU,
    ESP_SLEEP_WAKEUP_COCPU_TRAP_TRIG,
    ESP_SLEEP_WAKEUP_BT,
} esp_sleep_wakeup_cause_t;

typedef enum {
    ESP_SLEEP_MODE_LIGHT_SLEEP = 0,
    ESP_SLEEP_MODE_DEEP_SLEEP,
} esp_sleep_mode_t;

esp_sleep_wakeup_cause_t esp_sleep_get_wakeup_cause(void);
void esp_sleep_enable_timer_wakeup(uint64_t time_in_us);
void esp_sleep_enable_ext0_wakeup(int gpio_num, int level);
void esp_sleep_enable_ext1_wakeup(uint64_t mask, int mode);
void esp_sleep_enable_gpio_wakeup(void);
void esp_sleep_disable_wakeup_source(uint64_t source);
void esp_deep_sleep_start(void);
void esp_light_sleep_start(void);
uint64_t esp_sleep_get_ext1_wakeup_status(void);
