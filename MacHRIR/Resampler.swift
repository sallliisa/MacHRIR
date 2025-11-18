//
//  Resampler.swift
//  MacHRIR
//
//  High-quality audio resampling for HRIR sample rate conversion
//

import Foundation
import Accelerate

/// Provides audio resampling functionality
class Resampler {

    /// Resample audio from one sample rate to another using linear interpolation
    /// - Parameters:
    ///   - input: Input audio samples
    ///   - fromRate: Source sample rate
    ///   - toRate: Target sample rate
    /// - Returns: Resampled audio
    static func resample(input: [Float], fromRate: Double, toRate: Double) -> [Float] {
        // If sample rates match, return input as-is
        if abs(fromRate - toRate) < 0.01 {
            return input
        }

        let ratio = toRate / fromRate
        let outputLength = Int(Double(input.count) * ratio)

        guard outputLength > 0 else {
            return []
        }

        var output = [Float](repeating: 0, count: outputLength)

        // Linear interpolation resampling
        for i in 0..<outputLength {
            let inputPos = Double(i) / ratio
            let index = Int(inputPos)
            let fraction = Float(inputPos - Double(index))

            if index + 1 < input.count {
                // Interpolate between samples
                let sample1 = input[index]
                let sample2 = input[index + 1]
                output[i] = sample1 + (sample2 - sample1) * fraction
            } else if index < input.count {
                // Last sample, no interpolation
                output[i] = input[index]
            }
        }

        return output
    }

    /// Resample audio using high-quality sinc interpolation (slower but better quality)
    /// - Parameters:
    ///   - input: Input audio samples
    ///   - fromRate: Source sample rate
    ///   - toRate: Target sample rate
    /// - Returns: Resampled audio
    static func resampleHighQuality(input: [Float], fromRate: Double, toRate: Double) -> [Float] {
        // If sample rates match, return input as-is
        if abs(fromRate - toRate) < 0.01 {
            return input
        }

        let ratio = toRate / fromRate
        let outputLength = Int(Double(input.count) * ratio)

        guard outputLength > 0 else {
            return []
        }

        var output = [Float](repeating: 0, count: outputLength)

        // Sinc interpolation parameters
        let sincRadius = 8  // Number of samples to consider on each side

        for i in 0..<outputLength {
            let inputPos = Double(i) / ratio
            let centerIndex = Int(inputPos)

            var sum: Float = 0.0
            var weightSum: Float = 0.0

            // Sinc interpolation kernel
            for j in -sincRadius...sincRadius {
                let sampleIndex = centerIndex + j

                if sampleIndex >= 0 && sampleIndex < input.count {
                    let x = inputPos - Double(sampleIndex)
                    let weight = sinc(x)
                    sum += input[sampleIndex] * weight
                    weightSum += weight
                }
            }

            // Normalize
            if weightSum > 0 {
                output[i] = sum / weightSum
            }
        }

        return output
    }

    /// Sinc function for high-quality interpolation
    private static func sinc(_ x: Double) -> Float {
        if abs(x) < 1e-6 {
            return 1.0
        }

        let piX = Double.pi * x
        return Float(sin(piX) / piX)
    }
}
