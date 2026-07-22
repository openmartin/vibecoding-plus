#ifndef PROTOCOL_MESSAGES_H
#define PROTOCOL_MESSAGES_H

#define LAN_PROTOCOL_VERSION 2

#define LAN_MSG_DEVICE_HELLO "hello"
#define LAN_MSG_DEVICE_PTT_START "ptt_start"
#define LAN_MSG_DEVICE_PTT_STOP "ptt_stop"
#define LAN_MSG_DEVICE_TODO_COMMAND "todo_command"
#define LAN_MSG_DEVICE_PING "ping"
#define LAN_MSG_DEVICE_FIRMWARE_PROGRESS "firmware_progress"
#define LAN_MSG_DEVICE_FIRMWARE_RESULT "firmware_result"
#define LAN_MSG_DEVICE_FIRMWARE_CHECK_RESULT "firmware_check_result"
#define LAN_MSG_DEVICE_DISCOVER_HOST "discover_host"

#define LAN_MSG_SERVER_AUTH_CHALLENGE "auth_challenge"
#define LAN_MSG_SERVER_HELLO_ACK "hello_ack"
#define LAN_MSG_SERVER_SERVER_READY "server_ready"
#define LAN_MSG_SERVER_DISPLAY_CONFIG "display_config"
#define LAN_MSG_SERVER_TRANSCRIPT_FINAL "transcript_final"
#define LAN_MSG_SERVER_TRANSCRIPT_PARTIAL "transcript_partial"
#define LAN_MSG_SERVER_TRANSCRIPT_CLEARED "transcript_cleared"
#define LAN_MSG_SERVER_STATUS "status"
#define LAN_MSG_SERVER_TODO_STATE "todo_state"
#define LAN_MSG_SERVER_TODO_RESULT "todo_result"
#define LAN_MSG_SERVER_FORCE_REFRESH "force_refresh"
#define LAN_MSG_SERVER_DEVICE_EVENT "device_event"
#define LAN_MSG_SERVER_PONG "pong"
#define LAN_MSG_SERVER_WARNING "warning"
#define LAN_MSG_SERVER_ERROR "error"
#define LAN_MSG_SERVER_FIRMWARE_CHECK "firmware_check"
#define LAN_MSG_SERVER_FIRMWARE_OFFER "firmware_offer"
#define LAN_MSG_SERVER_PROVISION_SECRET "provision_secret"
#define LAN_MSG_SERVER_DISCOVER_REPLY "discover_reply"

#endif
