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
import AppKit

/// Manages HRIR presets and multi-channel convolution processing
class HRIRManager: ObservableObject {

    // MARK: - Published Properties

    @Published var presets: [HRIRPreset] = []
    @Published var activePreset: HRIRPreset?
    @Published var convolutionEnabled: Bool = false {
        didSet {
            isConvolutionActive = convolutionEnabled
        }
    }
    
    // Mirrored property for fast access in audio thread (avoids @Published overhead)
    public var isConvolutionActive: Bool = false
    @Published var errorMessage: String?
    @Published var currentInputLayout: InputLayout = .stereo
    @Published var currentHRIRMap: HRIRChannelMap?
    
    // MARK: - Private Properties
    
    // Multi-channel rendering: one renderer per input channel
    // Protected by a concurrent queue for thread-safe access
    // Immutable state container for lock-free access
    class RendererState {
        let renderers: [VirtualSpeakerRenderer]
        
        init(renderers: [VirtualSpeakerRenderer]) {
            self.renderers = renderers
        }
    }
    
    // Atomic reference to current state
    private var rendererState: RendererState?
    
    private let processingBlockSize: Int = 512  // Balance between latency (~10.7ms @ 48kHz) and CPU efficiency

    private let presetsDirectory: URL
    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryDebounceTask: DispatchWorkItem?

    // MARK: - Initialization

    init() {
        // Set up presets directory
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        presetsDirectory = appSupport.appendingPathComponent("MacHRIR/presets", isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: presetsDirectory, withIntermediateDirectories: true)

        // Load existing presets and sync with directory
        loadAndSyncPresets()
        
        // Start watching for changes
        startDirectoryWatcher()
    }
    
    deinit {
        directorySource?.cancel()
    }

    // MARK: - Public Methods

