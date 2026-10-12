import CoreAudio
import Foundation

public protocol AudioDeviceManaging: AnyObject {
    func outputDevices() throws -> [AudioDevice]
    func defaultOutputDevice() throws -> AudioDevice?
    func device(uid: String) throws -> AudioDevice?
    /// The output's current nominal sample rate, or nil when it isn't connected.
    func nominalSampleRate(uid: String) throws -> Double?
}

public extension AudioDeviceManaging {
    func nominalSampleRate(uid: String) throws -> Double? { nil }
}

public final class CoreAudioDeviceManager: AudioDeviceManaging {
    public init() {}

    public func outputDevices() throws -> [AudioDevice] {
        try devices(scope: kAudioDevicePropertyScopeOutput)
    }

    /// Devices with input channels.
    public func inputDevices() throws -> [AudioDevice] {
        try devices(scope: kAudioDevicePropertyScopeInput)
    }

    private func devices(scope: AudioObjectPropertyScope) throws -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount
        ))

        let count = Int(byteCount) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = Array(repeating: AudioObjectID(0), count: count)
        let status = ids.withUnsafeMutableBytes { storage in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                storage.baseAddress!
            )
        }
        try check(status)

        return ids.compactMap { id in
            // Core Audio exposes private aggregate devices (for example
            // CADefaultDeviceAggregate-…) in the global device list even though
            // macOS deliberately omits them from Sound settings. They are routing
            // implementation details, not devices the user can select.
            // A device can also disappear while the list is read, during a hot-plug
            // or a Bluetooth switch. Skip it rather than fail the whole list.
            guard (try? isSelectable(deviceID: id, scope: scope)) == true,
                  let device = try? readDevice(id: id) else { return nil }
            let hasChannels = scope == kAudioDevicePropertyScopeInput
                ? device.isInputDevice
                : device.isOutputDevice
            return hasChannels ? device : nil
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func defaultOutputDevice() throws -> AudioDevice? {
        let id = try defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
        return id == kAudioObjectUnknown ? nil : try readDevice(id: id)
    }

    /// The input macOS records from by default.
    public func defaultInputDevice() throws -> AudioDevice? {
        let id = try defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
        return id == kAudioObjectUnknown ? nil : try readDevice(id: id)
    }

    private func defaultDeviceID(_ selector: AudioObjectPropertySelector) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(0)
        var byteCount = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &id
        ))
        return id
    }

    public func device(uid: String) throws -> AudioDevice? {
        try outputDevices().first { $0.uid == uid }
    }

    public func nominalSampleRate(uid: String) throws -> Double? {
        guard let device = try device(uid: uid) else { return nil }
        return try Self.nominalSampleRate(deviceID: device.id)
    }

    public func observeHardwareChanges(
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) throws -> AudioHardwareObservation {
        try AudioHardwareObservation(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selectors: [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice],
            queue: queue,
            handler: handler
        )
    }

    /// Kept apart from `observeHardwareChanges`: a new microphone doesn't affect the route.
    public func observeDefaultInput(
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) throws -> AudioHardwareObservation {
        try AudioHardwareObservation(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selectors: [kAudioHardwarePropertyDefaultInputDevice],
            queue: queue,
            handler: handler
        )
    }

    /// Fires when the device's nominal sample rate changes, for example when a DAW
    /// or Audio MIDI Setup switches an interface to a project's rate.
    public func observeSampleRate(
        deviceID: AudioObjectID,
        queue: DispatchQueue = .main,
        handler: @escaping () -> Void
    ) throws -> AudioHardwareObservation {
        try AudioHardwareObservation(
            objectID: deviceID,
            selectors: [kAudioDevicePropertyNominalSampleRate],
            queue: queue,
            handler: handler
        )
    }

    static func nominalSampleRate(deviceID: AudioObjectID) throws -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = 0.0
        var byteCount = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &sampleRate)
        guard status == noErr else { throw SystemAudioError.coreAudio(status) }
        return sampleRate
    }

    private func readDevice(id: AudioObjectID) throws -> AudioDevice {
        AudioDevice(
            id: id,
            uid: try stringProperty(kAudioDevicePropertyDeviceUID, deviceID: id),
            name: try stringProperty(kAudioObjectPropertyName, deviceID: id),
            outputChannelCount: try channelCount(deviceID: id, scope: kAudioDevicePropertyScopeOutput),
            inputChannelCount: (try? channelCount(deviceID: id, scope: kAudioDevicePropertyScopeInput)) ?? 0,
            isBluetooth: isBluetooth(deviceID: id),
            isContinuity: isContinuity(deviceID: id),
            builtIn: builtInOutput(deviceID: id)
        )
    }

    /// The Mac's own output tells which one it is through its data source: the
    /// headphone jack or the built-in speakers.
    private func builtInOutput(deviceID: AudioObjectID) -> AudioDevice.BuiltInOutput? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSource,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var source: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &source) == noErr else {
            return nil
        }
        return switch source {
        case 0x6864_706E: .headphones  // 'hdpn'
        case 0x6973_706B: .speakers    // 'ispk'
        default: nil
        }
    }

    /// A device that doesn't report its transport isn't treated as Bluetooth.
    private func isBluetooth(deviceID: AudioObjectID) -> Bool {
        let transport = transportType(deviceID: deviceID)
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// An iPhone or iPad acting as a microphone over Continuity Capture.
    private func isContinuity(deviceID: AudioObjectID) -> Bool {
        let transport = transportType(deviceID: deviceID)
        return transport == kAudioDeviceTransportTypeContinuityCaptureWired
            || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
    }

    private func transportType(deviceID: AudioObjectID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &transport) == noErr else {
            return nil
        }
        return transport
    }

    private func stringProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioObjectID
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>? = nil
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &value))
        return value?.takeRetainedValue() as String? ?? "Unknown Audio Device"
    }

    private func channelCount(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteCount))
        guard byteCount > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(byteCount),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, raw))

        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func isSelectable(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Bool {
        if try booleanProperty(
            kAudioDevicePropertyIsHidden,
            scope: kAudioObjectPropertyScopeGlobal,
            deviceID: deviceID
        ) == true {
            return false
        }

        // Some private/aggregate devices do not mark themselves hidden, but still
        // cannot be chosen as the system's default device. Match the choices shown
        // by macOS instead of exposing those internal devices.
        if try booleanProperty(
            kAudioDevicePropertyDeviceCanBeDefaultDevice,
            scope: scope,
            deviceID: deviceID
        ) == false {
            return false
        }

        return true
    }

    /// Returns nil when a device does not implement the property. Older and
    /// third-party drivers should remain visible unless they explicitly opt out.
    private func booleanProperty(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        deviceID: AudioObjectID
    ) throws -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }

        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &byteCount, &value
        ))
        return value != 0
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw SystemAudioError.coreAudio(status) }
    }
}

public final class AudioHardwareObservation {
    private let objectID: AudioObjectID
    private let queue: DispatchQueue
    private let listener: AudioObjectPropertyListenerBlock
    private var addresses: [AudioObjectPropertyAddress] = []

    init(
        objectID: AudioObjectID,
        selectors: [AudioObjectPropertySelector],
        queue: DispatchQueue,
        handler: @escaping () -> Void
    ) throws {
        self.objectID = objectID
        self.queue = queue
        listener = { _, _ in handler() }

        do {
            for selector in selectors {
                try add(selector: selector)
            }
        } catch {
            removeAll()
            throw error
        }
    }

    deinit { removeAll() }

    private func add(selector: AudioObjectPropertySelector) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            objectID,
            &address,
            queue,
            listener
        )
        guard status == noErr else { throw SystemAudioError.coreAudio(status) }
        addresses.append(address)
    }

    private func removeAll() {
        for var address in addresses {
            AudioObjectRemovePropertyListenerBlock(
                objectID,
                &address,
                queue,
                listener
            )
        }
        addresses.removeAll()
    }
}
