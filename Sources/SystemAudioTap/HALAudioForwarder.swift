import AudioTapBridge
import AudioToolbox
import CoreAudio
import Foundation

/// Bridges the private system-audio tap's aggregate device to a fixed physical
/// output with two AUHAL instances. The output unit is pinned to the destination
/// device instead of following the system default, and the tap excludes
/// this process, so processed audio cannot feed back into capture.
public final class HALAudioForwarder: AudioForwarding {
    private static let channelCount: UInt32 = 2
    private static let maximumFramesPerSlice: UInt32 = 4096

    public private(set) var isRunning = false

    public var diagnostics: AudioForwardingDiagnostics {
        guard let fifo, let reader else { return AudioForwardingDiagnostics() }
        var written: UInt64 = 0
        var dropped: UInt64 = 0
        SATAudioFIFOGetStats(fifo, &written, nil, &dropped, nil)
        var playback = SATFIFOReaderStats()
        SATFIFOReaderGetStats(reader, &playback)
        return AudioForwardingDiagnostics(
            framesCaptured: written,
            framesPlayed: playback.framesPlayed,
            droppedFrames: dropped,
            silentFrames: playback.silentFrames,
            dropouts: playback.dropouts,
            splices: playback.splices,
            framesSkipped: playback.framesSkipped,
            framesRepeated: playback.framesRepeated,
            bufferedFrames: SATAudioFIFOAvailableFrames(fifo),
            latencyTargetFrames: playback.latencyTargetFrames
        )
    }

    public private(set) var sampleRate: Double?

    private var inputUnit: AudioUnit?
    private var outputUnit: AudioUnit?
    private var captureBuffer: UnsafeMutablePointer<Float>?
    private let fifo: OpaquePointer?
    private let reader: OpaquePointer?
    private let processor: RealtimeAudioProcessor?

    /// `processor` runs on the output's render thread. Without one, captured
    /// audio plays unchanged.
    public init(processor: RealtimeAudioProcessor? = nil) {
        self.processor = processor
        fifo = SATAudioFIFOCreate()
        reader = SATFIFOReaderCreate()
    }

    deinit {
        stop()
        SATAudioFIFODestroy(fifo)
        SATFIFOReaderDestroy(reader)
    }

