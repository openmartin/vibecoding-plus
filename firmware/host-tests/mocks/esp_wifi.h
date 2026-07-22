#pragma once
#include <stdint.h>
#include <stdbool.h>

typedef enum {
    WIFI_MODE_NULL = 0,
    WIFI_MODE_STA,
    WIFI_MODE_AP,
    WIFI_MODE_APSTA,
    WIFI_MODE_MAX,
} wifi_mode_t;

typedef enum {
    WIFI_IF_STA = 0,
    WIFI_IF_AP,
    WIFI_IF_MAX,
} wifi_interface_t;

typedef enum {
    WIFI_AUTH_OPEN = 0,
    WIFI_AUTH_WEP,
    WIFI_AUTH_WPA_PSK,
    WIFI_AUTH_WPA2_PSK,
    WIFI_AUTH_WPA_WPA2_PSK,
    WIFI_AUTH_WPA2_ENTERPRISE,
    WIFI_AUTH_WPA3_PSK,
    WIFI_AUTH_WPA2_WPA3_PSK,
    WIFI_AUTH_WAPI_PSK,
    WIFI_AUTH_MAX,
} wifi_auth_mode_t;

typedef struct {
    char ssid[32];
    char password[64];
    wifi_auth_mode_t threshold;
} wifi_sta_config_t;

typedef struct {
    wifi_sta_config_t sta;
} wifi_config_t;

typedef struct {
    uint8_t mac[6];
    int8_t rssi;
    uint8_t channel;
    char ssid[32];
    wifi_auth_mode_t authmode;
} wifi_ap_record_t;

typedef struct {
    uint32_t status;
    uint8_t number;
    int8_t rssi;
    uint8_t channel;
} wifi_sta_info_t;

typedef struct {
    bool connected;
    uint8_t ssid[32];
    uint8_t bssid[6];
    uint8_t channel;
    int8_t rssi;
} wifi_sta_status_t;

