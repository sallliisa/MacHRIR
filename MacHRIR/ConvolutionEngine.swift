//
//  ConvolutionEngine.swift
//  MacHRIR
//
//  Uniform Partitioned Convolution using Accelerate framework
//  Implements the Uniform Partitioned Overlap-Save (UPOLS) algorithm
//  to efficiently handle long HRIR filters with zero added latency.
//

import Foundation
import Accelerate

/// Real-time partitioned convolution engine
class ConvolutionEngine {

    // MARK: - Properties

    private let log2n: vDSP_Length
    private let fftSize: Int
    private let fftSizeHalf: Int
    private let blockSize: Int
    private let partitionCount: Int
    
    private let fftSetup: FFTSetup
    
    // Input Buffering (Overlap-Save)
    private let inputBuffer: UnsafeMutablePointer<Float>
    private let inputOverlapBuffer: UnsafeMutablePointer<Float> // Stores previous block
    
    // Frequency Domain Delay Line (FDL)
    // We store the FFT of past input blocks.
    // fdlReal[i] points to the real part of the i-th past block
    private var fdlReal: [UnsafeMutablePointer<Float>] = []
    private var fdlImag: [UnsafeMutablePointer<Float>] = []
    private var fdlIndex: Int = 0
    
    // HRIR Partitions (Frequency Domain)
    // hrirReal[i] points to the real part of the i-th partition of the filter
    private var hrirReal: [UnsafeMutablePointer<Float>] = []
    private var hrirImag: [UnsafeMutablePointer<Float>] = []
    
    // Processing Buffers
    private let splitComplexInputReal: UnsafeMutablePointer<Float>
    private let splitComplexInputImag: UnsafeMutablePointer<Float>
    private var splitComplexInput: DSPSplitComplex
    
    private let accumulatorReal: UnsafeMutablePointer<Float>
    private let accumulatorImag: UnsafeMutablePointer<Float>
    private var accumulator: DSPSplitComplex
    
    private let tempMulReal: UnsafeMutablePointer<Float>
    private let tempMulImag: UnsafeMutablePointer<Float>
    private var tempMul: DSPSplitComplex
    
    private var debugCounter: Int = 0

    // MARK: - Initialization

    /// Initialize convolution engine with partitioned convolution
    /// - Parameters:
    ///   - hrirSamples: Impulse response samples (can be long)
    ///   - blockSize: Processing block size (typically 512)
    init?(hrirSamples: [Float], blockSize: Int = 512) {
        self.blockSize = blockSize
        
        // 1. Setup FFT (Size = 2 * BlockSize for Overlap-Save)
        self.fftSize = blockSize * 2
        self.fftSizeHalf = fftSize / 2
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            print("[Convolution] Failed to create FFT setup")
            return nil
        }
        self.fftSetup = setup
        
        // 2. Calculate Partitions
        // We pad the HRIR to be a multiple of blockSize
        self.partitionCount = Int(ceil(Double(hrirSamples.count) / Double(blockSize)))
        
        print("[Convolution] Init: BlockSize=\(blockSize), HRIR=\(hrirSamples.count), Partitions=\(partitionCount)")
        
        // 3. Allocate Input Buffers
        self.inputBuffer = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
        self.inputBuffer.initialize(repeating: 0, count: fftSize)
        
        self.inputOverlapBuffer = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        self.inputOverlapBuffer.initialize(repeating: 0, count: blockSize)
        
        // 4. Allocate Processing Buffers
        self.splitComplexInputReal = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        self.splitComplexInputImag = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        self.splitComplexInput = DSPSplitComplex(realp: splitComplexInputReal, imagp: splitComplexInputImag)
        
        self.accumulatorReal = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        self.accumulatorImag = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        self.accumulator = DSPSplitComplex(realp: accumulatorReal, imagp: accumulatorImag)
        
        self.tempMulReal = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        self.tempMulImag = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
        self.tempMul = DSPSplitComplex(realp: tempMulReal, imagp: tempMulImag)
        
        // 5. Initialize FDL and HRIR Arrays
        for _ in 0..<partitionCount {
            // FDL
            let fReal = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
            let fImag = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
            fReal.initialize(repeating: 0, count: fftSizeHalf)
            fImag.initialize(repeating: 0, count: fftSizeHalf)
            fdlReal.append(fReal)
            fdlImag.append(fImag)
            
            // HRIR
            let hReal = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
            let hImag = UnsafeMutablePointer<Float>.allocate(capacity: fftSizeHalf)
            hrirReal.append(hReal)
            hrirImag.append(hImag)
        }
        
