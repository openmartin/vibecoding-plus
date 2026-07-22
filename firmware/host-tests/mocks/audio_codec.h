#pragma once
#include <stdint.h>
#include <stddef.h>

class AudioCodec {
public:
    virtual ~AudioCodec() = default;
    virtual bool Initialize() { return true; }
    virtual void SetVolume(int volume) {}
    virtual int GetVolume() const { return 0; }
    virtual void SetMute(bool mute) {}
    virtual bool IsMuted() const { return false; }
    virtual bool ReadAudioData(uint8_t* buffer, size_t size, size_t* bytes_read, uint32_t timeout_ms) { return false; }
    virtual bool WriteAudioData(const uint8_t* buffer, size_t size, size_t* bytes_written, uint32_t timeout_ms) { return false; }
    virtual bool Start() { return true; }
    virtual void Stop() {}
    virtual bool IsRunning() const { return false; }
};
