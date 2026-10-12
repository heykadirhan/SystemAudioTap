import Foundation
import SystemAudioTap

/// Turns all Mac audio down by a fixed amount. Run it, play something, and
/// press Control-C to stop: macOS restores the normal path as soon as it exits.
///
///     swift run tap-demo -12
final class Gain: RealtimeAudioProcessor {
    let factor: Float

    init(decibels: Float) { factor = pow(10, decibels / 20) }

    func prepare(sampleRate: Double, channelCount: Int, maximumFrameCount: Int) {}

    func process(_ samples: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int) {
        for index in 0..<frameCount * channelCount {
            samples[index] *= factor
        }
    }
}

let decibels = CommandLine.arguments.dropFirst().first.flatMap(Float.init) ?? -12
let devices = CoreAudioDeviceManager()
let coordinator = SystemAudioTapCoordinator(
    devices: devices,
    capture: CoreAudioTapSource(),
    forwarder: HALAudioForwarder(processor: Gain(decibels: decibels))
)

func start() {
    do {
        guard let output = try devices.defaultOutputDevice() else {
            print("No output device.")
            return
        }
        try coordinator.activate(destinationUID: output.uid)
        print("Playing Mac audio through \(output.name) at \(decibels) dB. Control-C stops.")
    } catch {
        print("Couldn't start: \(error.localizedDescription)")
    }
}

start()

// Follow the default output: the coordinator stops when it changes, and this starts again.
let observation = try devices.observeHardwareChanges {
    _ = try? coordinator.reconcileAfterHardwareChange()
    if coordinator.state == .inactive { start() }
}

// The render callbacks only count. Check them from here about once a second.
let health = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
    if coordinator.checkHealth() { print("The route stalled and was released.") }
}

signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    coordinator.deactivate(reason: .quit)
    exit(0)
}
interrupt.resume()

withExtendedLifetime((observation, health)) { RunLoop.main.run() }
