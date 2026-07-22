#pragma once
#include "FreeRTOS.h"

EventGroupHandle_t xEventGroupCreate(void);
uint32_t xEventGroupWaitBits(EventGroupHandle_t xEventGroup, const uint32_t uxBitsToWaitFor, const BaseType_t xClearOnExit, const BaseType_t xWaitForAllBits, TickType_t xTicksToWait);
uint32_t xEventGroupSetBits(EventGroupHandle_t xEventGroup, const uint32_t uxBitsToSet);
uint32_t xEventGroupClearBits(EventGroupHandle_t xEventGroup, const uint32_t uxBitsToClear);
void vEventGroupDelete(EventGroupHandle_t xEventGroup);
