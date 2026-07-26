//
//  ConvolutionEngine.swift
//  Airwave
//
//  Uniform Partitioned Convolution using Accelerate framework
//  Implements the Uniform Partitioned Overlap-Save (UPOLS) algorithm
//  to efficiently handle long HRIR filters with zero added latency.
//

import Foundation
import Accelerate

/// Real-time partitioned convolution of one input channel against a pair of
/// ear impulse responses.
///
/// Both ears see the same input, so the forward FFT and the frequency delay
/// line (FDL) are computed once per block and shared: only the partitioned
/// multiply-accumulate and the inverse FFT run per ear.
nonisolated final class StereoConvolutionEngine {

    // MARK: - Properties

    private let log2n: vDSP_Length
    private let fftSize: Int
    private let fftSizeHalf: Int
    private let blockSize: Int
    private let partitionCount: Int

    private let fftSetup: FFTSetup
    private let ownsFFTSetup: Bool

    // Input buffering (overlap-save)
    private let inputBuffer: UnsafeMutablePointer<Float>
    private let inputOverlapBuffer: UnsafeMutablePointer<Float>
    private let outputScratch: UnsafeMutablePointer<Float>

    // Frequency delay line, shared by both ears. Contiguous flat buffers.
    private let fdlRealData: UnsafeMutablePointer<Float>
    private let fdlImagData: UnsafeMutablePointer<Float>
    private var fdlIndex = 0

    // HRIR partitions (frequency domain), one set per ear.
    private let leftRealData: UnsafeMutablePointer<Float>
    private let leftImagData: UnsafeMutablePointer<Float>
    private let rightRealData: UnsafeMutablePointer<Float>
    private let rightImagData: UnsafeMutablePointer<Float>

    // Processing buffers
    private let accumulatorReal: UnsafeMutablePointer<Float>
    private let accumulatorImag: UnsafeMutablePointer<Float>
    private var accumulator: DSPSplitComplex

    private let tempMulReal: UnsafeMutablePointer<Float>
    private let tempMulImag: UnsafeMutablePointer<Float>

    // MARK: - Initialization

    /// - Parameters:
    ///   - leftEarHRIR: impulse response for the left ear
    ///   - rightEarHRIR: impulse response for the right ear
    ///   - blockSize: processing block size (FFT size is twice this)
    ///   - sharedFFTSetup: shared setup; one is created privately when nil
    init?(
        leftEarHRIR: [Float],
        rightEarHRIR: [Float],
        blockSize: Int = 512,
        sharedFFTSetup: FFTSetup? = nil
    ) {
        guard blockSize > 0, !leftEarHRIR.isEmpty || !rightEarHRIR.isEmpty else { return nil }

        self.blockSize = blockSize
        self.fftSize = blockSize * 2
        self.fftSizeHalf = fftSize / 2
        self.log2n = vDSP_Length(log2(Double(fftSize)))

        if let sharedFFTSetup {
            self.fftSetup = sharedFFTSetup
            self.ownsFFTSetup = false
        } else {
            guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
                Logger.log("[Convolution] Failed to create FFT setup")
                return nil
            }
            self.fftSetup = setup
            self.ownsFFTSetup = true
        }

        // Both ears share one partition count; the shorter response is zero-padded.
        let longestTapCount = max(leftEarHRIR.count, rightEarHRIR.count)
        self.partitionCount = Int(ceil(Double(longestTapCount) / Double(blockSize)))

        inputBuffer = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        inputBuffer.initialize(repeating: 0, count: fftSize)
        inputOverlapBuffer = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        inputOverlapBuffer.initialize(repeating: 0, count: blockSize)
        outputScratch = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        outputScratch.initialize(repeating: 0, count: fftSize)

        accumulatorReal = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        accumulatorImag = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        accumulatorReal.initialize(repeating: 0, count: fftSizeHalf)
        accumulatorImag.initialize(repeating: 0, count: fftSizeHalf)
        accumulator = DSPSplitComplex(realp: accumulatorReal, imagp: accumulatorImag)

        tempMulReal = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        tempMulImag = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        tempMulReal.initialize(repeating: 0, count: fftSizeHalf)
        tempMulImag.initialize(repeating: 0, count: fftSizeHalf)

        let partitionedSize = partitionCount * fftSizeHalf
        fdlRealData = UnsafeMutablePointer<Float>.allocate(capacity: partitionedSize)
        fdlImagData = UnsafeMutablePointer<Float>.allocate(capacity: partitionedSize)
        leftRealData = UnsafeMutablePointer<Float>.allocate(capacity: partitionedSize)
        leftImagData = UnsafeMutablePointer<Float>.allocate(capacity: partitionedSize)
        rightRealData = UnsafeMutablePointer<Float>.allocate(capacity: partitionedSize)
        rightImagData = UnsafeMutablePointer<Float>.allocate(capacity: partitionedSize)
        fdlRealData.initialize(repeating: 0, count: partitionedSize)
        fdlImagData.initialize(repeating: 0, count: partitionedSize)

        Self.partition(
            impulseResponse: leftEarHRIR,
            into: leftRealData,
            imaginary: leftImagData,
            partitionCount: partitionCount,
            blockSize: blockSize,
            fftSize: fftSize,
            fftSizeHalf: fftSizeHalf,
            fftSetup: fftSetup,
            log2n: log2n
        )
        Self.partition(
            impulseResponse: rightEarHRIR,
            into: rightRealData,
            imaginary: rightImagData,
            partitionCount: partitionCount,
            blockSize: blockSize,
            fftSize: fftSize,
            fftSizeHalf: fftSizeHalf,
            fftSetup: fftSetup,
            log2n: log2n
        )
    }

    deinit {
        if ownsFFTSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }

        inputBuffer.deallocate()
        inputOverlapBuffer.deallocate()
        outputScratch.deallocate()

        accumulatorReal.deallocate()
        accumulatorImag.deallocate()
        tempMulReal.deallocate()
        tempMulImag.deallocate()

        fdlRealData.deallocate()
        fdlImagData.deallocate()
        leftRealData.deallocate()
        leftImagData.deallocate()
        rightRealData.deallocate()
        rightImagData.deallocate()
    }

    private static func partition(
        impulseResponse: [Float],
        into real: UnsafeMutablePointer<Float>,
        imaginary: UnsafeMutablePointer<Float>,
        partitionCount: Int,
        blockSize: Int,
        fftSize: Int,
        fftSizeHalf: Int,
        fftSetup: FFTSetup,
        log2n: vDSP_Length
    ) {
        var padded = [Float](repeating: 0, count: fftSize)
        for partition in 0..<partitionCount {
            let start = partition * blockSize
            let end = min(start + blockSize, impulseResponse.count)
            for index in 0..<fftSize { padded[index] = 0 }
            if end > start {
                for index in 0..<(end - start) {
                    padded[index] = impulseResponse[start + index]
                }
            }

            let offset = partition * fftSizeHalf
            var split = DSPSplitComplex(
                realp: real.advanced(by: offset),
                imagp: imaginary.advanced(by: offset)
            )
            padded.withUnsafeBufferPointer { pointer in
                pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSizeHalf) { complex in
                    vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(fftSizeHalf))
                }
            }
            vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
        }
    }

    // MARK: - Processing

    // BEGIN REALTIME CALLBACK
    /// Convolve one `blockSize` input block against both ears.
    func process(
        input: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>
    ) {
        // 1. Overlap-save input: [previous block | current block]
        memcpy(inputBuffer, inputOverlapBuffer, blockSize * MemoryLayout<Float>.size)
        memcpy(inputBuffer.advanced(by: blockSize), input, blockSize * MemoryLayout<Float>.size)
        memcpy(inputOverlapBuffer, input, blockSize * MemoryLayout<Float>.size)

        // 2. Forward FFT straight into this block's FDL slot; partition 0 then
        //    reads the slot we just wrote, which is exactly the newest block.
        fdlIndex -= 1
        if fdlIndex < 0 {
            fdlIndex += partitionCount
        }
        let headOffset = fdlIndex * fftSizeHalf
        var head = DSPSplitComplex(
            realp: fdlRealData.advanced(by: headOffset),
            imagp: fdlImagData.advanced(by: headOffset)
        )
        inputBuffer.withMemoryRebound(to: DSPComplex.self, capacity: fftSizeHalf) { complex in
            vDSP_ctoz(complex, 2, &head, 1, vDSP_Length(fftSizeHalf))
        }
        vDSP_fft_zrip(fftSetup, &head, 1, log2n, FFTDirection(kFFTDirection_Forward))

        // 3. One multiply-accumulate pass and one inverse FFT per ear.
        convolve(hrirReal: leftRealData, hrirImag: leftImagData, output: outputLeft)
        convolve(hrirReal: rightRealData, hrirImag: rightImagData, output: outputRight)
    }

    @inline(__always)
    private func convolve(
        hrirReal: UnsafeMutablePointer<Float>,
        hrirImag: UnsafeMutablePointer<Float>,
        output: UnsafeMutablePointer<Float>
    ) {
        let len = vDSP_Length(fftSizeHalf - 1)
        let accRealDC = accumulatorReal
        let accImagDC = accumulatorImag
        let fdlReal = fdlRealData
        let fdlImag = fdlImagData

        // First partition writes the accumulator directly (no zeroing pass).
        let headOffset = fdlIndex * fftSizeHalf
        let fdlRBase0 = fdlReal.advanced(by: headOffset)
        let fdlIBase0 = fdlImag.advanced(by: headOffset)

        // Packed DC/Nyquist pair.
        accRealDC.pointee = fdlRBase0.pointee * hrirReal.pointee
        accImagDC.pointee = fdlIBase0.pointee * hrirImag.pointee

        var accSplit = DSPSplitComplex(realp: accRealDC + 1, imagp: accImagDC + 1)
        var fdlSplit = DSPSplitComplex(realp: fdlRBase0 + 1, imagp: fdlIBase0 + 1)
        var hrirSplit = DSPSplitComplex(realp: hrirReal + 1, imagp: hrirImag + 1)
        vDSP_zvmul(&fdlSplit, 1, &hrirSplit, 1, &accSplit, 1, len, 1)

        var partition = 1
        while partition < partitionCount {
            var fdlIdx = fdlIndex + partition
            if fdlIdx >= partitionCount {
                fdlIdx -= partitionCount
            }

            let fdlOffset = fdlIdx * fftSizeHalf
            let hrirOffset = partition * fftSizeHalf
            let fdlRBase = fdlReal.advanced(by: fdlOffset)
            let fdlIBase = fdlImag.advanced(by: fdlOffset)
            let hRBase = hrirReal.advanced(by: hrirOffset)
            let hIBase = hrirImag.advanced(by: hrirOffset)

            accRealDC.pointee += fdlRBase.pointee * hRBase.pointee
            accImagDC.pointee += fdlIBase.pointee * hIBase.pointee

            var fdl = DSPSplitComplex(realp: fdlRBase + 1, imagp: fdlIBase + 1)
            var hrir = DSPSplitComplex(realp: hRBase + 1, imagp: hIBase + 1)
            var temp = DSPSplitComplex(realp: tempMulReal + 1, imagp: tempMulImag + 1)
            var acc = DSPSplitComplex(realp: accRealDC + 1, imagp: accImagDC + 1)

            vDSP_zvmul(&fdl, 1, &hrir, 1, &temp, 1, len, 1)
            vDSP_zvadd(&temp, 1, &acc, 1, &acc, 1, len)

            partition += 1
        }

        vDSP_fft_zrip(fftSetup, &accumulator, 1, log2n, FFTDirection(kFFTDirection_Inverse))

        var scaleFactor = 0.25 / Float(fftSize)
        vDSP_vsmul(accumulator.realp, 1, &scaleFactor, accumulator.realp, 1, vDSP_Length(fftSizeHalf))
        vDSP_vsmul(accumulator.imagp, 1, &scaleFactor, accumulator.imagp, 1, vDSP_Length(fftSizeHalf))

        outputScratch.withMemoryRebound(to: DSPComplex.self, capacity: fftSizeHalf) { complex in
            vDSP_ztoc(&accumulator, 1, complex, 2, vDSP_Length(fftSizeHalf))
        }

        // Overlap-save: the valid output is the second half.
        memcpy(output, outputScratch.advanced(by: blockSize), blockSize * MemoryLayout<Float>.size)
    }
    // END REALTIME CALLBACK

    /// Reset the engine state
    func reset() {
        memset(inputBuffer, 0, fftSize * MemoryLayout<Float>.size)
        memset(inputOverlapBuffer, 0, blockSize * MemoryLayout<Float>.size)

        let partitionedSize = partitionCount * fftSizeHalf
        memset(fdlRealData, 0, partitionedSize * MemoryLayout<Float>.size)
        memset(fdlImagData, 0, partitionedSize * MemoryLayout<Float>.size)

        fdlIndex = 0
    }
}
