#pragma once
// Minimal cJSON mock for host tests
typedef struct cJSON {
    struct cJSON* next;
    struct cJSON* prev;
    struct cJSON* child;
    int type;
    char* valuestring;
    int valueint;
    double valuedouble;
    char* string;
} cJSON;

#define cJSON_False 0
#define cJSON_True 1
#define cJSON_NULL 2
#define cJSON_Number 8
#define cJSON_String 16
#define cJSON_Array 32
#define cJSON_Object 64

#ifdef __cplusplus
extern "C" {
#endif
cJSON* cJSON_Parse(const char* value);
void cJSON_Delete(cJSON* item);
cJSON* cJSON_GetObjectItem(const cJSON* const object, const char* const string);
cJSON* cJSON_GetObjectItemCaseSensitive(const cJSON* const object, const char* const string);
char* cJSON_Print(const cJSON* item);
int cJSON_GetArraySize(const cJSON* array);
cJSON* cJSON_GetArrayItem(const cJSON* array, int index);
int cJSON_IsString(const cJSON* const item);
int cJSON_IsBool(const cJSON* const item);
int cJSON_IsTrue(const cJSON* const item);
int cJSON_IsFalse(const cJSON* const item);
#ifdef __cplusplus
}
#endif
