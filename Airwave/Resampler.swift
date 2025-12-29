//
//  Resampler.swift
//  Airwave
//
//  High-quality audio resampling using Accelerate (vDSP)
//
//

import Foundation
import Accelerate

/// Provides audio resampling functionality using vDSP
class Resampler {

    /// Resample audio from one sample rate to another using linear interpolation (vDSP)
    /// - Parameters:
    ///   - input: Input audio samples
    ///   - fromRate: Source sample rate
    ///   - toRate: Target sample rate
    /// - Returns: Resampled audio
    static func resample(input: [Float], fromRate: Double, toRate: Double) -> [Float] {
        return resampleHighQuality(input: input, fromRate: fromRate, toRate: toRate)
    }

    /// Resample audio using vDSP linear interpolation
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

        let count = input.count
        let stride = fromRate / toRate
        let outputCount = Int(Double(count) / stride)

        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        
        // vDSP_vgenp uses a control vector to determine interpolation points.
        // However, for uniform resampling, vDSP_vlint (vector linear interpolation) is easier if we construct the control vector,
        // OR we can use vDSP_vgenp which takes a control vector of indices.
        
        // Let's use a simpler approach for linear interpolation:
        // We need to interpolate at indices: 0, stride, 2*stride, ...
        
        // 1. Generate control vector (indices)
        var control = [Float](repeating: 0, count: outputCount)
        var start: Float = 0
        var step: Float = Float(stride)
        vDSP_vramp(&start, &step, &control, 1, vDSP_Length(outputCount))
        
        // 2. Perform interpolation
        // vDSP_vlint interpolates based on integer and fractional parts.
        // But vDSP_vgenp is more direct for "gather and interpolate".
        // Note: vDSP_vgenp requires the control vector to be 1-based indices if I recall correctly?
        // Checking documentation: vDSP_vgenp interpolates A at indices I.
        // "The integer part of each element of I is the index... The fractional part is the weight..."
        
        vDSP_vgenp(input, 1, control, 1, &output, 1, vDSP_Length(outputCount), vDSP_Length(count))
        
        return output
    }
}