int esp_wifi_init(const void* config);
int esp_wifi_set_mode(wifi_mode_t mode);
int esp_wifi_start(void);
int esp_wifi_stop(void);
int esp_wifi_connect(void);
int esp_wifi_disconnect(void);
int esp_wifi_set_config(wifi_interface_t interface, wifi_config_t* conf);
int esp_wifi_get_config(wifi_interface_t interface, wifi_config_t* conf);
int esp_wifi_scan_start(const void* config, bool block);
int esp_wifi_scan_get_ap_records(uint16_t* number, wifi_ap_record_t* ap_records);
int esp_wifi_scan_get_ap_num(uint16_t* number);
int esp_wifi_sta_get_ap_info(wifi_ap_record_t* ap_info);
int esp_wifi_set_ps(int type);
int esp_wifi_get_ps(int* type);
int esp_wifi_set_max_tx_power(int8_t power);
int esp_wifi_get_max_tx_power(int8_t* power);
int esp_wifi_set_bandwidth(wifi_interface_t ifx, int bw);
int esp_wifi_get_bandwidth(wifi_interface_t ifx, int* bw);
int esp_wifi_set_channel(uint8_t primary, int second);
int esp_wifi_get_channel(uint8_t* primary, int* second);
int esp_wifi_set_country(const void* country);
int esp_wifi_get_country(void* country);
int esp_wifi_set_promiscuous(bool en);
int esp_wifi_get_promiscuous(bool* en);
int esp_wifi_set_promiscuous_rx_cb(void* cb);
int esp_wifi_set_promiscuous_filter(const void* filter);
int esp_wifi_get_promiscuous_filter(void* filter);
int esp_wifi_set_promiscuous_ctrl_filter(const void* filter);
int esp_wifi_get_promiscuous_ctrl_filter(void* filter);
int esp_wifi_set_ant(const void* config);
int esp_wifi_get_ant(void* config);
int esp_wifi_set_ant_gpio(const void* config);
int esp_wifi_get_ant_gpio(void* config);
int esp_wifi_set_vendor_ie(bool enable, int type, int idx, const void* vnd_ie);
int esp_wifi_set_vendor_ie_cb(void* cb, void* ctx);
int esp_wifi_set_event_mask(uint32_t mask);
int esp_wifi_get_event_mask(uint32_t* mask);
int esp_wifi_set_inactive_time(wifi_interface_t ifx, uint16_t sec);
int esp_wifi_get_inactive_time(wifi_interface_t ifx, uint16_t* sec);
int esp_wifi_statis_dump(uint32_t modules);
int esp_wifi_set_rssi_threshold(int32_t rssi);
int esp_wifi_ftm_initiate_session(void* cfg);
int esp_wifi_ftm_end_session(void);
int esp_wifi_ftm_resp_set_offset(int16_t offset_cm);
int esp_wifi_ftm_get_report(void* report, uint32_t report_len);
int esp_wifi_config_80211_tx_rate(wifi_interface_t ifx, void* rate);
int esp_wifi_config_espnow_rate(wifi_interface_t ifx, void* rate);
int esp_wifi_set_csi_config(const void* config);
int esp_wifi_set_csi_rx_cb(void* cb, void* ctx);
int esp_wifi_set_csi(bool en);
int esp_wifi_set_tx_power(int8_t power);
int esp_wifi_get_tx_power(int8_t* power);
int esp_wifi_set_storage(int storage);
int esp_wifi_restore(void);
int esp_wifi_set_mac(wifi_interface_t ifx, const uint8_t mac[6]);
int esp_wifi_get_mac(wifi_interface_t ifx, uint8_t mac[6]);
int esp_wifi_set_protocol(wifi_interface_t ifx, uint8_t protocol_bitmap);
int esp_wifi_get_protocol(wifi_interface_t ifx, uint8_t* protocol_bitmap);
int esp_wifi_set_protocols(wifi_interface_t ifx, void* protocols);
int esp_wifi_get_protocols(wifi_interface_t ifx, void* protocols);
int esp_wifi_set_band_mode(int band_mode);
int esp_wifi_get_band_mode(int* band_mode);
int esp_wifi_set_band(int band);
int esp_wifi_get_band(int* band);
int esp_wifi_set_country_code(const char* country, bool ieee80211d_enabled);
int esp_wifi_get_country_code(char* country);
int esp_wifi_set_tsf_time(uint64_t tsf_time);
uint64_t esp_wifi_get_tsf_time(void);
int esp_wifi_set_11ac_tx_rate(wifi_interface_t ifx, void* rate);
int esp_wifi_config_11b_tx_rate(wifi_interface_t ifx, void* rate);
int esp_wifi_config_11g_tx_rate(wifi_interface_t ifx, void* rate);
int esp_wifi_config_11n_tx_rate(wifi_interface_t ifx, void* rate);
int esp_wifi_config_11ac_tx_rate(wifi_interface_t ifx, void* rate);
int esp_wifi_config_11ax_tx_rate(wifi_interface_t ifx, void* rate);
int esp_wifi_config_tx_rate(wifi_interface_t ifx, void* rate);
int esp_wifi_config_get_tx_rate(wifi_interface_t ifx, void* rate);
int esp_wifi_set_rx_preamble(wifi_interface_t ifx, bool short_preamble);
int esp_wifi_get_rx_preamble(wifi_interface_t ifx, bool* short_preamble);
int esp_wifi_set_tx_done_cb(void* cb);
int esp_wifi_set_rx_done_cb(void* cb);
int esp_wifi_set_beacon_done_cb(void* cb);
int esp_wifi_set_csi_config_and_start(const void* config);
int esp_wifi_stop_csi(void);
int esp_wifi_set_csi_rx_cb_with_ctx(void* cb, void* ctx);
int esp_wifi_set_csi_rx_cb_without_ctx(void* cb);
int esp_wifi_set_promiscuous_rx_cb_with_ctx(void* cb, void* ctx);
int esp_wifi_set_promiscuous_rx_cb_without_ctx(void* cb);
int esp_wifi_set_promiscuous_filter_with_mask(const void* filter, uint32_t mask);
int esp_wifi_get_promiscuous_filter_with_mask(void* filter, uint32_t* mask);
int esp_wifi_set_promiscuous_ctrl_filter_with_mask(const void* filter, uint32_t mask);
int esp_wifi_get_promiscuous_ctrl_filter_with_mask(void* filter, uint32_t* mask);
int esp_wifi_set_promiscuous_rx_cb_with_ctx_and_mask(void* cb, void* ctx, uint32_t mask);
int esp_wifi_set_promiscuous_rx_cb_without_ctx_and_mask(void* cb, uint32_t mask);
int esp_wifi_set_promiscuous_rx_cb_with_ctx_and_filter(void* cb, void* ctx, const void* filter);
int esp_wifi_set_promiscuous_rx_cb_without_ctx_and_filter(void* cb, const void* filter);
int esp_wifi_set_promiscuous_rx_cb_with_ctx_and_ctrl_filter(void* cb, void* ctx, const void* filter);
int esp_wifi_set_promiscuous_rx_cb_without_ctx_and_ctrl_filter(void* cb, const void* filter);
int esp_wifi_set_promiscuous_rx_cb_with_ctx_and_filter_and_mask(void* cb, void* ctx, const void* filter, uint32_t mask);
int esp_wifi_set_promiscuous_rx_cb_without_ctx_and_filter_and_mask(void* cb, const void* filter, uint32_t mask);
int esp_wifi_set_promiscuous_rx_cb_with_ctx_and_ctrl_filter_and_mask(void* cb, void* ctx, const void* filter, uint32_t mask);
int esp_wifi_set_promiscuous_rx_cb_without_ctx_and_ctrl_filter_and_mask(void* cb, const void* filter, uint32_t mask);
int esp_wifi_set_promiscuous_rx_cb_with_ctx_and_filter_and_ctrl_filter(void* cb, void* ctx, const void* filter, const void* ctrl_filter);
int esp_wifi_set_promiscuous_rx_cb_without_ctx_and_filter_and_ctrl_filter(void* cb, const void* filter, const void* ctrl_filter);
int esp_wifi_set_promiscuous_rx_cb_with_ctx_and_filter_and_ctrl_filter_and_mask(void* cb, void* ctx, const void* filter, const void* ctrl_filter, uint32_t mask);
int esp_wifi_set_promiscuous_rx_cb_without_ctx_and_filter_and_ctrl_filter_and_mask(void* cb, const void* filter, const void* ctrl_filter, uint32_t mask);
