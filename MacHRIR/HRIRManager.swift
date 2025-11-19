//
//  HRIRManager.swift
//  MacHRIR
//
//  Manages HRIR presets and multi-channel convolution processing
//

import Foundation
import Combine
import Accelerate

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

/// Renders a single virtual speaker to binaural output
struct VirtualSpeakerRenderer {
    let speaker: VirtualSpeaker
    let convolverLeftEar: ConvolutionEngine
    let convolverRightEar: ConvolutionEngine
}

/// Manages HRIR presets and multi-channel convolution processing
class HRIRManager: ObservableObject {

    // MARK: - Published Properties

    @Published var presets: [HRIRPreset] = []
    @Published var activePreset: HRIRPreset?
    @Published var convolutionEnabled: Bool = false
    @Published var errorMessage: String?
    @Published var currentInputLayout: InputLayout = .stereo
    @Published var currentHRIRMap: HRIRChannelMap?

    // MARK: - Private Properties

    // Multi-channel rendering: one renderer per input channel
    private var renderers: [VirtualSpeakerRenderer] = []
    
    private let processingBlockSize: Int = 512
    
    // Temporary buffers for convolution (pre-allocated)
    private var tempConvolutionBuffer: [Float] = []

    private let presetsDirectory: URL

    // MARK: - Initialization

    init() {
        // Set up presets directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        presetsDirectory = appSupport.appendingPathComponent("MacHRIR/presets", isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)
        
        // Pre-allocate temp buffer
        tempConvolutionBuffer = [Float](repeating: 0, count: processingBlockSize)

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
        guard wavData.channelCount >= 2 else {
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
            renderers.removeAll()
        }

        savePresets()
    }

