import CoreAudio
import Foundation

public struct AudioDevice: Equatable, Identifiable, Sendable {
    /// Which of the Mac's own outputs a device is.
    public enum BuiltInOutput: Sendable {
        case headphones
        case speakers
    }

    public let id: UInt32
    public let uid: String
    public let name: String
    public let outputChannelCount: Int
    public let inputChannelCount: Int
    /// Bluetooth outputs add delay and can drop out for a moment.
    public let isBluetooth: Bool
    /// An iPhone or iPad used as a microphone, which can sit where the listener does.
    public let isContinuity: Bool
    /// Set for the headphone jack and the Mac's own speakers.
    public let builtIn: BuiltInOutput?

    public init(
        id: UInt32,
        uid: String,
        name: String,
        outputChannelCount: Int,
        inputChannelCount: Int = 0,
        isBluetooth: Bool = false,
        isContinuity: Bool = false,
        builtIn: BuiltInOutput? = nil
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.outputChannelCount = outputChannelCount
        self.inputChannelCount = inputChannelCount
        self.isBluetooth = isBluetooth
        self.isContinuity = isContinuity
        self.builtIn = builtIn
    }

    public var isOutputDevice: Bool { outputChannelCount > 0 }
    public var isInputDevice: Bool { inputChannelCount > 0 }
}

public enum SystemAudioError: LocalizedError, Equatable {
    case destinationUnavailable
    case destinationIsNotDefault
    case invalidDestination
    case forwardingUnavailable
    case audioFormatUnavailable
    case audioBufferAllocationFailed
    case systemAudioTapUnavailable
    case coreAudio(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .destinationUnavailable:
            "The selected output isn't connected."
        case .destinationIsNotDefault:
            "The selected output isn't the macOS default output."
        case .invalidDestination:
            "The selected output can't receive tapped audio."
        case .forwardingUnavailable:
            "The HAL output unit isn't available."
        case .audioFormatUnavailable:
            "Couldn't establish a matching stereo Float32 format at the output's sample rate."
        case .audioBufferAllocationFailed:
            "Couldn't allocate the real-time audio buffer."
        case .systemAudioTapUnavailable:
            "Couldn't access system audio. Allow Screen & System Audio Recording in System Settings, then try again."
        case let .coreAudio(status):
            "Core Audio returned error \(status)."
        }
    }
}
