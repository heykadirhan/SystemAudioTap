import XCTest
@testable import SystemAudioTap

final class SystemAudioTapCoordinatorTests: XCTestCase {
    private let tap = AudioDevice(
        id: 70,
        uid: "private-tap",
        name: "System Audio Tap",
        outputChannelCount: 0
    )
    private let speakers = AudioDevice(
        id: 4,
        uid: "built-in",
        name: "Mac Speakers",
        outputChannelCount: 2
    )
    private let headphones = AudioDevice(
        id: 8,
        uid: "headphones",
        name: "USB Headphones",
        outputChannelCount: 2
    )

    func testActivationStartsCaptureBeforeForwardingWithoutChangingDefault() throws {
        let events = EventLog()
        let manager = FakeDeviceManager(devices: [speakers], current: speakers)
        let capture = FakeCapture(source: tap, events: events)
        let forwarder = FakeForwarder(events: events)
        let coordinator = SystemAudioTapCoordinator(
            devices: manager,
            capture: capture,
            forwarder: forwarder
        )

        try coordinator.activate(destinationUID: speakers.uid)

        XCTAssertEqual(events.values, ["capture:start", "start"])
        XCTAssertEqual(manager.current, speakers)
        XCTAssertEqual(coordinator.state, .active(destinationUID: speakers.uid))
    }

    func testForwarderFailureDestroysTapAndRestoresDryPath() {
        let events = EventLog()
        let manager = FakeDeviceManager(devices: [speakers], current: speakers)
        let capture = FakeCapture(source: tap, events: events)
        let forwarder = FakeForwarder(events: events)
        forwarder.failStart = true
        let coordinator = SystemAudioTapCoordinator(
            devices: manager,
            capture: capture,
            forwarder: forwarder
        )

        XCTAssertThrowsError(try coordinator.activate(destinationUID: speakers.uid))
        XCTAssertEqual(events.values, ["capture:start", "start", "stop", "capture:stop"])
        XCTAssertEqual(coordinator.state, .inactive)
    }

    func testActivationDoesNotTouchAudioWhenDestinationIsNotDefault() {
        let events = EventLog()
        let manager = FakeDeviceManager(
            devices: [speakers, headphones],
            current: headphones
        )
        let coordinator = SystemAudioTapCoordinator(
            devices: manager,
            capture: FakeCapture(source: tap, events: events),
            forwarder: FakeForwarder(events: events)
        )

        XCTAssertThrowsError(try coordinator.activate(destinationUID: speakers.uid)) { error in
            XCTAssertEqual(error as? SystemAudioError, .destinationIsNotDefault)
        }
        XCTAssertEqual(events.values, [])
        XCTAssertEqual(manager.current, headphones)
        XCTAssertEqual(coordinator.state, .inactive)
    }

    func testDefaultOutputChangeStopsRouteWithoutChangingNewOutput() throws {
        let events = EventLog()
        let manager = FakeDeviceManager(
            devices: [speakers, headphones],
            current: speakers
        )
        let coordinator = SystemAudioTapCoordinator(
            devices: manager,
            capture: FakeCapture(source: tap, events: events),
            forwarder: FakeForwarder(events: events)
        )
        try coordinator.activate(destinationUID: speakers.uid)
        events.values.removeAll()
        manager.current = headphones

        XCTAssertTrue(try coordinator.reconcileAfterHardwareChange())
        XCTAssertEqual(events.values, ["stop", "capture:stop"])
        XCTAssertEqual(manager.current, headphones)
        XCTAssertEqual(coordinator.state, .inactive)
    }

    func testDeactivationStopsReaderBeforeDestroyingTap() throws {
        let events = EventLog()
        let manager = FakeDeviceManager(devices: [speakers], current: speakers)
        let capture = FakeCapture(source: tap, events: events)
        let coordinator = SystemAudioTapCoordinator(
            devices: manager,
            capture: capture,
            forwarder: FakeForwarder(events: events)
        )
        try coordinator.activate(destinationUID: speakers.uid)
        events.values.removeAll()

        coordinator.deactivate()

        XCTAssertEqual(events.values, ["stop", "capture:stop"])
        XCTAssertEqual(coordinator.state, .inactive)
    }