    /// Select and load a preset for convolution with specified input layout
    /// - Parameters:
    ///   - preset: The preset to activate
    ///   - targetSampleRate: The sample rate to resample to
    ///   - inputLayout: The layout of input channels (detected from device)
    ///   - hrirMap: Optional custom HRIR channel mapping (defaults to interleaved pairs)
    func activatePreset(
        _ preset: HRIRPreset,
        targetSampleRate: Double,
        inputLayout: InputLayout,
        hrirMap: HRIRChannelMap? = nil
    ) {
        do {
            // Load WAV file
            let wavData = try WAVLoader.load(from: preset.fileURL)

            print("[HRIRManager] Activating preset: \(preset.name)")
            print("[HRIRManager] HRIR channels: \(wavData.channelCount), Input layout: \(inputLayout.name)")

            // Debug: Analyze ALL HRIR channels to understand the file structure
            func calculateRMS(_ samples: [Float]) -> Float {
                var sum: Float = 0
                vDSP_svesq(samples, 1, &sum, vDSP_Length(samples.count))
                return sqrt(sum / Float(samples.count))
            }
            
            print("[HRIRManager] === HRIR Channel Analysis ===")
            for (idx, channelData) in wavData.audioData.enumerated() {
                let rms = calculateRMS(channelData)
                let peak = channelData.map { abs($0) }.max() ?? 0
                print("[HRIRManager]   Ch[\(idx)]: RMS=\(String(format: "%.6f", rms)) Peak=\(String(format: "%.6f", peak))")
            }
            print("[HRIRManager] ================================")

            // Determine HRIR mapping
            let channelMap: HRIRChannelMap
            if let customMap = hrirMap {
                channelMap = customMap
            } else {
                // Auto-detect mapping format based on channel count
                // Assume interleaved pairs by default
                let speakerCount = wavData.channelCount / 2
                let speakers = inputLayout.channels.prefix(speakerCount)
                channelMap = HRIRChannelMap.interleavedPairs(speakers: Array(speakers))
                print("[HRIRManager] Auto-detected interleaved pair mapping for \(speakerCount) speakers")
            }

            // Build renderers for each input channel
            var newRenderers: [VirtualSpeakerRenderer] = []
            
            for (inputIndex, speaker) in inputLayout.channels.enumerated() {
                // Look up HRIR indices for this speaker
                guard let (leftEarIdx, rightEarIdx) = channelMap.getIndices(for: speaker) else {
                    print("[HRIRManager] Warning: No HRIR mapping for \(speaker.displayName), skipping")
                    continue
                }
                
                // Validate indices
                guard leftEarIdx < wavData.channelCount && rightEarIdx < wavData.channelCount else {
                    throw HRIRError.invalidChannelMapping(
                        "HRIR indices (\(leftEarIdx), \(rightEarIdx)) out of range for \(wavData.channelCount) channels"
                    )
                }
                
                // Get HRIR data
                let leftEarIR = wavData.audioData[leftEarIdx]
                let rightEarIR = wavData.audioData[rightEarIdx]
                
                // Debug: Calculate RMS energy to identify channel content
                func calculateRMS(_ samples: [Float]) -> Float {
                    var sum: Float = 0
                    vDSP_svesq(samples, 1, &sum, vDSP_Length(samples.count))
                    return sqrt(sum / Float(samples.count))
                }
                
                let leftRMS = calculateRMS(leftEarIR)
                let rightRMS = calculateRMS(rightEarIR)
                
                // Debug: Show first few samples and energy
                let samplePreview = min(8, leftEarIR.count)
                let leftPreview = leftEarIR.prefix(samplePreview).map { String(format: "%.3f", $0) }.joined(separator: ", ")
                let rightPreview = rightEarIR.prefix(samplePreview).map { String(format: "%.3f", $0) }.joined(separator: ", ")
                print("[HRIRManager]   HRIR[\(leftEarIdx)] RMS:\(String(format: "%.6f", leftRMS)) samples: [\(leftPreview)...]")
                print("[HRIRManager]   HRIR[\(rightEarIdx)] RMS:\(String(format: "%.6f", rightRMS)) samples: [\(rightPreview)...]")
                
                // Resample if needed
                let resampledLeft: [Float]
                let resampledRight: [Float]
                
                if abs(wavData.sampleRate - targetSampleRate) > 0.01 {
                    resampledLeft = Resampler.resampleHighQuality(
                        input: leftEarIR,
                        fromRate: wavData.sampleRate,
                        toRate: targetSampleRate
                    )
                    resampledRight = Resampler.resampleHighQuality(
                        input: rightEarIR,
                        fromRate: wavData.sampleRate,
                        toRate: targetSampleRate
                    )
                } else {
                    resampledLeft = leftEarIR
                    resampledRight = rightEarIR
                }
                
                // Create convolution engines
                guard let leftEngine = ConvolutionEngine(hrirSamples: resampledLeft, blockSize: processingBlockSize),
                      let rightEngine = ConvolutionEngine(hrirSamples: resampledRight, blockSize: processingBlockSize) else {
                    throw HRIRError.convolutionSetupFailed("Failed to create engines for \(speaker.displayName)")
                }
                
                let renderer = VirtualSpeakerRenderer(
                    speaker: speaker,
                    convolverLeftEar: leftEngine,
                    convolverRightEar: rightEngine
                )
                
                newRenderers.append(renderer)
                print("[HRIRManager] ✓ Input[\(inputIndex)] '\(speaker.displayName)' → HRIR L:\(leftEarIdx) R:\(rightEarIdx)")
            }
            
            guard !newRenderers.isEmpty else {
                throw HRIRError.convolutionSetupFailed("No valid renderers created")
            }

            // Activate
            renderers = newRenderers
            
            DispatchQueue.main.async {
                self.activePreset = preset
                self.currentInputLayout = inputLayout
                self.currentHRIRMap = channelMap
                self.errorMessage = nil
            }
            
            print("[HRIRManager] Successfully activated \(newRenderers.count) renderers")

        } catch {
            DispatchQueue.main.async {
                self.errorMessage = "Failed to activate preset: \(error.localizedDescription)"
            }
        }
    }

