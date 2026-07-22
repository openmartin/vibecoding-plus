#pragma once
#include <stdint.h>

class DeferredTapTracker {
public:
    DeferredTapTracker() = default;
    void OnPress() {}
    void OnRelease() {}
    bool ShouldTriggerTap() const { return false; }
    void Reset() {}
};