    func testNewTapLeavesOutDirectProcesses() throws {
        let events = EventLog()
        let capture = FakeCapture(source: tap, events: events)
        let coordinator = SystemAudioTapCoordinator(
            devices: FakeDeviceManager(devices: [speakers], current: speakers),
            capture: capture,
            forwarder: FakeForwarder(events: events)
        )
        coordinator.setDirectProcesses([41, 97])

        try coordinator.activate(destinationUID: speakers.uid)

        XCTAssertEqual(events.values, ["capture:start", "start"])
        XCTAssertEqual(capture.excluded, [41, 97])
    }

    func testDirectProcessChangeUpdatesTheRunningTapWithoutRestartingIt() throws {
        let events = EventLog()
        let capture = FakeCapture(source: tap, events: events)
        let coordinator = SystemAudioTapCoordinator(
            devices: FakeDeviceManager(devices: [speakers], current: speakers),
            capture: capture,
            forwarder: FakeForwarder(events: events)
        )
        try coordinator.activate(destinationUID: speakers.uid)
        events.values.removeAll()

        coordinator.setDirectProcesses([41])
        coordinator.setDirectProcesses([41])

        XCTAssertEqual(events.values, ["capture:exclude"])
        XCTAssertEqual(capture.excluded, [41])
        XCTAssertEqual(coordinator.state, .active(destinationUID: speakers.uid))
    }

    func testFailedExclusionKeepsTheRouteAndIsRetried() throws {
        let events = EventLog()
        let capture = FakeCapture(source: tap, events: events)
        let coordinator = SystemAudioTapCoordinator(
            devices: FakeDeviceManager(devices: [speakers], current: speakers),
            capture: capture,
            forwarder: FakeForwarder(events: events)
        )
        try coordinator.activate(destinationUID: speakers.uid)
        events.values.removeAll()
        capture.failExclude = true

        coordinator.setDirectProcesses([41])
        XCTAssertEqual(coordinator.directProcesses, [])
        capture.failExclude = false
        coordinator.setDirectProcesses([41])

        XCTAssertEqual(events.values, ["capture:exclude", "capture:exclude"])
        XCTAssertEqual(capture.excluded, [41])
        XCTAssertEqual(coordinator.state, .active(destinationUID: speakers.uid))
    }
}


private final class EventLog {
    var values: [String] = []
}

private final class FakeDeviceManager: AudioDeviceManaging {
    var devices: [AudioDevice]
    var current: AudioDevice?

    init(devices: [AudioDevice], current: AudioDevice?) {
        self.devices = devices
        self.current = current
    }

    func outputDevices() throws -> [AudioDevice] { devices }
    func defaultOutputDevice() throws -> AudioDevice? { current }
    func device(uid: String) throws -> AudioDevice? { devices.first { $0.uid == uid } }
}

private final class FakeForwarder: AudioForwarding {
    private(set) var isRunning = false
    var failStart = false
    let events: EventLog

    init(events: EventLog) { self.events = events }

    func start(source: AudioDevice, destination: AudioDevice) throws {
        events.values.append("start")
        if failStart { throw SystemAudioError.forwardingUnavailable }
        isRunning = true
    }

    func stop() {
        events.values.append("stop")
        isRunning = false
    }
}

private final class FakeCapture: SystemAudioCaptureSource {
    let source: AudioDevice
    let events: EventLog
    var isSupported = true
    var failExclude = false
    private(set) var excluded: [UInt32] = []

    init(source: AudioDevice, events: EventLog) {
        self.source = source
        self.events = events
    }

    func start(excluding excludedProcesses: [UInt32], sampleRate: Double?) throws -> AudioDevice {
        events.values.append("capture:start")
        excluded = excludedProcesses
        return source
    }

    func exclude(_ processes: [UInt32]) throws {
        events.values.append("capture:exclude")
        if failExclude { throw SystemAudioError.systemAudioTapUnavailable }
        excluded = processes
    }

    func stop() {
        events.values.append("capture:stop")
    }
}
