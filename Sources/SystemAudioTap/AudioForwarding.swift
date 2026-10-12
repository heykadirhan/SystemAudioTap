import Foundation

/// Processes the captured audio on the output device's real-time thread, just
/// before it reaches the speakers.
public protocol RealtimeAudioProcessor: AnyObject {
    /// Called on the starting thread before rendering begins, and again after
    /// every restart, for example when the output's sample rate changes.
    /// Allocate here, not in `process`.
    func prepare(sampleRate: Double, channelCount: Int, maximumFrameCount: Int)
    /// Called on the audio thread with interleaved Float32 samples to change in
    /// place. Must not allocate, lock, log, or wait. Move parameter changes in
    /// through atomics.
    func process(_ interleavedSamples: UnsafeMutablePointer<Float>, frameCount: Int, channelCount: Int)
}

public struct AudioForwardingDiagnostics: Equatable, Sendable {
    public var framesCaptured: UInt64
    /// Output frames that carried captured audio.
    public var framesPlayed: UInt64
    public var droppedFrames: UInt64
    /// Output frames of silence while the playback buffer filled.
    public var silentFrames: UInt64
    /// Times capture ran dry and playback faded out.
    public var dropouts: UInt64
    /// Crossfaded corrections that moved the buffer back to its latency target.
    public var splices: UInt64
    /// Frames removed or replayed by latency-correction splices.
    public var framesSkipped: UInt64
    public var framesRepeated: UInt64
    /// Captured frames waiting for playback.
    public var bufferedFrames: UInt32
    public var latencyTargetFrames: UInt32

    public init(
        framesCaptured: UInt64 = 0,
        framesPlayed: UInt64 = 0,
        droppedFrames: UInt64 = 0,
        silentFrames: UInt64 = 0,
        dropouts: UInt64 = 0,
        splices: UInt64 = 0,
        framesSkipped: UInt64 = 0,
        framesRepeated: UInt64 = 0,
        bufferedFrames: UInt32 = 0,
        latencyTargetFrames: UInt32 = 0
    ) {
        self.framesCaptured = framesCaptured
        self.framesPlayed = framesPlayed
        self.droppedFrames = droppedFrames
        self.silentFrames = silentFrames
        self.dropouts = dropouts
        self.splices = splices
        self.framesSkipped = framesSkipped
        self.framesRepeated = framesRepeated
        self.bufferedFrames = bufferedFrames
        self.latencyTargetFrames = latencyTargetFrames
    }
}

public protocol AudioForwarding: AnyObject {
    var isRunning: Bool { get }
    var diagnostics: AudioForwardingDiagnostics { get }
    /// The rate the running route was configured for, or nil when stopped.
    var sampleRate: Double? { get }
    func start(source: AudioDevice, destination: AudioDevice) throws
    func stop()
}

public extension AudioForwarding {
    var diagnostics: AudioForwardingDiagnostics { AudioForwardingDiagnostics() }
    var sampleRate: Double? { nil }
}

/// A short, bounded retry schedule for a route that failed after it had already
/// been working. Keeping this policy outside the UI makes the "try quietly, then
/// ask for help" behaviour deterministic and testable.
public struct SystemAudioRecoverySchedule: Equatable, Sendable {
    public static let defaultDelays: [TimeInterval] = [2, 5, 15]

    private let delays: [TimeInterval]
    private var nextIndex = 0

    public init(delays: [TimeInterval] = Self.defaultDelays) {
        precondition(delays.allSatisfy { $0 >= 0 })
        self.delays = delays
    }

    public var hasAttemptsRemaining: Bool { nextIndex < delays.count }

    public mutating func nextDelay() -> TimeInterval? {
        guard hasAttemptsRemaining else { return nil }
        defer { nextIndex += 1 }
        return delays[nextIndex]
    }

    public mutating func reset() {
        nextIndex = 0
    }
}

/// Interprets forwarder counters sampled on the main thread. The render
/// callbacks only count; everything that reasons about the counts lives here.
public struct ForwardingHealthMonitor {
    public struct Report: Equatable, Sendable {
        public var minimumBufferedFrames: UInt32
        public var maximumBufferedFrames: UInt32
        public var latencyTargetFrames: UInt32
        public var droppedFrames: UInt64
        public var dropouts: UInt64
        public var splices: UInt64
        public var framesSkipped: UInt64
        public var framesRepeated: UInt64
        /// Frames capture delivered and playback asked for since the route's first
        /// sample. Dropped frames count as delivered and silence as asked for, so
        /// the buffer's corrections can't hide how far apart the clocks run.
        public var framesDelivered: UInt64
        public var framesRequested: UInt64

        public init(
            minimumBufferedFrames: UInt32,
            maximumBufferedFrames: UInt32,
            latencyTargetFrames: UInt32 = 0,
            droppedFrames: UInt64,
            dropouts: UInt64 = 0,
            splices: UInt64 = 0,
            framesSkipped: UInt64 = 0,
            framesRepeated: UInt64 = 0,
            framesDelivered: UInt64 = 0,
            framesRequested: UInt64 = 0
        ) {
            self.minimumBufferedFrames = minimumBufferedFrames
            self.maximumBufferedFrames = maximumBufferedFrames
            self.latencyTargetFrames = latencyTargetFrames
            self.droppedFrames = droppedFrames
            self.dropouts = dropouts
            self.splices = splices
            self.framesSkipped = framesSkipped
            self.framesRepeated = framesRepeated
            self.framesDelivered = framesDelivered
            self.framesRequested = framesRequested
        }

