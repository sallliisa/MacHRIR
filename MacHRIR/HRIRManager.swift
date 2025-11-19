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

    // Automatic spatial asymmetry compensation (computed from HRIR analysis)
    private var autoLeftGain: Float = 1.0
    private var autoRightGain: Float = 1.0

    // Manual balance adjustment (from UI slider)
    private var manualLeftGain: Float = 1.0
    private var manualRightGain: Float = 1.0

    // Spatial asymmetry compensation
    // Stores the FL and FR ILD values to compute compensation
    private var flILD: Float = 0.0
    private var frILD: Float = 0.0
    @Published var spatialCompensationEnabled: Bool = true {
        didSet {
            if !spatialCompensationEnabled {
                // Disable compensation by resetting auto gains to 1.0
                autoLeftGain = 1.0
                autoRightGain = 1.0
                print("[HRIRManager] Spatial compensation disabled - auto gains reset to 1.0")
            } else if flILD != 0.0 && frILD != 0.0 {
                // Re-apply compensation
                recomputeSpatialCompensation()
            }
        }
    }

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

        // Note: Balance compensation is now computed automatically based on HRIR ILD analysis
        // when a preset is activated. The balance slider can still be used for manual adjustment.

        // Load existing presets
        loadPresets()
    }

    // MARK: - Public Methods

    /// Set the manual stereo balance adjustment
    /// - Parameter balance: Balance adjustment from -1.0 (boost left) to +1.0 (boost right)
    ///   0.0 = no manual adjustment, -0.1 = slightly boost left, +0.1 = slightly boost right
    /// Note: This adjustment is ADDED to the automatic ILD compensation
    func setBalance(_ balance: Float) {
        let clampedBalance = max(-1.0, min(1.0, balance))

        if clampedBalance < 0 {
            // Boost left, attenuate right
            manualLeftGain = 1.0 + abs(clampedBalance) * 0.15  // Up to +15% boost
            manualRightGain = 1.0 - abs(clampedBalance) * 0.15  // Up to -15% attenuation
        } else if clampedBalance > 0 {
            // Boost right, attenuate left
            manualLeftGain = 1.0 - clampedBalance * 0.15
            manualRightGain = 1.0 + clampedBalance * 0.15
        } else {
            manualLeftGain = 1.0
            manualRightGain = 1.0
        }

        let totalLeftGain = autoLeftGain * manualLeftGain
        let totalRightGain = autoRightGain * manualRightGain

        print(String(format: "[HRIRManager] Manual balance: %.2f → Manual L: %.3f R: %.3f, Total L: %.3f R: %.3f",
                     clampedBalance, manualLeftGain, manualRightGain, totalLeftGain, totalRightGain))
    }

    /// Recompute spatial compensation based on stored ILD values
    private func recomputeSpatialCompensation() {
        guard spatialCompensationEnabled else { return }

        let ildAsymmetry = abs(frILD) - abs(flILD)
        let compensationAmount = ildAsymmetry * 0.9  // 90% aggressive

        let gainRatio = pow(10.0, compensationAmount / 20.0)
        autoLeftGain = Float(sqrt(gainRatio))
        autoRightGain = Float(1.0 / sqrt(gainRatio))

        print(String(format: "[HRIRManager] Spatial compensation re-enabled: %.2f dB → L: %.3f, R: %.3f",
                     compensationAmount, autoLeftGain, autoRightGain))
    }

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

                // Calculate centroid (center of energy) to detect ITD
                var weightedSum: Float = 0
                var totalEnergy: Float = 0
                for (sampleIdx, sample) in channelData.enumerated() {
                    let energy = sample * sample
                    weightedSum += Float(sampleIdx) * energy
                    totalEnergy += energy
                }
                let centroid = totalEnergy > 0 ? weightedSum / totalEnergy : 0
                let centroidMs = (centroid / Float(wavData.sampleRate)) * 1000.0

                print("[HRIRManager]   Ch[\(idx)]: RMS=\(String(format: "%.6f", rms)) Peak=\(String(format: "%.6f", peak)) Centroid=\(String(format: "%.2fms", centroidMs))")
            }
            print("[HRIRManager] ================================")

            // Analyze FL vs FR spatial symmetry for stereo
            if wavData.audioData.count >= 4 {
                print("[HRIRManager] === Spatial Symmetry Analysis (FL vs FR) ===")

                // FL: Ch0=L ear, Ch1=R ear (assuming no swap)
                // FR: Ch2=?, Ch3=? (need to determine)
                let fl_L = wavData.audioData[0]
                let fl_R = wavData.audioData[1]
                let fr_0 = wavData.audioData[2]
                let fr_1 = wavData.audioData[3]

                // Calculate ILD (Interaural Level Difference) for FL
                let fl_L_rms = calculateRMS(fl_L)
                let fl_R_rms = calculateRMS(fl_R)
                let fl_ILD_dB = 20 * log10(fl_L_rms / max(fl_R_rms, 0.000001))

                // Calculate ILD for FR (both possible mappings)
                let fr_0_rms = calculateRMS(fr_0)
                let fr_1_rms = calculateRMS(fr_1)
                let fr_ILD_dB_noSwap = 20 * log10(fr_0_rms / max(fr_1_rms, 0.000001))
                let fr_ILD_dB_swap = 20 * log10(fr_1_rms / max(fr_0_rms, 0.000001))

                print("[HRIRManager]   FL ILD: \(String(format: "%.2f dB", fl_ILD_dB)) (L ear \(fl_L_rms > fl_R_rms ? "louder" : "quieter"))")
                print("[HRIRManager]   FR ILD (no swap): \(String(format: "%.2f dB", fr_ILD_dB_noSwap))")
                print("[HRIRManager]   FR ILD (swapped): \(String(format: "%.2f dB", fr_ILD_dB_swap)) (R ear \(fr_0_rms > fr_1_rms ? "louder" : "quieter"))")
                print("[HRIRManager]   Expected symmetric ILD: \(String(format: "%.2f dB", -fl_ILD_dB)) (mirror of FL)")

                // Check which mapping gives better symmetry
                let symmetryError_noSwap = abs(fl_ILD_dB + fr_ILD_dB_noSwap)
                let symmetryError_swap = abs(fl_ILD_dB + fr_ILD_dB_swap)

                print("[HRIRManager]   Symmetry error (no swap): \(String(format: "%.2f dB", symmetryError_noSwap))")
                print("[HRIRManager]   Symmetry error (swapped): \(String(format: "%.2f dB", symmetryError_swap))")
                print("[HRIRManager]   Recommendation: \(symmetryError_swap < symmetryError_noSwap ? "USE SWAP" : "NO SWAP")")

                // Store ILD values for compensation
                flILD = fl_ILD_dB
                frILD = symmetryError_swap < symmetryError_noSwap ? fr_ILD_dB_swap : fr_ILD_dB_noSwap

                // Calculate automatic balance compensation for stereo
                if inputLayout.channels.count == 2 && spatialCompensationEnabled {
                    // The asymmetry in ILD magnitude causes asymmetric spatial perception
                    // If |FR_ILD| > |FL_ILD|, then FR sounds more lateral (wider)
                    // Compensate by adjusting L/R gains to equalize perceived width
                    let ildAsymmetry = abs(frILD) - abs(flILD)

                    // Aggressive compensation: 90% of the asymmetry
                    // Increased from 50% to address persistent spatial width difference
                    let compensationAmount = ildAsymmetry * 0.9  // dB to compensate

                    // Convert dB difference to linear gain ratio
                    // If FR is wider (higher ILD), reduce right ear output
                    let gainRatio = pow(10.0, compensationAmount / 20.0)

                    // Apply automatic gains while preserving total energy
                    autoLeftGain = Float(sqrt(gainRatio))
                    autoRightGain = Float(1.0 / sqrt(gainRatio))

                    print("[HRIRManager]   ILD Asymmetry: \(String(format: "%.2f dB", ildAsymmetry)) (FR \(abs(frILD) > abs(flILD) ? "wider" : "narrower") than FL)")
                    print("[HRIRManager]   Auto Compensation: \(String(format: "%.2f dB", compensationAmount)) (90% aggressive) → L: \(String(format: "%.3f", autoLeftGain)), R: \(String(format: "%.3f", autoRightGain))")
                    print("[HRIRManager]   Result: Effective compensation = \(String(format: "%.2f dB", 20 * log10(Double(autoLeftGain / autoRightGain))))")
                }

                print("[HRIRManager] ===============================================")
            }

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

                // Verify HRIR symmetry for stereo channels
                if inputLayout.channels.count == 2 {
                    let leftHRIR_RMS = calculateRMS(resampledLeft)
                    let rightHRIR_RMS = calculateRMS(resampledRight)
                    let hrirILD = 20 * log10(leftHRIR_RMS / max(rightHRIR_RMS, 0.000001))
                    print("[HRIRManager]     Convolver for '\(speaker.displayName)': L_HRIR RMS=\(String(format: "%.6f", leftHRIR_RMS)), R_HRIR RMS=\(String(format: "%.6f", rightHRIR_RMS)), ILD=\(String(format: "%.2f dB", hrirILD))")
                }
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

            // Diagnostic: Test convolution symmetry with impulse response
            if newRenderers.count == 2 && inputLayout.channels.count == 2 {
                print("[HRIRManager] === Convolution Symmetry Test ===")

                // Reset convolvers to clear FDL
                newRenderers[0].convolverLeftEar.reset()
                newRenderers[0].convolverRightEar.reset()
                newRenderers[1].convolverLeftEar.reset()
                newRenderers[1].convolverRightEar.reset()

                // Create test impulse: single spike at beginning
                var testImpulse = [Float](repeating: 0.0, count: processingBlockSize)
                testImpulse[0] = 1.0

                var silenceBlock = [Float](repeating: 0.0, count: processingBlockSize)

                // Need to process partitionCount blocks to fill the FDL completely
                // Process blocks alternating input and silence to see the full IR
                let numBlocks = 29 // Match partition count from diagnostic
                var flLeftAccum = [Float](repeating: 0.0, count: processingBlockSize * numBlocks)
                var flRightAccum = [Float](repeating: 0.0, count: processingBlockSize * numBlocks)
                var frLeftAccum = [Float](repeating: 0.0, count: processingBlockSize * numBlocks)
                var frRightAccum = [Float](repeating: 0.0, count: processingBlockSize * numBlocks)

                for blockIdx in 0..<numBlocks {
                    let inputBlock = (blockIdx == 0) ? testImpulse : silenceBlock

                    var flLeftOut = [Float](repeating: 0.0, count: processingBlockSize)
                    var flRightOut = [Float](repeating: 0.0, count: processingBlockSize)
                    var frLeftOut = [Float](repeating: 0.0, count: processingBlockSize)
                    var frRightOut = [Float](repeating: 0.0, count: processingBlockSize)

                    // Process through FL convolver
                    inputBlock.withUnsafeBufferPointer { inPtr in
                        guard let inBase = inPtr.baseAddress else { return }
                        flLeftOut.withUnsafeMutableBufferPointer { leftPtr in
                            guard let leftBase = leftPtr.baseAddress else { return }
                            newRenderers[0].convolverLeftEar.process(input: inBase, output: leftBase)
                        }
                        flRightOut.withUnsafeMutableBufferPointer { rightPtr in
                            guard let rightBase = rightPtr.baseAddress else { return }
                            newRenderers[0].convolverRightEar.process(input: inBase, output: rightBase)
                        }
                    }

                    // Process through FR convolver
                    inputBlock.withUnsafeBufferPointer { inPtr in
                        guard let inBase = inPtr.baseAddress else { return }
                        frLeftOut.withUnsafeMutableBufferPointer { leftPtr in
                            guard let leftBase = leftPtr.baseAddress else { return }
                            newRenderers[1].convolverLeftEar.process(input: inBase, output: leftBase)
                        }
                        frRightOut.withUnsafeMutableBufferPointer { rightPtr in
                            guard let rightBase = rightPtr.baseAddress else { return }
                            newRenderers[1].convolverRightEar.process(input: inBase, output: rightBase)
                        }
                    }

                    // Accumulate outputs
                    let offset = blockIdx * processingBlockSize
                    for i in 0..<processingBlockSize {
                        flLeftAccum[offset + i] = flLeftOut[i]
                        flRightAccum[offset + i] = flRightOut[i]
                        frLeftAccum[offset + i] = frLeftOut[i]
                        frRightAccum[offset + i] = frRightOut[i]
                    }
                }

                // Calculate RMS of accumulated outputs
                var flLeftRMS: Float = 0, flRightRMS: Float = 0
                var frLeftRMS: Float = 0, frRightRMS: Float = 0
                vDSP_rmsqv(flLeftAccum, 1, &flLeftRMS, vDSP_Length(processingBlockSize * numBlocks))
                vDSP_rmsqv(flRightAccum, 1, &flRightRMS, vDSP_Length(processingBlockSize * numBlocks))
                vDSP_rmsqv(frLeftAccum, 1, &frLeftRMS, vDSP_Length(processingBlockSize * numBlocks))
                vDSP_rmsqv(frRightAccum, 1, &frRightRMS, vDSP_Length(processingBlockSize * numBlocks))

                let flILDtest = 20 * log10(flLeftRMS / max(flRightRMS, 0.000001))
                let frILDtest = 20 * log10(frRightRMS / max(frLeftRMS, 0.000001))

                print("[HRIRManager]   FL convolution output: L=\(String(format: "%.6f", flLeftRMS)) R=\(String(format: "%.6f", flRightRMS)) ILD=\(String(format: "%.2f dB", flILDtest))")
                print("[HRIRManager]   FR convolution output: L=\(String(format: "%.6f", frLeftRMS)) R=\(String(format: "%.6f", frRightRMS)) ILD=\(String(format: "%.2f dB", frILDtest))")

                let flError = abs(flILDtest - flILD)
                let frError = abs(frILDtest - abs(frILD))
                print("[HRIRManager]   ILD Error: FL=\(String(format: "%.2f dB", flError)) FR=\(String(format: "%.2f dB", frError))")
                print("[HRIRManager]   Convolution is working correctly: \(flError < 1.0 && frError < 1.0 ? "YES ✓" : "NO ✗ (MISMATCH!)")")
                print("[HRIRManager] ========================================")
            }

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
            static var callCount: Int = 0
            static var leftRMSSum: Float = 0
            static var rightRMSSum: Float = 0
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

        // Apply balance compensation gains (automatic + manual)
        let totalLeftGain = autoLeftGain * manualLeftGain
        let totalRightGain = autoRightGain * manualRightGain

        if totalLeftGain != 1.0 {
            vDSP_vsmul(leftOutput, 1, [totalLeftGain], &leftOutput, 1, vDSP_Length(frameCount))
        }
        if totalRightGain != 1.0 {
            vDSP_vsmul(rightOutput, 1, [totalRightGain], &rightOutput, 1, vDSP_Length(frameCount))
        }

        // Periodic RMS level monitoring to detect left/right imbalance
        ProcessLogger.callCount += 1
        if ProcessLogger.callCount % 100 == 0 {
            // Calculate RMS for left and right outputs (after gain compensation)
            var leftRMS: Float = 0
            var rightRMS: Float = 0
            vDSP_rmsqv(leftOutput, 1, &leftRMS, vDSP_Length(frameCount))
            vDSP_rmsqv(rightOutput, 1, &rightRMS, vDSP_Length(frameCount))

            ProcessLogger.leftRMSSum += leftRMS
            ProcessLogger.rightRMSSum += rightRMS

            let leftAvg = ProcessLogger.leftRMSSum / Float(ProcessLogger.callCount / 100)
            let rightAvg = ProcessLogger.rightRMSSum / Float(ProcessLogger.callCount / 100)
            let balance = leftAvg / max(rightAvg, 0.0001) // Avoid division by zero

            let totalLeft = autoLeftGain * manualLeftGain
            let totalRight = autoRightGain * manualRightGain

            print(String(format: "[HRIRManager] Output - L:%.6f R:%.6f Ratio:%.4f | Gains: Auto(L:%.3f R:%.3f) Manual(L:%.3f R:%.3f) Total(L:%.3f R:%.3f)",
                         leftAvg, rightAvg, balance, autoLeftGain, autoRightGain, manualLeftGain, manualRightGain, totalLeft, totalRight))
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