    /// Opens the presets directory in Finder
    func openPresetsDirectory() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: presetsDirectory.path)
    }

    /// Remove a preset
    /// - Parameter preset: The preset to remove
    func removePreset(_ preset: HRIRPreset) {
        // Remove file
        try? FileManager.default.removeItem(at: preset.fileURL)
        // The directory watcher will handle the update, but we can update immediately for responsiveness
        // However, to avoid race conditions with the watcher, it's often safer to let the watcher handle it,
        // or update local state and let the watcher confirm.
        // For simplicity and responsiveness, we'll update local state and let sync handle any discrepancies.
        
        presets.removeAll { $0.id == preset.id }

        // Clear active preset if it was removed
        if activePreset?.id == preset.id {
            activePreset = nil
            activePreset = nil
            self.rendererState = nil
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
        // Perform loading and processing on a background queue
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            do {
                // Load WAV file
                let wavData = try WAVLoader.load(from: preset.fileURL)

                // Determine HRIR mapping
                let speakers = inputLayout.channels
                let channelMap: HRIRChannelMap
                
                if wavData.channelCount == 7 {
                    channelMap = HRIRChannelMap.hesuvi7Channel(speakers: Array(speakers))
                } else {
                    // Default to HeSuVi 14-channel mapping
                    channelMap = HRIRChannelMap.hesuvi14Channel(speakers: Array(speakers))
                }

                // Build renderers for each input channel
                var newRenderers: [VirtualSpeakerRenderer] = []
                
                for (_, speaker) in inputLayout.channels.enumerated() {
                    // Look up HRIR indices for this speaker
                    guard let (leftEarIdx, rightEarIdx) = channelMap.getIndices(for: speaker) else {
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
                    
                    // Create convolution engines with shared FFTSetup for memory efficiency
                    let blockSize = self.processingBlockSize
                    let log2n = vDSP_Length(log2(Double(blockSize * 2)))
                    let sharedSetup = FFTSetupManager.shared.getSetup(log2n: log2n)
                    
                    guard let leftEngine = ConvolutionEngine(hrirSamples: resampledLeft, blockSize: blockSize, sharedFFTSetup: sharedSetup),
                          let rightEngine = ConvolutionEngine(hrirSamples: resampledRight, blockSize: blockSize, sharedFFTSetup: sharedSetup) else {
                        throw HRIRError.convolutionSetupFailed("Failed to create engines for \(speaker.displayName)")
                    }
                    
                    let renderer = VirtualSpeakerRenderer(
                        speaker: speaker,
                        convolverLeftEar: leftEngine,
                        convolverRightEar: rightEngine
                    )
                    
                    newRenderers.append(renderer)
                }
                
                guard !newRenderers.isEmpty else {
                    throw HRIRError.convolutionSetupFailed("No valid renderers created")
                }

                // Activate safely
                // Activate safely (atomic reference swap)
                let newState = RendererState(renderers: newRenderers)
                self.rendererState = newState
                
                DispatchQueue.main.async {
                    self.activePreset = preset
                    self.currentInputLayout = inputLayout
                    self.currentHRIRMap = channelMap
                    self.errorMessage = nil
                }

            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to activate preset: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Process multi-channel audio through convolution (zero-allocation version)
    /// - Parameters:
    ///   - inputPtrs: Array of pointers to input channel buffers
    ///   - inputCount: Number of input channels to process
    ///   - leftOutput: Pointer to left ear output buffer
    ///   - rightOutput: Pointer to right ear output buffer
    ///   - frameCount: Number of frames to process
    func processAudio(
        inputPtrs: UnsafeMutablePointer<UnsafeMutablePointer<Float>>,
        inputCount: Int,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        // Capture current state atomically (retain)
        guard let state = self.rendererState, !state.renderers.isEmpty else {
            // Passthrough mode - simple copy
            if inputCount >= 1 {
                memcpy(leftOutput, inputPtrs[0], frameCount * MemoryLayout<Float>.size)
            } else {
                memset(leftOutput, 0, frameCount * MemoryLayout<Float>.size)
            }
            
            if inputCount >= 2 {
                memcpy(rightOutput, inputPtrs[1], frameCount * MemoryLayout<Float>.size)
            } else if inputCount >= 1 {
                memcpy(rightOutput, inputPtrs[0], frameCount * MemoryLayout<Float>.size)
            } else {
                memset(rightOutput, 0, frameCount * MemoryLayout<Float>.size)
            }
            return
        }

        // Process in chunks of processingBlockSize
        var offset = 0
        
        while offset + processingBlockSize <= frameCount {
            let currentLeftOut = leftOutput.advanced(by: offset)
            let currentRightOut = rightOutput.advanced(by: offset)
            
            // Zero the output for this block
            memset(currentLeftOut, 0, processingBlockSize * MemoryLayout<Float>.size)
            memset(currentRightOut, 0, processingBlockSize * MemoryLayout<Float>.size)
            
            // Accumulate contributions from each virtual speaker
            for (channelIndex, renderer) in state.renderers.enumerated() {
                guard channelIndex < inputCount else { continue }
                
                let currentInput = inputPtrs[channelIndex].advanced(by: offset)
                
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
            
            offset += processingBlockSize
        }
    }


    // MARK: - Private Methods

    private func startDirectoryWatcher() {
        let fileDescriptor = open(presetsDirectory.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )
        
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            // Cancel any pending reload
            self.directoryDebounceTask?.cancel()
            
            // Schedule new reload with debouncing
            let task = DispatchWorkItem { [weak self] in
                self?.loadAndSyncPresets()
            }
            self.directoryDebounceTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: task)
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
        directorySource = source
    }

    private func loadAndSyncPresets() {
        // 1. Load known presets from JSON
        var knownPresets: [HRIRPreset] = []
        let metadataURL = presetsDirectory.appendingPathComponent("presets.json")
        
        if let data = try? Data(contentsOf: metadataURL),
           let decoded = try? JSONDecoder().decode([HRIRPreset].self, from: data) {
            knownPresets = decoded
        }
        
        // 2. Scan directory for WAV files
        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: presetsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        
        let wavFiles = fileURLs.filter { $0.pathExtension.lowercased() == "wav" }
        
        var updatedPresets: [HRIRPreset] = []
        var hasChanges = false
        
        // 3. Reconcile
        for fileURL in wavFiles {
            // Check if we already have this file
            if let existing = knownPresets.first(where: { $0.fileURL.lastPathComponent == fileURL.lastPathComponent }) {
                // Update path in case it moved (though unlikely if filename matches)
                // But mostly just keep it
                let updated = HRIRPreset(
                    id: existing.id,
                    name: existing.name,
                    fileURL: fileURL,
                    channelCount: existing.channelCount,
                    sampleRate: existing.sampleRate
                )
                updatedPresets.append(updated)
            } else {
                // New file found!
                if let newPreset = try? createPreset(from: fileURL) {
                    updatedPresets.append(newPreset)
                    hasChanges = true
                }
            }
        }
        
        // Check if any were removed
        if updatedPresets.count != knownPresets.count {
            hasChanges = true
        }
        
        // 4. Update State
        DispatchQueue.main.async {
            if hasChanges || self.presets != updatedPresets {
                self.presets = updatedPresets
                self.savePresets()
            }
            
            // Check if active preset is still valid
            if let active = self.activePreset, !updatedPresets.contains(where: { $0.id == active.id }) {
                self.activePreset = nil
                self.activePreset = nil
                self.rendererState = nil
            }
        }
    }
    
    private func createPreset(from fileURL: URL) throws -> HRIRPreset {
        let wavData = try WAVLoader.load(from: fileURL)
        
        return HRIRPreset(
            id: UUID(),
            name: fileURL.deletingPathExtension().lastPathComponent,
            fileURL: fileURL,
            channelCount: wavData.channelCount,
            sampleRate: wavData.sampleRate
        )
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
    case batchImportFailed(String)

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
        case .batchImportFailed(let detail):
            return "Batch import failed: \(detail)"
        }
    }
}