        /// How much faster the capture clock runs than the playback clock. Below zero
        /// the buffer drains and needs repeat splices; above zero it fills and needs
        /// skips. Main-thread sampling makes each count up to one IO cycle stale, so
        /// the figure settles as the route keeps running.
        public var clockDriftPartsPerMillion: Double? {
            guard framesRequested > 0 else { return nil }
            return (Double(framesDelivered) - Double(framesRequested)) / Double(framesRequested) * 1_000_000
        }

        static let empty = Report(
            minimumBufferedFrames: .max,
            maximumBufferedFrames: 0,
            droppedFrames: 0
        )
    }

    public enum Event: Equatable, Sendable {
        /// The first dropped frames or dropout within a report window. Buffering
        /// before playback starts and splices are not glitches.
        case glitch(droppedFrames: UInt64, dropouts: UInt64)
        /// Capture keeps running but playback stopped. The tapped apps stay
        /// muted while nothing reaches the speakers.
        case playbackStalled
        /// Playback keeps asking for audio but capture delivers none, for example when
        /// its renders fail. The tapped apps stay muted while the speakers play silence.
        case captureStalled
        case report(Report)
    }

    private let stallSampleCount: Int
    private let reportSampleCount: Int
    private var previous = AudioForwardingDiagnostics()
    /// Where the clock comparison starts, or nil until the buffer is near its target.
    private var first: AudioForwardingDiagnostics?
    private var stalledSamples = 0
    private var captureStalledSamples = 0
    private var samplesInReport = 0
    private var report = Report.empty

    public init(stallSampleCount: Int = 3, reportSampleCount: Int = 40) {
        precondition(stallSampleCount > 0 && reportSampleCount > 0)
        self.stallSampleCount = stallSampleCount
        self.reportSampleCount = reportSampleCount
    }

    public mutating func add(_ sample: AudioForwardingDiagnostics) -> [Event] {
        let captured = Self.delta(sample.framesCaptured, previous.framesCaptured)
        let played = Self.delta(sample.framesPlayed, previous.framesPlayed)
        let dropped = Self.delta(sample.droppedFrames, previous.droppedFrames)
        let silent = Self.delta(sample.silentFrames, previous.silentFrames)
        let dropouts = Self.delta(sample.dropouts, previous.dropouts)
        let splices = Self.delta(sample.splices, previous.splices)
        let skipped = Self.delta(sample.framesSkipped, previous.framesSkipped)
        let repeated = Self.delta(sample.framesRepeated, previous.framesRepeated)
        previous = sample
        // Restarted counters start the clock comparison over. So do dropped frames:
        // splices keep the buffer near its target, so it only fills up when playback
        // stops asking for audio for a moment. The dropped frames, and the backlog
        // splices skip afterwards, would read as a fast capture clock, so the
        // comparison starts again once the buffer is back near its target.
        if let start = first,
           dropped > 0
            || Self.delivered(sample) < Self.delivered(start)
            || Self.requested(sample) < Self.requested(start) {
            first = nil
        }
        if first == nil, dropped == 0, sample.bufferedFrames / 2 <= sample.latencyTargetFrames {
            first = sample
        }

        var events: [Event] = []
        if dropped > 0 || dropouts > 0 {
            if report.droppedFrames == 0 && report.dropouts == 0 {
                events.append(.glitch(droppedFrames: dropped, dropouts: dropouts))
            }
            report.droppedFrames += dropped
            report.dropouts += dropouts
        }
        report.splices += splices
        report.framesSkipped += skipped
        report.framesRepeated += repeated

        // A full buffer stops counting captured frames and counts drops instead,
        // and a filling buffer plays silence.
        let captureAdvanced = captured > 0 || dropped > 0
        let playbackAdvanced = played > 0 || silent > 0
        stalledSamples = captureAdvanced && !playbackAdvanced ? stalledSamples + 1 : 0
        if stalledSamples == stallSampleCount {
            events.append(.playbackStalled)
        }
        captureStalledSamples = playbackAdvanced && !captureAdvanced ? captureStalledSamples + 1 : 0
        if captureStalledSamples == stallSampleCount {
            events.append(.captureStalled)
        }

        report.minimumBufferedFrames = min(report.minimumBufferedFrames, sample.bufferedFrames)
        report.maximumBufferedFrames = max(report.maximumBufferedFrames, sample.bufferedFrames)
        samplesInReport += 1
        if samplesInReport == reportSampleCount {
            report.latencyTargetFrames = sample.latencyTargetFrames
            report.framesDelivered = first.map { Self.delivered(sample) - Self.delivered($0) } ?? 0
            report.framesRequested = first.map { Self.requested(sample) - Self.requested($0) } ?? 0
            events.append(.report(report))
            report = .empty
            samplesInReport = 0
        }
        return events
    }

    private static func delivered(_ sample: AudioForwardingDiagnostics) -> UInt64 {
        sample.framesCaptured + sample.droppedFrames
    }

    private static func requested(_ sample: AudioForwardingDiagnostics) -> UInt64 {
        sample.framesPlayed + sample.silentFrames
    }

    /// Counters restart from zero when the route restarts.
    private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : current
    }
}
