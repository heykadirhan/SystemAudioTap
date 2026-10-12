import XCTest
@testable import SystemAudioTap

final class ForwardingHealthMonitorTests: XCTestCase {
    func testReportsOnlyTheFirstGlitchInEachReportWindow() {
        var monitor = ForwardingHealthMonitor(reportSampleCount: 4)

        XCTAssertEqual(monitor.add(sample(captured: 480, played: 480)), [])
        XCTAssertEqual(
            monitor.add(sample(captured: 960, played: 900, silent: 60, dropouts: 1)),
            [.glitch(droppedFrames: 0, dropouts: 1)]
        )
        XCTAssertEqual(monitor.add(sample(
            captured: 1_440,
            played: 1_380,
            silent: 120,
            dropouts: 2,
            splices: 1,
            skipped: 240
        )), [])
        XCTAssertEqual(
            monitor.add(sample(
                captured: 1_920, played: 1_860, silent: 120, dropouts: 2,
                splices: 1, skipped: 240, buffered: 60, target: 2_400
            )),
            [.report(ForwardingHealthMonitor.Report(
                minimumBufferedFrames: 0,
                maximumBufferedFrames: 60,
                latencyTargetFrames: 2_400,
                droppedFrames: 0,
                dropouts: 2,
                splices: 1,
                framesSkipped: 240,
                framesDelivered: 1_440,
                framesRequested: 1_500
            ))]
        )
    }

    func testReportMeasuresASlowCaptureClockThroughUnderflows() throws {
        var monitor = ForwardingHealthMonitor(reportSampleCount: 2)
        XCTAssertEqual(monitor.add(sample(captured: 48_000, played: 48_000)), [])

        // Over 60 s at 48 kHz, capture delivers 100 ppm fewer frames than playback
        // asks for. Playback reads everything and fills the rest with silence.
        let events = monitor.add(sample(captured: 2_927_712, played: 2_927_712, silent: 288))

        guard case let .report(report)? = events.last else { return XCTFail("Expected a report") }
        XCTAssertEqual(report.framesDelivered, 2_879_712)
        XCTAssertEqual(report.framesRequested, 2_880_000)
        XCTAssertEqual(try XCTUnwrap(report.clockDriftPartsPerMillion), -100, accuracy: 0.001)
    }

    func testPlaybackPauseDoesNotReadAsClockDrift() throws {
        var monitor = ForwardingHealthMonitor(reportSampleCount: 5)
        XCTAssertEqual(monitor.add(sample(captured: 48_000, played: 48_000, buffered: 2_400, target: 2_400)), [])

        // Playback stops asking for 0.7 s. The buffer fills and the rest is dropped.
        XCTAssertEqual(
            monitor.add(sample(captured: 81_600, played: 48_000, dropped: 1_232, buffered: 32_768, target: 2_400)),
            [.glitch(droppedFrames: 1_232, dropouts: 0)]
        )
        // Playback is back, but a splice hasn't skipped the backlog yet.
        XCTAssertEqual(monitor.add(sample(captured: 129_600, played: 96_000, dropped: 1_232, buffered: 32_768, target: 2_400)), [])
        // The splice skipped the backlog, so the comparison starts here.
        XCTAssertEqual(monitor.add(sample(captured: 177_600, played: 113_632, dropped: 1_232, buffered: 2_400, target: 2_400)), [])

        // 60 s later, capture delivered 100 ppm fewer frames than playback asked for.
        let events = monitor.add(sample(
            captured: 3_057_312, played: 2_993_344, dropped: 1_232, silent: 288, buffered: 2_400, target: 2_400
        ))

        guard case let .report(report)? = events.last else { return XCTFail("Expected a report") }
        XCTAssertEqual(report.droppedFrames, 1_232)
        XCTAssertEqual(report.framesRequested, 2_880_000)
        XCTAssertEqual(try XCTUnwrap(report.clockDriftPartsPerMillion), -100, accuracy: 0.001)
    }

    func testClockIsNotMeasuredUntilTheBufferRecovers() {
        var monitor = ForwardingHealthMonitor(reportSampleCount: 2)
        XCTAssertEqual(monitor.add(sample(captured: 48_000, played: 0, buffered: 32_768, target: 2_400)), [])

        let events = monitor.add(sample(captured: 96_000, played: 48_000, buffered: 32_768, target: 2_400))

        guard case let .report(report)? = events.last else { return XCTFail("Expected a report") }
        XCTAssertNil(report.clockDriftPartsPerMillion)
    }