    /// Process multi-channel audio through convolution
    /// - Parameters:
    ///   - inputs: Array of input channel buffers
    ///   - leftOutput: Left ear output buffer
    ///   - rightOutput: Right ear output buffer
    ///   - frameCount: Number of frames to process
    func processAudio(
        inputs: [[Float]],
        leftOutput: inout [Float],
        rightOutput: inout [Float],
        frameCount: Int
    ) {
        guard convolutionEnabled, !renderers.isEmpty else {
            // Passthrough mode - mix all inputs to stereo
            for i in 0..<frameCount {
                leftOutput[i] = 0
                rightOutput[i] = 0
            }
            
            // Simple downmix: take first two channels if available
            if inputs.count >= 1 {
                for i in 0..<frameCount {
                    leftOutput[i] = inputs[0][i]
                }
            }
            if inputs.count >= 2 {
                for i in 0..<frameCount {
                    rightOutput[i] = inputs[1][i]
                }
            }
            return
        }

        // Process in chunks of processingBlockSize
        var offset = 0
        
        // Debug logging (once)
        struct ProcessLogger {
            static var hasLogged = false
        }
        if !ProcessLogger.hasLogged && !renderers.isEmpty {
            print("[HRIRManager] Processing \(inputs.count) input channels with \(renderers.count) renderers")
            for (i, renderer) in renderers.enumerated() {
                print("[HRIRManager]   Renderer[\(i)]: \(renderer.speaker.displayName)")
            }
            ProcessLogger.hasLogged = true
        }
        
        while offset + processingBlockSize <= frameCount {
            // Clear output accumulators for this block
            leftOutput.withUnsafeMutableBufferPointer { leftPtr in
                rightOutput.withUnsafeMutableBufferPointer { rightPtr in
                    guard let leftBase = leftPtr.baseAddress,
                          let rightBase = rightPtr.baseAddress else { return }
                    
                    let currentLeftOut = leftBase.advanced(by: offset)
                    let currentRightOut = rightBase.advanced(by: offset)
                    
                    // Zero the output for this block
                    memset(currentLeftOut, 0, processingBlockSize * MemoryLayout<Float>.size)
                    memset(currentRightOut, 0, processingBlockSize * MemoryLayout<Float>.size)
                    
                    // Accumulate contributions from each virtual speaker
                    for (channelIndex, renderer) in renderers.enumerated() {
                        guard channelIndex < inputs.count else { continue }
                        
                        inputs[channelIndex].withUnsafeBufferPointer { inputPtr in
                            guard let inputBase = inputPtr.baseAddress else { return }
                            let currentInput = inputBase.advanced(by: offset)
                            
                            // Convolve and accumulate to left ear
                            renderer.convolverLeftEar.processAndAccumulate(
                                input: currentInput,
                                outputAccumulator: currentLeftOut
                            )
                            
                            // Convolve and accumulate to right ear
                            renderer.convolverRightEar.processAndAccumulate(
                                input: currentInput,
                                outputAccumulator: currentRightOut
                            )
                        }
                    }
                }
            }
            
            offset += processingBlockSize
        }
        
        // Handle remaining frames (passthrough/simple mix)
        if offset < frameCount {
            for i in offset..<frameCount {
                leftOutput[i] = inputs.count >= 1 ? inputs[0][i] : 0
                rightOutput[i] = inputs.count >= 2 ? inputs[1][i] : 0
            }
        }
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
    case invalidChannelMapping(String)

    var errorDescription: String? {
        switch self {
        case .invalidChannelCount(let count):
            return "Invalid HRIR channel count: \(count). Must have at least 2 channels."
        case .emptyFile:
            return "HRIR file is empty"
        case .convolutionSetupFailed(let detail):
            return "Failed to set up convolution: \(detail)"
        case .invalidChannelMapping(let detail):
            return "Invalid channel mapping: \(detail)"
        }
    }
}
