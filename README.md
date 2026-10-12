# SystemAudioTap

Process all of a Mac's audio in real time, then play it on the speakers. Uses the
Core Audio process taps added in macOS 14.2. No virtual audio driver needed.

```
apps ──► process tap (muted while tapped) ──► AUHAL input ──► lock-free FIFO
                                                                    │
speakers ◄── AUHAL output (pinned to the device) ◄── your processor ◄┘
```

Pulled out of [Unboom](https://unboom.app), a macOS app that removes room boom from
speakers, where it runs every day.

## What it handles

Most process-tap examples stop at "it captures". Most of this code covers what goes
wrong after that:

- **Sample-rate mismatch.** A tap-only aggregate device doesn't follow the output's
  rate, and an AUHAL input doesn't convert rates. When the rates differ, every
  capture render fails silently. The aggregate is set to the output's nominal rate,
  and the route is rebuilt when that rate changes.
- **Clock drift.** The capture and playback clocks are different devices. The FIFO
  reader holds an adaptive latency target (30–120 ms) and corrects drift with
  crossfaded splices aligned to the audio, so sustained bass stays in phase.
- **Dropouts.** When capture runs dry, playback fades out instead of clicking. It
  fades back in when audio returns.
- **No stuck mutes.** `mutedWhenTapped` silences the apps only while someone reads the
  tap. If playback or capture stalls, the route is released and macOS's normal path
  comes back. A crash is safe too.
- **Output changes.** The route never changes the macOS default output. If the user
  picks another one, it stops right away.
- **Excluding apps.** Leave chosen processes out of the tap without restarting it.
- **Real-time safety.** The render callbacks don't allocate, lock, or log. They only
  count, and `ForwardingHealthMonitor` reads the counters from the main thread.

## Use

```swift
import SystemAudioTap

final class Gain: RealtimeAudioProcessor {
    func prepare(sampleRate: Double, channelCount: Int, maximumFrameCount: Int) {}

    // Audio thread: no allocation, locks, or logging.
    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        for i in 0..<frameCount * channelCount { samples[i] *= 0.5 }
    }
}

let devices = CoreAudioDeviceManager()
let route = SystemAudioTapCoordinator(
    devices: devices,
    capture: CoreAudioTapSource(),
    forwarder: HALAudioForwarder(processor: Gain())
)
try route.activate(destinationUID: devices.defaultOutputDevice()!.uid)

// Then, from the main thread:
route.checkHealth()                     // about once a second
try route.reconcileAfterHardwareChange() // from devices.observeHardwareChanges
route.setDirectProcesses([pid])          // AudioObjectIDs to leave out of the tap
route.deactivate()
```

Try it with the demo, which turns all Mac audio down by 12 dB until you press Control-C:

```sh
swift run tap-demo -12
```

The first run asks for **Screen & System Audio Recording** permission. An app needs
`NSAudioCaptureUsageDescription` in its Info.plist.

## Layout

| Module | Contents |
| --- | --- |
| `AudioTapBridge` (C) | Lock-free SPSC stereo FIFO and the drift-correcting reader |
| `SystemAudioTap` | Tap source, HAL forwarder, coordinator, device and process monitoring, health monitor |

Every Core Audio piece sits behind a protocol (`AudioDeviceManaging`,
`SystemAudioCaptureSource`, `AudioForwarding`), so the tests cover start and stop
order, stalls, and rate changes with fakes:

```sh
swift test
```

## Limits

- Stereo Float32 only.
- Plays to one output device: the current macOS default.
- About 50 ms of added latency. That's fine for music and video, but not for live
  monitoring.

## License

MIT