        // 6. Process HRIR Partitions
        var tempPadBuffer = [Float](repeating: 0, count: fftSize)
        
        for p in 0..<partitionCount {
            // Clear temp buffer
            memset(tempPadBuffer.withUnsafeMutableBufferPointer { $0.baseAddress! }, 0, fftSize * MemoryLayout<Float>.size)
            
            // Copy HRIR chunk
            let startIdx = p * blockSize
            let endIdx = min(startIdx + blockSize, hrirSamples.count)
            let copyCount = endIdx - startIdx
            
            if copyCount > 0 {
                for i in 0..<copyCount {
                    tempPadBuffer[i] = hrirSamples[startIdx + i]
                }
            }
            
            // FFT this partition
            // We use the temp buffer as input to FFT.
            // Note: For real-to-complex FFT, we pack the input.
            // But here we can just use our split complex buffers directly if we cast.
            
            // Pack into split complex (using hrirReal/Imag as destination)
            var splitH = DSPSplitComplex(realp: hrirReal[p], imagp: hrirImag[p])
            
            tempPadBuffer.withUnsafeBufferPointer { ptr in
                ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSizeHalf) { complexPtr in
                    vDSP_ctoz(complexPtr, 2, &splitH, 1, vDSP_Length(fftSizeHalf))
                }
            }
            
            // Forward FFT
            vDSP_fft_zrip(fftSetup, &splitH, 1, log2n, FFTDirection(kFFTDirection_Forward))

