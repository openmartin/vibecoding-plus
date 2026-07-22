#pragma once
#include <stdint.h>

typedef void* esp_timer_handle_t;
typedef void (*esp_timer_cb_t)(void* arg);

typedef enum {
    ESP_TIMER_TASK = 0,
    ESP_TIMER_ISR,
} esp_timer_dispatch_t;

typedef struct {
    esp_timer_cb_t callback;
    void* arg;
    esp_timer_dispatch_t dispatch_method;
    const char* name;
    bool skip_unhandled_events;
} esp_timer_create_args_t;

int esp_timer_create(const esp_timer_create_args_t* create_args, esp_timer_handle_t* out_handle);
int esp_timer_start_once(esp_timer_handle_t timer, uint64_t timeout_us);
int esp_timer_start_periodic(esp_timer_handle_t timer, uint64_t period_us);
int esp_timer_stop(esp_timer_handle_t timer);
int esp_timer_delete(esp_timer_handle_t timer);
int64_t esp_timer_get_time(void);
