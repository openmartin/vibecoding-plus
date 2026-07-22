#pragma once
#include <stdint.h>
#include <stddef.h>

typedef void* TaskHandle_t;
typedef void* QueueHandle_t;
typedef void* SemaphoreHandle_t;
typedef void* EventGroupHandle_t;
typedef uint32_t TickType_t;
typedef uint32_t UBaseType_t;
typedef int32_t BaseType_t;

#define pdTRUE 1
#define pdFALSE 0
#define pdPASS 1
#define pdFAIL 0
#define portMAX_DELAY 0xFFFFFFFF

#define configTICK_RATE_HZ 1000
#define pdMS_TO_TICKS(ms) ((ms) * configTICK_RATE_HZ / 1000)

#define tskIDLE_PRIORITY 0
#define configMAX_PRIORITIES 25

#define eventGroupWaitBitsWaitForAll 0x01
#define eventGroupWaitBitsClearOnExit 0x02

typedef void (*TaskFunction_t)(void*);
