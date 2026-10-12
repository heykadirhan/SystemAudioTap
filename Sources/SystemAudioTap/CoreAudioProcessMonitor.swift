import CoreAudio
import Darwin
import Foundation

/// An app's audio client, as Core Audio lists it. A process appears once it has
/// used audio.
public struct AudioProcess: Equatable, Sendable {
    public let id: AudioObjectID
    public let pid: pid_t
    /// The process's own bundle ID, then the outermost app containing its executable
    /// when that differs. A browser's audio helper, for example, has both.
    public let bundleIDs: [String]
    /// The outermost app's name, for example "REAPER".
    public let appName: String?
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(
        id: AudioObjectID,
        pid: pid_t,
        bundleIDs: [String],
        appName: String?,
        isRunningInput: Bool,
        isRunningOutput: Bool
    ) {
        self.id = id
        self.pid = pid
        self.bundleIDs = bundleIDs
        self.appName = appName
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

/// Reads Core Audio's process list, and calls `handler` on the main queue when a
/// process appears or goes away, or starts or stops audio input or output.
public final class CoreAudioProcessMonitor {
    private struct App {
        let bundleID: String?
        let name: String
    }

    private let handler: () -> Void
    private var listObservation: AudioHardwareObservation?
    private var processObservations: [AudioObjectID: AudioHardwareObservation] = [:]
    /// Keyed by PID, so the executable path and Info.plist are read once per process.
    private var apps: [pid_t: App?] = [:]

    public init(handler: @escaping () -> Void) throws {
        self.handler = handler
        listObservation = try AudioHardwareObservation(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selectors: [kAudioHardwarePropertyProcessObjectList],
            queue: .main
        ) { [weak self] in
            self?.observeProcesses()
            self?.handler()
        }
        observeProcesses()
    }

    public func processes() -> [AudioProcess] {
        let processes = processObjectIDs().compactMap(readProcess)
        let pids = Set(processes.map(\.pid))
        apps = apps.filter { pids.contains($0.key) }
        return processes
    }

    private func observeProcesses() {
        let ids = Set(processObjectIDs())
        processObservations = processObservations.filter { ids.contains($0.key) }
        for id in ids where processObservations[id] == nil {
            processObservations[id] = try? AudioHardwareObservation(
                objectID: id,
                selectors: [kAudioProcessPropertyIsRunningInput, kAudioProcessPropertyIsRunningOutput],
                queue: .main
            ) { [weak self] in
                self?.handler()
            }
        }
    }

    private func processObjectIDs() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &byteCount) == noErr,
              byteCount > 0 else { return [] }
        var ids = Array(repeating: AudioObjectID(0), count: Int(byteCount) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { storage in
            AudioObjectGetPropertyData(system, &address, 0, nil, &byteCount, storage.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(byteCount) / MemoryLayout<AudioObjectID>.size))
    }

    /// A process can quit while the list is read. It's skipped.
    private func readProcess(_ id: AudioObjectID) -> AudioProcess? {
        guard let pidBits = uint32Property(kAudioProcessPropertyPID, objectID: id) else { return nil }
        let pid = pid_t(bitPattern: pidBits)
        let app = apps[pid] ?? Self.outermostApp(pid: pid)
        apps[pid] = app
        var bundleIDs: [String] = []
        if let own = stringProperty(kAudioProcessPropertyBundleID, objectID: id), !own.isEmpty {
            bundleIDs.append(own)
        }
        if let appBundleID = app?.bundleID, !bundleIDs.contains(appBundleID) {
            bundleIDs.append(appBundleID)
        }
        return AudioProcess(
            id: id,
            pid: pid,
            bundleIDs: bundleIDs,
            appName: app?.name,
            isRunningInput: uint32Property(kAudioProcessPropertyIsRunningInput, objectID: id) ?? 0 != 0,
            isRunningOutput: uint32Property(kAudioProcessPropertyIsRunningOutput, objectID: id) ?? 0 != 0
        )
    }

    /// Nil for a process that isn't inside an app bundle, such as a system daemon.
    private static func outermostApp(pid: pid_t) -> App? {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(cString: path)
        guard let end = executable.range(of: ".app/") else { return nil }
        let appURL = URL(fileURLWithPath: String(executable[..<end.lowerBound]) + ".app")
        let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist"))
        return App(
            bundleID: info?["CFBundleIdentifier"] as? String,
            name: appURL.deletingPathExtension().lastPathComponent
        )
    }

    private func uint32Property(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> UInt32? {
        var address = Self.address(selector)
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value) == noErr else {
            return nil
        }
        return value
    }

    private func stringProperty(_ selector: AudioObjectPropertySelector, objectID: AudioObjectID) -> String? {
        var address = Self.address(selector)
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
