#ifndef AUDIO_TAP_BRIDGE_TESTS_H
#define AUDIO_TAP_BRIDGE_TESTS_H

/// Runs the AudioTapBridge checks and calls `reportFailure` for each failed
/// check, so XCTest reports it instead of the test process aborting.
void SATAudioTapBridgeRunTests(
    void (*reportFailure)(const char* file, int line, const char* expression)
);

#endif