            // Debug: Check first partition energy
            if p == 0 {
                var energy: Float = 0
                vDSP_sve(hrirReal[0], 1, &energy, vDSP_Length(fftSizeHalf))
                print("[Convolution] Partition 0 real sum: \(energy)")
            }
        }

        // Debug: Log HRIR FFT energy for first few partitions
        for p in 0..<min(3, partitionCount) {
            var realEnergy: Float = 0
            var imagEnergy: Float = 0
            vDSP_svesq(hrirReal[p], 1, &realEnergy, vDSP_Length(fftSizeHalf))
            vDSP_svesq(hrirImag[p], 1, &imagEnergy, vDSP_Length(fftSizeHalf))
            let totalEnergy = sqrt(realEnergy + imagEnergy)
            print("[Convolution] Partition[\(p)] FFT energy: \(String(format: "%.6f", totalEnergy))")
        }
    }
    
    deinit {
        vDSP_destroy_fftsetup(fftSetup)
        
        inputBuffer.deallocate()
        inputOverlapBuffer.deallocate()
        
        splitComplexInputReal.deallocate()
        splitComplexInputImag.deallocate()
        
        accumulatorReal.deallocate()
        accumulatorImag.deallocate()
        
        tempMulReal.deallocate()
        tempMulImag.deallocate()
        
        for ptr in fdlReal { ptr.deallocate() }
        for ptr in fdlImag { ptr.deallocate() }
        for ptr in hrirReal { ptr.deallocate() }
        for ptr in hrirImag { ptr.deallocate() }
    }

    // MARK: - Public Methods

    /// Process a block of audio samples using Uniform Partitioned Overlap-Save
    /// - Parameters:
    ///   - input: Input buffer pointer (must contain `blockSize` samples)
    ///   - output: Output buffer pointer (must have capacity for `blockSize` samples)
    func process(input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>) {
        // 1. Prepare Input (Overlap-Save)
        // Construct buffer: [PreviousBlock | CurrentBlock]
        
        // Copy previous block to first half of inputBuffer
        memcpy(inputBuffer, inputOverlapBuffer, blockSize * MemoryLayout<Float>.size)
        
        // Copy new input to second half
        memcpy(inputBuffer.advanced(by: blockSize), input, blockSize * MemoryLayout<Float>.size)
        
        // Save current input as next overlap
        memcpy(inputOverlapBuffer, input, blockSize * MemoryLayout<Float>.size)
        
        // 2. FFT Input
        // Pack to split complex
        inputBuffer.withMemoryRebound(to: DSPComplex.self, capacity: fftSizeHalf) { complexPtr in
            vDSP_ctoz(complexPtr, 2, &splitComplexInput, 1, vDSP_Length(fftSizeHalf))
        }
        
        // Forward FFT
        vDSP_fft_zrip(fftSetup, &splitComplexInput, 1, log2n, FFTDirection(kFFTDirection_Forward))
        
        // 3. Update FDL (Frequency Delay Line)
        // Write current FFT to FDL at current index
        fdlIndex = (fdlIndex - 1 + partitionCount) % partitionCount
        
        // Copy current FFT to FDL head
        memcpy(fdlReal[fdlIndex], splitComplexInput.realp, fftSizeHalf * MemoryLayout<Float>.size)
        memcpy(fdlImag[fdlIndex], splitComplexInput.imagp, fftSizeHalf * MemoryLayout<Float>.size)
        
        // 4. Convolution Sum (Partitioned)
        // Accumulator = Sum(FDL[i] * HRIR[i])
        
        // Reset accumulator to 0
        memset(accumulator.realp, 0, fftSizeHalf * MemoryLayout<Float>.size)
        memset(accumulator.imagp, 0, fftSizeHalf * MemoryLayout<Float>.size)
        
        for p in 0..<partitionCount {
            let fdlIdx = (fdlIndex + p) % partitionCount
            
            var fdlSplit = DSPSplitComplex(realp: fdlReal[fdlIdx], imagp: fdlImag[fdlIdx])
            var hrirSplit = DSPSplitComplex(realp: hrirReal[p], imagp: hrirImag[p])
            
            if p == 0 {
                vDSP_zvmul(&fdlSplit, 1, &hrirSplit, 1, &accumulator, 1, vDSP_Length(fftSizeHalf), 1)
            } else {
                vDSP_zvmul(&fdlSplit, 1, &hrirSplit, 1, &tempMul, 1, vDSP_Length(fftSizeHalf), 1)
                vDSP_zvadd(&tempMul, 1, &accumulator, 1, &accumulator, 1, vDSP_Length(fftSizeHalf))
            }
        }
        
        // 5. Inverse FFT
        vDSP_fft_zrip(fftSetup, &accumulator, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        
        // 6. Scale Output
        let scaleFactor = 0.25 / Float(fftSize)
        vDSP_vsmul(accumulator.realp, 1, [scaleFactor], accumulator.realp, 1, vDSP_Length(fftSizeHalf))
        vDSP_vsmul(accumulator.imagp, 1, [scaleFactor], accumulator.imagp, 1, vDSP_Length(fftSizeHalf))
        
        // 7. Unpack and Extract Valid Output
        inputBuffer.withMemoryRebound(to: DSPComplex.self, capacity: fftSizeHalf) { complexPtr in
            vDSP_ztoc(&accumulator, 1, complexPtr, 2, vDSP_Length(fftSizeHalf))
        }
        
        // The valid output is the second half
        memcpy(output, inputBuffer.advanced(by: blockSize), blockSize * MemoryLayout<Float>.size)
        
        if debugCounter < 2 {
            print("[Convolution] Processed partitioned block. Partitions: \(partitionCount)")
            debugCounter += 1
        }
    }

    /// Process a block of audio samples using Uniform Partitioned Overlap-Save
    func process(input: [Float], output: inout [Float], frameCount: Int? = nil) {
        let count = frameCount ?? blockSize
        guard count == blockSize else { return }
        
        input.withUnsafeBufferPointer { inPtr in
            output.withUnsafeMutableBufferPointer { outPtr in
                guard let inAddr = inPtr.baseAddress, let outAddr = outPtr.baseAddress else { return }
                process(input: inAddr, output: outAddr)
            }
        }
    }
    
    /// Process and accumulate: convolve input and ADD result to existing output buffer
    /// This is critical for multi-channel binaural mixing where multiple virtual speakers
    /// contribute to the same stereo output.
    /// - Parameters:
    ///   - input: Input buffer pointer (must contain `blockSize` samples)
    ///   - outputAccumulator: Output buffer pointer to accumulate into (must have capacity for `blockSize` samples)
    func processAndAccumulate(input: UnsafePointer<Float>, outputAccumulator: UnsafeMutablePointer<Float>) {
        // We need a temporary buffer to hold the convolution result
        // Then we add it to the accumulator
        let tempOutput = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        defer { tempOutput.deallocate() }
        
        // Perform convolution
        process(input: input, output: tempOutput)
        
        // Add to accumulator using vDSP
        vDSP_vadd(outputAccumulator, 1, tempOutput, 1, outputAccumulator, 1, vDSP_Length(blockSize))
    }
    
    /// Reset the engine state
    func reset() {
        memset(inputBuffer, 0, fftSize * MemoryLayout<Float>.size)
        memset(inputOverlapBuffer, 0, blockSize * MemoryLayout<Float>.size)
        
        for ptr in fdlReal { memset(ptr, 0, fftSizeHalf * MemoryLayout<Float>.size) }
        for ptr in fdlImag { memset(ptr, 0, fftSizeHalf * MemoryLayout<Float>.size) }
        
        fdlIndex = 0
    }
}
