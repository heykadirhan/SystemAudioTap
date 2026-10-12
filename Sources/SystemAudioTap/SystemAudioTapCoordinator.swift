import CoreAudio
import Foundation
import os

/// Coordinates Apple's process-tap capture with the physical-output forwarder.
/// It never changes macOS's selected output.
public final class SystemAudioTapCoordinator {
    public enum State: Equatable {
        case inactive
        case active(destinationUID: String)
    }

    public enum DeactivationReason: String {
        case requested
        case outputChanged = "output changed"
        case playbackStalled = "playback stalled"
        case captureStalled = "capture stalled"
        case sampleRateChanged = "sample rate changed"
        case idle = "nothing playing"
        case sleep
        case quit
    }

    public private(set) var state: State = .inactive
    /// Processes that play straight to their output, left out of the tap.
    public private(set) var directProcesses: [AudioObjectID] = []
    public var isSupported: Bool { capture.isSupported }
    public var diagnostics: AudioForwardingDiagnostics { forwarder.diagnostics }
    public var sampleRate: Double? { forwarder.sampleRate }

    private let devices: AudioDeviceManaging
    private let capture: SystemAudioCaptureSource
    private let forwarder: AudioForwarding
    private var health = ForwardingHealthMonitor()
    private let log = Logger(subsystem: "SystemAudioTap", category: "route")

    public init(
        devices: AudioDeviceManaging,
        capture: SystemAudioCaptureSource,
        forwarder: AudioForwarding
    ) {
        self.devices = devices
        self.capture = capture
        self.forwarder = forwarder
    }

    public func availableDestinations() throws -> [AudioDevice] {
        try devices.outputDevices().filter { $0.isOutputDevice }
    }

    /// Taps system audio and plays it on `destinationUID`, which must be the
    /// current macOS default output.
    public func activate(destinationUID: String) throws {
        guard let destination = try devices.device(uid: destinationUID) else {
            log.notice("Not activating: the saved output isn't connected")
            throw SystemAudioError.destinationUnavailable
        }
        guard try devices.defaultOutputDevice()?.uid == destination.uid else {
            log.notice("Not activating: the saved output isn't the macOS output")
            throw SystemAudioError.destinationIsNotDefault
        }

        if state != .inactive { deactivate() }
        let source: AudioDevice
        do {
            source = try capture.start(
                excluding: directProcesses,
                sampleRate: devices.nominalSampleRate(uid: destination.uid)
            )
        } catch {
            log.error("System audio tap failed to start: \(String(describing: error), privacy: .public)")
            throw error
        }
        do {
            try forwarder.start(source: source, destination: destination)
            state = .active(destinationUID: destination.uid)
            health = ForwardingHealthMonitor()
            log.notice("""
                Route started on \(destination.name, privacy: .private(mask: .hash)) \
                at \(self.forwarder.sampleRate ?? 0, format: .fixed(precision: 0)) Hz, \
                \(self.directProcesses.count) direct process(es)
                """)
        } catch {
            log.error("Forwarder failed to start, releasing the tap: \(String(describing: error), privacy: .public)")
            forwarder.stop()
            capture.stop()
            throw error
        }
    }

    /// Leaves these processes out of the tap, now if a route is running and at the
    /// next activation otherwise. A running tap changes without a restart. If that
    /// fails, the processes stay tapped, which only delays them, and the next call
    /// tries again.
    public func setDirectProcesses(_ processes: [AudioObjectID]) {
        guard processes != directProcesses else { return }
        guard state != .inactive else {
            directProcesses = processes
            return
        }
        do {
            try capture.exclude(processes)
            directProcesses = processes
            log.info("\(processes.count) process(es) now play directly")
        } catch {
            log.error("Couldn't change the tap's direct processes: \(String(describing: error), privacy: .public)")
        }
    }

    public func deactivate(reason: DeactivationReason = .requested) {
        let wasActive = state != .inactive
        // Stopping the reader causes mutedWhenTapped to restore the dry path.
        forwarder.stop()
        capture.stop()
        state = .inactive
        if wasActive {
            log.notice("Route stopped (\(reason.rawValue, privacy: .public)); macOS output restored")
        }
    }

    @discardableResult
    public func reconcileAfterHardwareChange() throws -> Bool {
        guard case let .active(destinationUID) = state else { return false }
        let destinationStillExists = try devices.device(uid: destinationUID) != nil
        let destinationIsDefault = try devices.defaultOutputDevice()?.uid == destinationUID
        guard destinationStillExists && destinationIsDefault else {
            // Release mutedWhenTapped immediately. macOS owns output selection;
            // The route never follows or overrides a newly selected device.
            deactivate(reason: .outputChanged)
            return true
        }
        if let routeRate = forwarder.sampleRate,
           let outputRate = try devices.nominalSampleRate(uid: destinationUID),
           outputRate != routeRate {
            // Rebuild at the output's new rate rather than leave both AUHAL units
            // resampling. A failed rebuild stays inactive, which restores the dry path.
            log.notice("""
                Output rate changed from \(routeRate, format: .fixed(precision: 0)) \
                to \(outputRate, format: .fixed(precision: 0)) Hz; rebuilding the route
                """)
            deactivate(reason: .sampleRateChanged)
            try activate(destinationUID: destinationUID)
            return true
        }
        return false
    }

    /// Call about once a second from the main thread. Logs glitches and buffer
    /// levels, and returns true after stopping a route whose playback or capture
    /// stalled.
    @discardableResult
    public func checkHealth() -> Bool {
        guard state != .inactive else { return false }
        for event in health.add(forwarder.diagnostics) {
            switch event {
            case let .glitch(dropped, dropouts):
                log.notice("Audio glitch: \(dropped) frames dropped, \(dropouts) dropouts")
            case let .report(report):
                // Notice level keeps reports in the persisted log.
                let rate = forwarder.sampleRate ?? 0
                log.notice("""
                    Buffered \(report.minimumBufferedFrames)–\(report.maximumBufferedFrames) frames \
                    (\(Self.milliseconds(report.minimumBufferedFrames, rate: rate), format: .fixed(precision: 0))–\
                    \(Self.milliseconds(report.maximumBufferedFrames, rate: rate), format: .fixed(precision: 0)) ms, \
                    target \(Self.milliseconds(report.latencyTargetFrames, rate: rate), format: .fixed(precision: 0)) ms); \
                    \(report.droppedFrames) dropped, \(report.dropouts) dropouts, \
                    \(report.splices) splices (\(report.framesSkipped) skipped, \
                    \(report.framesRepeated) repeated) since last report; \
                    capture clock \(report.clockDriftPartsPerMillion ?? 0, format: .fixed(precision: 0)) ppm \
                    vs playback over \(rate > 0 ? Double(report.framesRequested) / rate : 0, format: .fixed(precision: 0)) s
                    """)
            case .playbackStalled:
                log.fault("Playback stalled while the tap was capturing")
                deactivate(reason: .playbackStalled)
                return true
            case .captureStalled:
                log.fault("Capture delivered nothing while playback was running")
                deactivate(reason: .captureStalled)
                return true
            }
        }
        return false
    }

    private static func milliseconds(_ frames: UInt32, rate: Double) -> Double {
        rate > 0 ? Double(frames) / rate * 1_000 : 0
    }
}
