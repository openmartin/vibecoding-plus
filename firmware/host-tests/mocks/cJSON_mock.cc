#include "cJSON.h"
#include <cstring>
#include <cstdlib>

// Minimal cJSON implementation for host tests (only what's needed)

cJSON* cJSON_Parse(const char* value) {
    (void)value;
    return nullptr;
}

void cJSON_Delete(cJSON* item) {
    (void)item;
}

cJSON* cJSON_GetObjectItem(const cJSON* const object, const char* const string) {
    (void)object; (void)string;
    return nullptr;
}

cJSON* cJSON_GetObjectItemCaseSensitive(const cJSON* const object, const char* const string) {
    (void)object; (void)string;
    return nullptr;
}

char* cJSON_Print(const cJSON* item) {
    (void)item;
    return nullptr;
}

int cJSON_GetArraySize(const cJSON* array) {
    (void)array;
    return 0;
}

cJSON* cJSON_GetArrayItem(const cJSON* array, int index) {
    (void)array; (void)index;
    return nullptr;
}

int cJSON_IsString(const cJSON* const item) {
    return item && (item->type & 0xFF) == cJSON_String;
}

int cJSON_IsBool(const cJSON* const item) {
    return item && ((item->type & 0xFF) == cJSON_False || (item->type & 0xFF) == cJSON_True);
}

int cJSON_IsTrue(const cJSON* const item) {
    return item && (item->type & 0xFF) == cJSON_True;
}

int cJSON_IsFalse(const cJSON* const item) {
    return item && (item->type & 0xFF) == cJSON_False;
}
