//
//  ConvolutionEngine.swift
//  MacHRIR
//
//  Fast convolution using Accelerate framework's vDSP_conv
//

import Foundation
import Accelerate

/// Real-time convolution engine using Accelerate's optimized vDSP_conv
class ConvolutionEngine {

    // MARK: - Properties

    private let blockSize: Int
    private var hrir: [Float]
    private var overlapBuffer: [Float]
    private var convResult: [Float]  // Pre-allocated convolution result buffer
    private let hrirLength: Int
    private var debugCounter: Int = 0  // For first-run debugging

    // MARK: - Initialization

    /// Initialize convolution engine
    /// - Parameters:
    ///   - hrirSamples: Impulse response samples
    ///   - blockSize: Processing block size (typically 512)
    init?(hrirSamples: [Float], blockSize: Int = 512) {
        self.blockSize = blockSize
        self.hrir = hrirSamples
        self.hrirLength = hrirSamples.count

        // Allocate overlap buffer for tail from previous block
        self.overlapBuffer = [Float](repeating: 0, count: hrirLength - 1)

        // Pre-allocate convolution result buffer
        let resultLength = blockSize + hrirLength - 1
        self.convResult = [Float](repeating: 0, count: resultLength)

        print("[Convolution] Initialized with HRIR length: \(hrirLength), block size: \(blockSize)")
    }

    // MARK: - Public Methods

    /// Process a block of audio samples using fast convolution
    /// - Parameters:
    ///   - input: Input samples buffer
    ///   - output: Output buffer
    ///   - frameCount: Number of frames to process
    func process(input: [Float], output: inout [Float], frameCount: Int? = nil) {
        let framesToProcess = frameCount ?? blockSize

        guard framesToProcess == blockSize else {
            // Passthrough if size doesn't match
            for i in 0..<min(framesToProcess, min(input.count, output.count)) {
                output[i] = input[i]
            }
            return
        }

        guard input.count >= blockSize && output.count >= blockSize else {
            return
        }

        // Clear convolution result buffer
        for i in 0..<convResult.count {
            convResult[i] = 0
        }

        // Debug: Log input values on first run
        if debugCounter < 2 {
            var inputMax: Float = 0
            for i in 0..<min(10, blockSize) {
                inputMax = max(inputMax, abs(input[i]))
            }
            print("[Convolution] Input max (first 10): \(inputMax)")

            var hrirMax: Float = 0
            for i in 0..<min(10, hrirLength) {
                hrirMax = max(hrirMax, abs(hrir[i]))
            }
            print("[Convolution] HRIR max (first 10): \(hrirMax)")
        }

        // Perform convolution using Accelerate
        // vDSP_conv convolves input signal with HRIR kernel
        vDSP_conv(
            input, 1,           // Input signal
            hrir, 1,            // HRIR kernel (impulse response)
            &convResult, 1,     // Output
            vDSP_Length(blockSize),     // Length of input
            vDSP_Length(hrirLength)     // Length of kernel
        )

        // Check for invalid values and debug output
        var hasInvalid = false
        var maxOutput: Float = 0
        for i in 0..<convResult.count {
            if convResult[i].isNaN || convResult[i].isInfinite {
                hasInvalid = true
                break
            }
            maxOutput = max(maxOutput, abs(convResult[i]))
        }

        if debugCounter < 2 {
            print("[Convolution] Convolution result max: \(maxOutput), count: \(convResult.count)")
            debugCounter += 1
        }

        if hasInvalid {
            print("[Convolution] WARNING: Invalid values detected in convolution result!")
            // Passthrough if we got invalid values
            for i in 0..<blockSize {
                output[i] = input[i]
            }
            return
        }

        // Overlap-add: Add the tail from previous block
        for i in 0..<min(overlapBuffer.count, blockSize) {
            convResult[i] += overlapBuffer[i]
        }

        // Copy output samples
        for i in 0..<blockSize {
            output[i] = convResult[i]
        }

        // Save overlap (tail) for next block
        let tailStart = blockSize
        for i in 0..<overlapBuffer.count {
            if tailStart + i < convResult.count {
                overlapBuffer[i] = convResult[tailStart + i]
            } else {
                overlapBuffer[i] = 0
            }
        }
    }

    /// Reset the engine state
    func reset() {
        overlapBuffer = [Float](repeating: 0, count: hrirLength - 1)
        for i in 0..<convResult.count {
            convResult[i] = 0
        }
    }
}