    func testFlagsPlaybackStallOnlyAfterConsecutiveSamples() {
        var monitor = ForwardingHealthMonitor(stallSampleCount: 3)

        XCTAssertEqual(monitor.add(sample(captured: 480, played: 480)), [])
        XCTAssertEqual(monitor.add(sample(captured: 960, played: 480)), [])
        XCTAssertEqual(monitor.add(sample(captured: 1_440, played: 480)), [])
        // Playback moved again, so the count starts over.
        XCTAssertEqual(monitor.add(sample(captured: 1_920, played: 960)), [])
        XCTAssertEqual(monitor.add(sample(captured: 2_400, played: 960)), [])
        XCTAssertEqual(monitor.add(sample(captured: 2_880, played: 960)), [])
        XCTAssertEqual(monitor.add(sample(captured: 3_360, played: 960)), [.playbackStalled])
    }

    /// A 44.1 kHz route once captured nothing for a minute while the speakers played
    /// silence, because its tap ran at 48 kHz.
    func testFlagsCaptureStallOnlyAfterConsecutiveSamples() {
        var monitor = ForwardingHealthMonitor(stallSampleCount: 3)

        XCTAssertEqual(monitor.add(sample(captured: 0, played: 0, silent: 441)), [])
        XCTAssertEqual(monitor.add(sample(captured: 0, played: 0, silent: 882)), [])
        // Capture started, so the count starts over.
        XCTAssertEqual(monitor.add(sample(captured: 441, played: 0, silent: 1_323)), [])
        XCTAssertEqual(monitor.add(sample(captured: 441, played: 441, silent: 1_323)), [])
        XCTAssertEqual(monitor.add(sample(captured: 441, played: 441, silent: 1_764)), [])
        XCTAssertEqual(monitor.add(sample(captured: 441, played: 441, silent: 2_205)), [.captureStalled])
    }

    func testFullBufferStillCountsAsCapturing() {
        var monitor = ForwardingHealthMonitor(stallSampleCount: 2)

        XCTAssertEqual(monitor.add(sample(captured: 32_768, played: 0)), [])
        XCTAssertEqual(
            monitor.add(sample(captured: 32_768, played: 0, dropped: 480)),
            [.glitch(droppedFrames: 480, dropouts: 0), .playbackStalled]
        )
    }

    func testBufferingBeforePlaybackIsNeitherAStallNorAGlitch() {
        var monitor = ForwardingHealthMonitor(stallSampleCount: 1)

        XCTAssertEqual(monitor.add(sample(captured: 0, played: 0)), [])
        XCTAssertEqual(monitor.add(sample(captured: 480, played: 0, silent: 480)), [])
    }

    private func sample(
        captured: UInt64,
        played: UInt64,
        dropped: UInt64 = 0,
        silent: UInt64 = 0,
        dropouts: UInt64 = 0,
        splices: UInt64 = 0,
        skipped: UInt64 = 0,
        repeated: UInt64 = 0,
        buffered: UInt32 = 0,
        target: UInt32 = 0
    ) -> AudioForwardingDiagnostics {
        AudioForwardingDiagnostics(
            framesCaptured: captured,
            framesPlayed: played,
            droppedFrames: dropped,
            silentFrames: silent,
            dropouts: dropouts,
            splices: splices,
            framesSkipped: skipped,
            framesRepeated: repeated,
            bufferedFrames: buffered,
            latencyTargetFrames: target
        )
    }
}

final class SystemAudioRecoveryScheduleTests: XCTestCase {
    func testUsesBoundedDelaysThenStops() {
        var schedule = SystemAudioRecoverySchedule(delays: [2, 5, 15])

        XCTAssertEqual(schedule.nextDelay(), 2)
        XCTAssertEqual(schedule.nextDelay(), 5)
        XCTAssertEqual(schedule.nextDelay(), 15)
        XCTAssertNil(schedule.nextDelay())
        XCTAssertFalse(schedule.hasAttemptsRemaining)
    }

    func testResetStartsTheScheduleAgain() {
        var schedule = SystemAudioRecoverySchedule(delays: [2, 5])
        XCTAssertEqual(schedule.nextDelay(), 2)

        schedule.reset()

        XCTAssertEqual(schedule.nextDelay(), 2)
        XCTAssertTrue(schedule.hasAttemptsRemaining)
    }
}

final class SystemAudioRouteHealthTests: XCTestCase {
    private var events: [String] = []
    private var output: SingleOutput!
    private var forwarder: CountingForwarder!
    private var capture: RecordingCapture!
    private var coordinator: SystemAudioTapCoordinator!

    override func setUpWithError() throws {
        events = []
        let output = SingleOutput(speakers)
        self.output = output
        forwarder = CountingForwarder(
            outputRate: { output.sampleRate },
            record: { [unowned self] in self.events.append($0) }
        )
        capture = RecordingCapture { [unowned self] in self.events.append($0) }
        coordinator = SystemAudioTapCoordinator(
            devices: output,
            capture: capture,
            forwarder: forwarder
        )
        try coordinator.activate(destinationUID: speakers.uid)
        events.removeAll()
    }

