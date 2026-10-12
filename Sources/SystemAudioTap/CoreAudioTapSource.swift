import CoreAudio
import Darwin
import Foundation

public protocol SystemAudioCaptureSource: AnyObject {
    var isSupported: Bool { get }
    /// Taps every process except this one and `excludedProcesses`, which keep playing
    /// straight to their output. The returned device runs at `sampleRate`, the
    /// output's rate, when one is given.
    func start(excluding excludedProcesses: [AudioObjectID], sampleRate: Double?) throws -> AudioDevice
    /// Changes which processes a running tap leaves out, without restarting it.
    func exclude(_ processes: [AudioObjectID]) throws
    func stop()
}

/// Creates a private, stereo global Core Audio process tap. `mutedWhenTapped`
/// suppresses the dry hardware path only while an audio client is reading the
/// tap; if this process stops or crashes, macOS resumes the normal path automatically.
public final class CoreAudioTapSource: SystemAudioCaptureSource {
    public var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ownProcess = AudioObjectID(kAudioObjectUnknown)
    /// The running tap's `CATapDescription`, which needs macOS 14.2.
    private var tapDescription: AnyObject?

    public init() {}

    deinit { stop() }

    public func start(excluding excludedProcesses: [AudioObjectID], sampleRate: Double?) throws -> AudioDevice {
        stop()
        guard #available(macOS 14.2, *) else {
            throw SystemAudioError.systemAudioTapUnavailable
        }

        let ownProcess = try currentAudioProcessObject()
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: Self.processList(own: ownProcess, excluded: excludedProcesses)
        )
        description.name = "System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &newTapID))
        tapID = newTapID
        self.ownProcess = ownProcess
        tapDescription = description

        do {
            let aggregateUID = "SystemAudioTap.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "System Audio Tap",
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false
            ]
            var newAggregateID = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(
                aggregateDescription as CFDictionary,
                &newAggregateID
            ))
            aggregateDeviceID = newAggregateID

            let tapUID = try stringProperty(kAudioTapPropertyUID, objectID: newTapID)
            try setTapList([tapUID], aggregateDeviceID: newAggregateID)
            if let sampleRate {
                try setNominalSampleRate(sampleRate, deviceID: newAggregateID)
            }

            return AudioDevice(
                id: newAggregateID,
                uid: aggregateUID,
                name: "System Audio Tap",
                outputChannelCount: 0
            )
        } catch {
            stop()
            throw error
        }
    }

    /// Core Audio applies the new process list to the running tap, so the aggregate
    /// device and its reader keep going.
    public func exclude(_ processes: [AudioObjectID]) throws {
        guard #available(macOS 14.2, *),
              tapID != kAudioObjectUnknown,
              let description = tapDescription as? CATapDescription else { return }
        let list = Self.processList(own: ownProcess, excluded: processes)
        let previous = description.processes
        guard list != previous else { return }
        description.processes = list
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(description)
        let status = AudioObjectSetPropertyData(
            tapID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size),
            &value
        )
        guard status == noErr else {
            description.processes = previous
            throw SystemAudioError.coreAudio(status)
        }
    }

    public func stop() {
        tapDescription = nil
        ownProcess = AudioObjectID(kAudioObjectUnknown)
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// This process first, then the other processes in a stable order.
    private static func processList(own: AudioObjectID, excluded: [AudioObjectID]) -> [AudioObjectID] {
        [own] + Set(excluded).subtracting([own]).sorted()
    }

    @available(macOS 14.2, *)
    private func currentAudioProcessObject() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = getpid()
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &processID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifier,
                &size,
                &objectID
            )
        }
        try check(status)
        guard objectID != kAudioObjectUnknown else {
            throw SystemAudioError.systemAudioTapUnavailable
        }
        return objectID
    }

    private func setTapList(
        _ tapUIDs: [String],
        aggregateDeviceID: AudioObjectID
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyTapList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var list: CFArray? = tapUIDs.map { $0 as CFString } as CFArray
        let size = UInt32(tapUIDs.count * MemoryLayout<CFString>.stride)
        try withUnsafeMutablePointer(to: &list) { pointer in
            try check(AudioObjectSetPropertyData(
                aggregateDeviceID,
                &address,
                0,
                nil,
                size,
                pointer
            ))
        }
    }

    /// A tap-only aggregate doesn't follow the output's rate: one ran at 48 kHz for a
    /// 44.1 kHz output. An AUHAL input doesn't convert rates, so every capture render
    /// then fails and the speakers play silence. The tap follows the aggregate's rate.
    private func setNominalSampleRate(_ sampleRate: Double, deviceID: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = sampleRate
        try check(AudioObjectSetPropertyData(
            deviceID, &address, 0, nil, UInt32(MemoryLayout<Float64>.size), &rate
        ))
        guard try CoreAudioDeviceManager.nominalSampleRate(deviceID: deviceID) == sampleRate else {
            throw SystemAudioError.audioFormatUnavailable
        }
    }

    private func stringProperty(
        _ selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(
            objectID, &address, 0, nil, &size, &value
        ))
        guard let value else { throw SystemAudioError.systemAudioTapUnavailable }
        return value.takeRetainedValue() as String
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw SystemAudioError.coreAudio(status) }
    }
}
