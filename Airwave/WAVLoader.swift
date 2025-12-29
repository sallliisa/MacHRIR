//
//  WAVLoader.swift
//  Airwave
//
//  Loads multi-channel WAV files for HRIR presets
//

import Foundation
import AVFoundation

/// Represents loaded WAV file data
struct WAVData {
    let sampleRate: Double
    let channelCount: Int
    let frameCount: Int
    let audioData: [[Float]]  // Array of channels, each containing samples
}

/// Loads and parses WAV files
class WAVLoader {

    /// Load a WAV file and extract audio data
    /// - Parameter url: URL to the WAV file
    /// - Returns: WAVData containing the loaded audio
    /// - Throws: Error if loading or parsing fails
    static func load(from url: URL) throws -> WAVData {
        // Use AVAudioFile for robust WAV loading
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw WAVError.fileReadError("Failed to open WAV file: \(error.localizedDescription)")
        }

        let format = audioFile.processingFormat
        let channelCount = Int(format.channelCount)
        let sampleRate = format.sampleRate
        let frameCount = Int(audioFile.length)

        guard channelCount > 0 else {
            throw WAVError.invalidChannelCount(channelCount)
        }

        guard frameCount > 0 else {
            throw WAVError.emptyFile
        }

        // Allocate buffer to read audio data
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw WAVError.bufferAllocationFailed
        }

        // Read entire file
        do {
            try audioFile.read(into: buffer)
        } catch {
            throw WAVError.fileReadError("Failed to read audio data: \(error.localizedDescription)")
        }

        // Extract samples from buffer
        var audioData: [[Float]] = []

        if let floatChannelData = buffer.floatChannelData {
            // Audio is already in float format
            for channel in 0..<channelCount {
                let channelPointer = floatChannelData[channel]
                let samples = Array(UnsafeBufferPointer(start: channelPointer, count: Int(buffer.frameLength)))
                audioData.append(samples)
            }
        } else if let int16ChannelData = buffer.int16ChannelData {
            // Convert from Int16 to Float
            for channel in 0..<channelCount {
                let channelPointer = int16ChannelData[channel]
                let int16Samples = UnsafeBufferPointer(start: channelPointer, count: Int(buffer.frameLength))
                let floatSamples = int16Samples.map { Float($0) / 32768.0 }
                audioData.append(floatSamples)
            }
        } else if let int32ChannelData = buffer.int32ChannelData {
            // Convert from Int32 to Float
            for channel in 0..<channelCount {
                let channelPointer = int32ChannelData[channel]
                let int32Samples = UnsafeBufferPointer(start: channelPointer, count: Int(buffer.frameLength))
                let floatSamples = int32Samples.map { Float($0) / 2147483648.0 }
                audioData.append(floatSamples)
            }
        } else {
            throw WAVError.unsupportedFormat
        }

        return WAVData(
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: frameCount,
            audioData: audioData
        )
    }

    /// Extract stereo channels from multi-channel HRIR
    /// - Parameter wavData: The loaded WAV data
    /// - Returns: Tuple of (leftChannel, rightChannel)
    /// - Throws: Error if channel extraction fails
    static func extractStereoChannels(from wavData: WAVData) throws -> (left: [Float], right: [Float]) {
        guard wavData.channelCount >= 1 else {
            throw WAVError.invalidChannelCount(wavData.channelCount)
        }

        let leftChannel = wavData.audioData[0]

        let rightChannel: [Float]
        if wavData.channelCount >= 2 {
            // Use channel 1 for right
            rightChannel = wavData.audioData[1]
        } else {
            // Mono file: duplicate left channel
            rightChannel = leftChannel
        }

        return (leftChannel, rightChannel)
    }
}

// MARK: - Error Types

enum WAVError: LocalizedError {
    case fileReadError(String)
    case invalidChannelCount(Int)
    case emptyFile
    case bufferAllocationFailed
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .fileReadError(let detail):
            return "WAV file read error: \(detail)"
        case .invalidChannelCount(let count):
            return "Invalid channel count: \(count). WAV file must have at least 1 channel."
        case .emptyFile:
            return "WAV file is empty (0 frames)"
        case .bufferAllocationFailed:
            return "Failed to allocate audio buffer"
        case .unsupportedFormat:
            return "Unsupported WAV format"
        }
    }
}
