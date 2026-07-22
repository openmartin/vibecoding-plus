import Foundation

/// Generated from doc/protocol.yaml — do not edit by hand.
enum LANProtocol {
    static let version = 2
}

enum LANDeviceMessage {
    static let hello = "hello"
    static let ptt_start = "ptt_start"
    static let ptt_stop = "ptt_stop"
    static let todo_command = "todo_command"
    static let ping = "ping"
    static let firmware_progress = "firmware_progress"
    static let firmware_result = "firmware_result"
    static let firmware_check_result = "firmware_check_result"
    static let discover_host = "discover_host"
}

enum LANServerMessage {
    static let auth_challenge = "auth_challenge"
    static let hello_ack = "hello_ack"
    static let server_ready = "server_ready"
    static let display_config = "display_config"
    static let transcript_final = "transcript_final"
    static let transcript_partial = "transcript_partial"
    static let transcript_cleared = "transcript_cleared"
    static let status = "status"
    static let todo_state = "todo_state"
    static let todo_result = "todo_result"
    static let force_refresh = "force_refresh"
    static let device_event = "device_event"
    static let pong = "pong"
    static let warning = "warning"
    static let error = "error"
    static let firmware_check = "firmware_check"
    static let firmware_offer = "firmware_offer"
    static let provision_secret = "provision_secret"
    static let discover_reply = "discover_reply"
}
