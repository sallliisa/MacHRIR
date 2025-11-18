//
//  HRIRManager.swift
//  MacHRIR
//
//  Manages HRIR presets and convolution processing
//

import Foundation
import Combine

/// Represents an HRIR preset
struct HRIRPreset: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let name: String
    let fileURL: URL
    let channelCount: Int
    let sampleRate: Double

    static func == (lhs: HRIRPreset, rhs: HRIRPreset) -> Bool {
        return lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Manages HRIR presets and convolution processing
class HRIRManager: ObservableObject {

    // MARK: - Published Properties

    @Published var presets: [HRIRPreset] = []
    @Published var activePreset: HRIRPreset?
    @Published var convolutionEnabled: Bool = false
    @Published var errorMessage: String?

    // MARK: - Private Properties

    private var leftConvolver: ConvolutionEngine?
    private var rightConvolver: ConvolutionEngine?
    private let processingBlockSize: Int = 512

    private let presetsDirectory: URL

    // MARK: - Initialization

    init() {
        // Set up presets directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        presetsDirectory = appSupport.appendingPathComponent("MacHRIR/presets", isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)

        // Load existing presets
        loadPresets()
    }

    // MARK: - Public Methods

    /// Add a new preset from a WAV file
    /// - Parameter fileURL: URL to the WAV file
    /// - Throws: Error if loading or validation fails
    func addPreset(from fileURL: URL) throws {
        // Load WAV file
        let wavData = try WAVLoader.load(from: fileURL)

        // Validate
        guard wavData.channelCount >= 1 else {
            throw HRIRError.invalidChannelCount(wavData.channelCount)
        }

        guard wavData.frameCount > 0 else {
            throw HRIRError.emptyFile
        }

        // Create preset
        let preset = HRIRPreset(
            id: UUID(),
            name: fileURL.deletingPathExtension().lastPathComponent,
            fileURL: fileURL,
            channelCount: wavData.channelCount,
            sampleRate: wavData.sampleRate
        )

        // Copy file to presets directory
        let destinationURL = presetsDirectory.appendingPathComponent(fileURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: fileURL, to: destinationURL)

        // Update preset with new URL
        let updatedPreset = HRIRPreset(
            id: preset.id,
            name: preset.name,
            fileURL: destinationURL,
            channelCount: preset.channelCount,
            sampleRate: preset.sampleRate
        )

        DispatchQueue.main.async {
            self.presets.append(updatedPreset)
            self.savePresets()
            self.errorMessage = nil
        }
    }

    /// Remove a preset
    /// - Parameter preset: The preset to remove
    func removePreset(_ preset: HRIRPreset) {
        // Remove file
        try? FileManager.default.removeItem(at: preset.fileURL)

        // Remove from list
        presets.removeAll { $0.id == preset.id }

        // Clear active preset if it was removed
        if activePreset?.id == preset.id {
            activePreset = nil
            leftConvolver = nil
            rightConvolver = nil
        }

        savePresets()
    }

    /// Select and load a preset for convolution
    /// - Parameters:
    ///   - preset: The preset to activate
    ///   - targetSampleRate: The sample rate to resample to
    func activatePreset(_ preset: HRIRPreset, targetSampleRate: Double) {
        do {
            // Load WAV file
            let wavData = try WAVLoader.load(from: preset.fileURL)

            // Extract stereo channels
            let (leftIR, rightIR) = try WAVLoader.extractStereoChannels(from: wavData)

            // Resample if needed
            let resampledLeft: [Float]
            let resampledRight: [Float]

            if abs(wavData.sampleRate - targetSampleRate) > 0.01 {
                resampledLeft = Resampler.resampleHighQuality(
                    input: leftIR,
                    fromRate: wavData.sampleRate,
                    toRate: targetSampleRate
                )
                resampledRight = Resampler.resampleHighQuality(
                    input: rightIR,
                    fromRate: wavData.sampleRate,
                    toRate: targetSampleRate
                )
            } else {
                resampledLeft = leftIR
                resampledRight = rightIR
            }

            // Create convolution engines
            guard let leftEngine = ConvolutionEngine(hrirSamples: resampledLeft, blockSize: processingBlockSize) else {
                throw HRIRError.convolutionSetupFailed("Failed to create left channel convolver")
            }

            guard let rightEngine = ConvolutionEngine(hrirSamples: resampledRight, blockSize: processingBlockSize) else {
                throw HRIRError.convolutionSetupFailed("Failed to create right channel convolver")
            }

            // Set engines
            leftConvolver = leftEngine
            rightConvolver = rightEngine

            DispatchQueue.main.async {
                self.activePreset = preset
                self.errorMessage = nil
            }

        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to activate preset: \(error.localizedDescription)"
            }
        }
    }

    /// Process audio through convolution
    /// - Parameters:
    ///   - leftInput: Left channel input samples
    ///   - rightInput: Right channel input samples
    ///   - leftOutput: Left channel output buffer
    ///   - rightOutput: Right channel output buffer
    ///   - frameCount: Number of frames to process
    func processAudio(
        leftInput: [Float],
        rightInput: [Float],
        leftOutput: inout [Float],
        rightOutput: inout [Float],
        frameCount: Int
    ) {
        // TEMPORARILY DISABLED: Convolution not working yet
        // Passthrough mode - copy input to output
        for i in 0..<frameCount {
            leftOutput[i] = leftInput[i]
            rightOutput[i] = rightInput[i]
        }

        /* TODO: Fix convolution implementation
        guard convolutionEnabled,
              let leftConv = leftConvolver,
              let rightConv = rightConvolver else {
            // Passthrough mode - copy input to output
            for i in 0..<frameCount {
                leftOutput[i] = leftInput[i]
                rightOutput[i] = rightInput[i]
            }
            return
        }

        // Check if frame count matches block size
        if frameCount != processingBlockSize {
            // Size mismatch - passthrough for this block
            for i in 0..<frameCount {
                leftOutput[i] = leftInput[i]
                rightOutput[i] = rightInput[i]
            }
            return
        }

        // Process through convolution
        leftConv.process(input: leftInput, output: &leftOutput, frameCount: frameCount)
        rightConv.process(input: rightInput, output: &rightOutput, frameCount: frameCount)
        */
    }

    // MARK: - Private Methods

    private func loadPresets() {
        // Load presets metadata from JSON
        let metadataURL = presetsDirectory.appendingPathComponent("presets.json")

        guard FileManager.default.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let loadedPresets = try? JSONDecoder().decode([HRIRPreset].self, from: data) else {
            return
        }

        DispatchQueue.main.async {
            self.presets = loadedPresets.filter { FileManager.default.fileExists(atPath: $0.fileURL.path) }
        }
    }

    private func savePresets() {
        let metadataURL = presetsDirectory.appendingPathComponent("presets.json")

        guard let data = try? JSONEncoder().encode(presets) else {
            print("Failed to encode presets")
            return
        }

        try? data.write(to: metadataURL)
    }
}

// MARK: - Error Types

enum HRIRError: LocalizedError {
    case invalidChannelCount(Int)
    case emptyFile
    case convolutionSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidChannelCount(let count):
            return "Invalid HRIR channel count: \(count). Must have at least 1 channel."
        case .emptyFile:
            return "HRIR file is empty"
        case .convolutionSetupFailed(let detail):
            return "Failed to set up convolution: \(detail)"
        }
    }
}