    func testPlaybackStallReleasesTheTap() {
        for tick in 1...2 {
            forwarder.diagnostics.framesCaptured = UInt64(tick) * 480
            XCTAssertFalse(coordinator.checkHealth())
        }
        forwarder.diagnostics.framesCaptured = 1_440

        XCTAssertTrue(coordinator.checkHealth())
        XCTAssertEqual(events, ["stop", "capture:stop"])
        XCTAssertEqual(coordinator.state, .inactive)
        XCTAssertFalse(coordinator.checkHealth())
    }

    func testCaptureStallReleasesTheTap() {
        for tick in 1...2 {
            forwarder.diagnostics.silentFrames = UInt64(tick) * 441
            XCTAssertFalse(coordinator.checkHealth())
        }
        forwarder.diagnostics.silentFrames = 1_323

        XCTAssertTrue(coordinator.checkHealth())
        XCTAssertEqual(events, ["stop", "capture:stop"])
        XCTAssertEqual(coordinator.state, .inactive)
    }

    func testTapRunsAtTheOutputRate() {
        XCTAssertEqual(capture.sampleRate, 48_000)
    }

    func testHealthyRouteKeepsRunning() {
        for tick in 1...10 {
            forwarder.diagnostics.framesCaptured = UInt64(tick) * 480
            forwarder.diagnostics.framesPlayed = UInt64(tick) * 480
            XCTAssertFalse(coordinator.checkHealth())
        }
        XCTAssertEqual(coordinator.state, .active(destinationUID: speakers.uid))
    }

    func testOutputRateChangeRebuildsTheRouteAtTheNewRate() throws {
        output.sampleRate = 96_000

        XCTAssertTrue(try coordinator.reconcileAfterHardwareChange())
        XCTAssertEqual(events, ["stop", "capture:stop", "capture:start", "start"])
        XCTAssertEqual(coordinator.state, .active(destinationUID: speakers.uid))
        XCTAssertEqual(forwarder.sampleRate, 96_000)
        XCTAssertEqual(capture.sampleRate, 96_000)
    }

    func testUnchangedRateLeavesTheRouteAlone() throws {
        XCTAssertFalse(try coordinator.reconcileAfterHardwareChange())
        XCTAssertEqual(events, [])
        XCTAssertEqual(coordinator.state, .active(destinationUID: speakers.uid))
    }

    func testFailedRebuildLeavesMacOSOutputRestored() {
        output.sampleRate = 96_000
        forwarder.failStart = true

        XCTAssertThrowsError(try coordinator.reconcileAfterHardwareChange())
        XCTAssertEqual(events, ["stop", "capture:stop", "capture:start", "start", "stop", "capture:stop"])
        XCTAssertEqual(coordinator.state, .inactive)
    }
}

private let speakers = AudioDevice(
    id: 4,
    uid: "built-in",
    name: "Mac Speakers",
    outputChannelCount: 2
)

private final class SingleOutput: AudioDeviceManaging {
    let output: AudioDevice
    var sampleRate = 48_000.0

    init(_ output: AudioDevice) { self.output = output }

    func outputDevices() throws -> [AudioDevice] { [output] }
    func defaultOutputDevice() throws -> AudioDevice? { output }
    func device(uid: String) throws -> AudioDevice? { uid == output.uid ? output : nil }
    func nominalSampleRate(uid: String) throws -> Double? { uid == output.uid ? sampleRate : nil }
}

private final class RecordingCapture: SystemAudioCaptureSource {
    let record: (String) -> Void
    var isSupported = true
    private(set) var sampleRate: Double?

    init(record: @escaping (String) -> Void) { self.record = record }

    func start(excluding excludedProcesses: [UInt32], sampleRate: Double?) throws -> AudioDevice {
        record("capture:start")
        self.sampleRate = sampleRate
        return AudioDevice(id: 70, uid: "private-tap", name: "System Audio Tap", outputChannelCount: 0)
    }

    func exclude(_ processes: [UInt32]) throws { record("capture:exclude") }

    func stop() { record("capture:stop") }
}

private final class CountingForwarder: AudioForwarding {
    let outputRate: () -> Double
    let record: (String) -> Void
    var diagnostics = AudioForwardingDiagnostics()
    var failStart = false
    private(set) var isRunning = false
    private(set) var sampleRate: Double?

    init(outputRate: @escaping () -> Double, record: @escaping (String) -> Void) {
        self.outputRate = outputRate
        self.record = record
    }

    func start(source: AudioDevice, destination: AudioDevice) throws {
        record("start")
        if failStart { throw SystemAudioError.forwardingUnavailable }
        isRunning = true
        // Like HALAudioForwarder, run at the destination's current rate.
        sampleRate = outputRate()
    }

    func stop() {
        record("stop")
        isRunning = false
        sampleRate = nil
        diagnostics = AudioForwardingDiagnostics()
    }
}