    public func start(source: AudioDevice, destination: AudioDevice) throws {
        stop()
        guard source.uid != destination.uid else { throw SystemAudioError.invalidDestination }
        guard let fifo, let reader else { throw SystemAudioError.audioBufferAllocationFailed }

        let sampleRate = try CoreAudioDeviceManager.nominalSampleRate(deviceID: AudioDeviceID(destination.id))
        guard sampleRate > 0 else { throw SystemAudioError.audioFormatUnavailable }
        // An AUHAL input doesn't convert rates. At another rate every capture render
        // fails, and the tapped apps stay muted while the speakers play silence.
        guard try CoreAudioDeviceManager.nominalSampleRate(deviceID: AudioDeviceID(source.id)) == sampleRate else {
            throw SystemAudioError.audioFormatUnavailable
        }

        let input = try makeHALUnit()
        let output = try makeHALUnit()
        inputUnit = input
        outputUnit = output

        do {
            try configureInputUnit(input, deviceID: AudioDeviceID(source.id), sampleRate: sampleRate)
            try configureOutputUnit(output, deviceID: AudioDeviceID(destination.id), sampleRate: sampleRate)

            captureBuffer = .allocate(
                capacity: Int(Self.maximumFramesPerSlice * Self.channelCount)
            )
            processor?.prepare(
                sampleRate: sampleRate,
                channelCount: Int(Self.channelCount),
                maximumFrameCount: Int(Self.maximumFramesPerSlice)
            )
            SATAudioFIFOClear(fifo)
            var readerConfiguration = Self.readerConfiguration(sampleRate: sampleRate)
            SATFIFOReaderReset(reader, &readerConfiguration)

            var inputCallback = AURenderCallbackStruct(
                inputProc: Self.inputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(AudioUnitSetProperty(
                input,
                kAudioOutputUnitProperty_SetInputCallback,
                kAudioUnitScope_Global,
                0,
                &inputCallback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ))

            var outputCallback = AURenderCallbackStruct(
                inputProc: Self.outputCallback,
                inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
            )
            try check(AudioUnitSetProperty(
                output,
                kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input,
                0,
                &outputCallback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            ))

            try check(AudioUnitInitialize(input))
            try check(AudioUnitInitialize(output))
            try check(AudioOutputUnitStart(input))
            do {
                try check(AudioOutputUnitStart(output))
            } catch {
                AudioOutputUnitStop(input)
                throw error
            }
            self.sampleRate = sampleRate
            isRunning = true
        } catch {
            tearDownUnits()
            throw error
        }
    }

    public func stop() {
        guard inputUnit != nil || outputUnit != nil || captureBuffer != nil else {
            isRunning = false
            return
        }
        tearDownUnits()
    }

    private func configureInputUnit(
        _ unit: AudioUnit,
        deviceID: AudioDeviceID,
        sampleRate: Double
    ) throws {
        var enableInput: UInt32 = 1
        var disableOutput: UInt32 = 0
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &enableInput, UInt32(MemoryLayout<UInt32>.size)
        ))
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &disableOutput, UInt32(MemoryLayout<UInt32>.size)
        ))
        try setDevice(unit, deviceID: deviceID)
        var format = Self.clientFormat(sampleRate: sampleRate)
        try check(AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ))
        try setMaximumFrames(unit)
    }

    private func configureOutputUnit(
        _ unit: AudioUnit,
        deviceID: AudioDeviceID,
        sampleRate: Double
    ) throws {
        var enableOutput: UInt32 = 1
        var disableInput: UInt32 = 0
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
            &enableOutput, UInt32(MemoryLayout<UInt32>.size)
        ))
        try check(AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
            &disableInput, UInt32(MemoryLayout<UInt32>.size)
        ))
        try setDevice(unit, deviceID: deviceID)
        var format = Self.clientFormat(sampleRate: sampleRate)
        try check(AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
            &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ))
        try setMaximumFrames(unit)
    }

    private func setDevice(_ unit: AudioUnit, deviceID: AudioDeviceID) throws {
        var mutableDeviceID = deviceID
        try check(AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ))
    }

    private func setMaximumFrames(_ unit: AudioUnit) throws {
        var frames = Self.maximumFramesPerSlice
        try check(AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &frames,
            UInt32(MemoryLayout<UInt32>.size)
        ))
    }

    private func capture(
        actionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount: UInt32
    ) -> OSStatus {
        guard frameCount <= Self.maximumFramesPerSlice,
              let inputUnit,
              let captureBuffer,
              let fifo else { return kAudioUnitErr_TooManyFramesToProcess }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: Self.channelCount,
                mDataByteSize: frameCount * Self.channelCount * UInt32(MemoryLayout<Float>.size),
                mData: captureBuffer
            )
        )
        let status = AudioUnitRender(
            inputUnit,
            actionFlags,
            timestamp,
            1,
            frameCount,
            &bufferList
        )
        guard status == noErr else { return status }
        _ = SATAudioFIFOWrite(fifo, captureBuffer, frameCount)
        return noErr
    }

    private func render(frameCount: UInt32, outputData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard frameCount <= Self.maximumFramesPerSlice,
              let outputData,
              let fifo,
              let reader else { return kAudioUnitErr_TooManyFramesToProcess }

        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        guard buffers.count == 1,
              buffers[0].mNumberChannels == Self.channelCount,
              let rawData = buffers[0].mData else {
            for buffer in buffers {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return kAudio_ParamError
        }

        let samples = rawData.assumingMemoryBound(to: Float.self)
        SATFIFOReaderRead(reader, fifo, samples, frameCount)
        processor?.process(samples, frameCount: Int(frameCount), channelCount: Int(Self.channelCount))
        return noErr
    }

    private func tearDownUnits() {
        isRunning = false
        sampleRate = nil
        if let outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
        }
        if let inputUnit {
            AudioOutputUnitStop(inputUnit)
            AudioUnitUninitialize(inputUnit)
            AudioComponentInstanceDispose(inputUnit)
        }
        self.outputUnit = nil
        self.inputUnit = nil
        captureBuffer?.deallocate()
        captureBuffer = nil
        if let fifo { SATAudioFIFOClear(fifo) }
        if let reader { SATFIFOReaderReset(reader, nil) }
    }

    private func makeHALUnit() throws -> AudioUnit {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw SystemAudioError.forwardingUnavailable
        }
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(component, &unit))
        guard let unit else { throw SystemAudioError.forwardingUnavailable }
        return unit
    }

    /// About 50 ms of latency to start, which the reader raises after dropouts, up to
    /// 120 ms, and lowers again after 10 minutes without one. The splice search
    /// covers one period of 50 Hz, so sustained bass stays in phase across a splice.
    private static func readerConfiguration(sampleRate: Double) -> SATFIFOReaderConfiguration {
        func frames(_ seconds: Double) -> UInt32 { UInt32((seconds * sampleRate).rounded()) }
        return SATFIFOReaderConfiguration(
            initialLatencyFrames: frames(0.05),
            minimumLatencyFrames: frames(0.03),
            maximumLatencyFrames: frames(0.12),
            fadeFrames: frames(0.003),
            crossfadeFrames: frames(0.01),
            spliceSearchFrames: frames(0.02),
            checkFrames: frames(4),
            relaxFrames: UInt64((600 * sampleRate).rounded())
        )
    }

    private static func clientFormat(sampleRate: Double) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: channelCount * UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: channelCount * UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw SystemAudioError.coreAudio(status) }
    }

    private static let inputCallback: AURenderCallback = {
        reference, actionFlags, timestamp, _, frameCount, _ in
        let forwarder = Unmanaged<HALAudioForwarder>.fromOpaque(reference).takeUnretainedValue()
        return forwarder.capture(
            actionFlags: actionFlags,
            timestamp: timestamp,
            frameCount: frameCount
        )
    }

    private static let outputCallback: AURenderCallback = {
        reference, _, _, _, frameCount, outputData in
        let forwarder = Unmanaged<HALAudioForwarder>.fromOpaque(reference).takeUnretainedValue()
        return forwarder.render(frameCount: frameCount, outputData: outputData)
    }
}
