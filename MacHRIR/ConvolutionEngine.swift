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
    
    // Power-of-2 partitioning for branch-free circular indexing
    private let partitionCountPow2: Int  // Next power of 2 >= partitionCount
    private let partitionMask: Int       // partitionCountPow2 - 1 for bitwise AND
    
    private let fftSetup: FFTSetup
    private let ownsFFTSetup: Bool  // Track if we own the FFTSetup (should destroy in deinit)
    
    // Input Buffering (Overlap-Save)
    private let inputBuffer: UnsafeMutablePointer<Float>
    private let inputOverlapBuffer: UnsafeMutablePointer<Float> // Stores previous block
    
    // Frequency Domain Delay Line (FDL) - OPTIMIZED: Contiguous flat buffers
    // We store the FFT of past input blocks in contiguous memory for cache efficiency
    private var fdlRealData: UnsafeMutablePointer<Float>!
    private var fdlImagData: UnsafeMutablePointer<Float>!
    private var fdlIndex: Int = 0
    
    // HRIR Partitions (Frequency Domain) - OPTIMIZED: Contiguous flat buffers
    private var hrirRealData: UnsafeMutablePointer<Float>!
    private var hrirImagData: UnsafeMutablePointer<Float>!
    
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
    
    // Pre-allocated buffer for processAndAccumulate to avoid real-time allocation
    private let tempOutputBuffer: UnsafeMutablePointer<Float>
    
    // MARK: - Initialization

    /// Initialize convolution engine with partitioned convolution
    /// - Parameters:
    ///   - hrirSamples: Impulse response samples (can be long)
    ///   - blockSize: Processing block size (default 512 for CPU efficiency)
    ///   - sharedFFTSetup: Optional shared FFTSetup to reduce memory usage (recommended)
    init?(hrirSamples: [Float], blockSize: Int = 512, sharedFFTSetup: FFTSetup? = nil) {
        self.blockSize = blockSize
        
        // 1. Setup FFT (Size = 2 * BlockSize for Overlap-Save)
        self.fftSize = blockSize * 2
        self.fftSizeHalf = fftSize / 2
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        
        // Use shared setup if provided, otherwise create private one
        if let shared = sharedFFTSetup {
            self.fftSetup = shared
            self.ownsFFTSetup = false
            Logger.log("[Convolution] Using shared FFT setup")
        } else {
            guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
                Logger.log("[Convolution] Failed to create FFT setup")
                return nil
            }
            self.fftSetup = setup
            self.ownsFFTSetup = true
            Logger.log("[Convolution] Created private FFT setup")
        }
        
        // 2. Calculate Partitions
        // We pad the HRIR to be a multiple of blockSize
        self.partitionCount = Int(ceil(Double(hrirSamples.count) / Double(blockSize)))
        
        // Calculate power-of-2 partition count for branch-free circular indexing
        self.partitionCountPow2 = 1 << Int(ceil(log2(Double(partitionCount))))
        self.partitionMask = partitionCountPow2 - 1
        
        Logger.log("[Convolution] Init: BlockSize=\(blockSize), HRIR=\(hrirSamples.count), Partitions=\(partitionCount), Pow2=\(partitionCountPow2)")
        
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
        
        // Pre-allocate temp buffer for processAndAccumulate
        self.tempOutputBuffer = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        
        // 5. Initialize FDL and HRIR Flat Buffers (OPTIMIZED: Contiguous memory)
        // Allocate single contiguous blocks for all partitions to improve cache efficiency
        let fdlTotalSize = partitionCountPow2 * fftSizeHalf
        let hrirTotalSize = partitionCountPow2 * fftSizeHalf
        
        fdlRealData = UnsafeMutablePointer<Float>.allocate(capacity: fdlTotalSize)
        fdlImagData = UnsafeMutablePointer<Float>.allocate(capacity: fdlTotalSize)
        hrirRealData = UnsafeMutablePointer<Float>.allocate(capacity: hrirTotalSize)
        hrirImagData = UnsafeMutablePointer<Float>.allocate(capacity: hrirTotalSize)
        
        // Initialize all to zero
        fdlRealData.initialize(repeating: 0, count: fdlTotalSize)
        fdlImagData.initialize(repeating: 0, count: fdlTotalSize)
        hrirRealData.initialize(repeating: 0, count: hrirTotalSize)
        hrirImagData.initialize(repeating: 0, count: hrirTotalSize)
        
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
            // Calculate offset into flat buffer for this partition
            let partitionOffset = p * fftSizeHalf
            let hrirRealPartition = hrirRealData.advanced(by: partitionOffset)
            let hrirImagPartition = hrirImagData.advanced(by: partitionOffset)
            
            // Pack into split complex (using flat buffer offsets)
            var splitH = DSPSplitComplex(realp: hrirRealPartition, imagp: hrirImagPartition)
            
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
                vDSP_sve(hrirRealData, 1, &energy, vDSP_Length(fftSizeHalf))
                Logger.log("[Convolution] Partition 0 real sum: \(energy)")
            }
        }

        // Debug: Log HRIR FFT energy for first few partitions
        for p in 0..<min(3, partitionCount) {
            let partitionOffset = p * fftSizeHalf
            let hrirRealPartition = hrirRealData.advanced(by: partitionOffset)
            let hrirImagPartition = hrirImagData.advanced(by: partitionOffset)
            
            var realEnergy: Float = 0
            var imagEnergy: Float = 0
            vDSP_svesq(hrirRealPartition, 1, &realEnergy, vDSP_Length(fftSizeHalf))
            vDSP_svesq(hrirImagPartition, 1, &imagEnergy, vDSP_Length(fftSizeHalf))
            let totalEnergy = sqrt(realEnergy + imagEnergy)
            Logger.log("[Convolution] Partition[\(p)] FFT energy: \(String(format: "%.6f", totalEnergy))")
        }
    }
    
    deinit {
        // Only destroy FFTSetup if we own it
        if ownsFFTSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
        
        inputBuffer.deallocate()
        inputOverlapBuffer.deallocate()
        
        splitComplexInputReal.deallocate()
        splitComplexInputImag.deallocate()
        
        accumulatorReal.deallocate()
        accumulatorImag.deallocate()
        
        tempMulReal.deallocate()
        tempMulImag.deallocate()
        
        tempOutputBuffer.deallocate()
        
        // Deallocate flat buffers
        fdlRealData.deallocate()
        fdlImagData.deallocate()
        hrirRealData.deallocate()
        hrirImagData.deallocate()
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
        fdlIndex -= 1
        if fdlIndex < 0 {
            fdlIndex += partitionCount
        }
        
        // Copy current FFT to FDL head (using flat buffer with offset)
        let fdlOffset = fdlIndex * fftSizeHalf
        memcpy(fdlRealData.advanced(by: fdlOffset), splitComplexInput.realp, fftSizeHalf * MemoryLayout<Float>.size)
        memcpy(fdlImagData.advanced(by: fdlOffset), splitComplexInput.imagp, fftSizeHalf * MemoryLayout<Float>.size)
        
        // 4. Convolution Sum (Partitioned)
        // Accumulator = Sum(FDL[i] * HRIR[i])
        
        // Reset accumulator to 0
        memset(accumulator.realp, 0, fftSizeHalf * MemoryLayout<Float>.size)
        memset(accumulator.imagp, 0, fftSizeHalf * MemoryLayout<Float>.size)
        
        // Pre-calculate length outside loop (invariant)
        let len = vDSP_Length(fftSizeHalf - 1)
        
        // Cache accumulator DC pointers (avoid repeated access)
        let accRealDC = accumulator.realp
        let accImagDC = accumulator.imagp
        
        // Capture class properties to locals to avoid self access in hot loop
        let fdlRealDataLocal = fdlRealData!
        let fdlImagDataLocal = fdlImagData!
        let hrirRealDataLocal = hrirRealData!
        let hrirImagDataLocal = hrirImagData!
        
        // Capture temp buffer pointers
        let tempMulReal = tempMul.realp
        let tempMulImag = tempMul.imagp
        
        // OPTIMIZATION: Unroll first partition outside loop to eliminate branches
        // Handle first partition (p=0)
        // NOTE: FDL uses modulo by partitionCount (not power-of-2) for correct wraparound
        var fdlIdx0 = fdlIndex
        if fdlIdx0 < 0 {
            fdlIdx0 += partitionCount
        }
        let fdlOffset0 = fdlIdx0 * fftSizeHalf
        let fdlRBase0 = fdlRealDataLocal.advanced(by: fdlOffset0)
        let fdlIBase0 = fdlImagDataLocal.advanced(by: fdlOffset0)
        let hRBase0 = hrirRealDataLocal  // First HRIR partition (offset 0)
        let hIBase0 = hrirImagDataLocal
        
        // DC/Nyquist for first partition (direct assignment, no accumulation)
        accRealDC.pointee = fdlRBase0.pointee * hRBase0.pointee
        accImagDC.pointee = fdlIBase0.pointee * hIBase0.pointee
        
        // Complex bins for first partition (direct write, no accumulation)
        var accSplit = DSPSplitComplex(realp: accRealDC + 1, imagp: accImagDC + 1)
        var fdlSplit = DSPSplitComplex(realp: fdlRBase0 + 1, imagp: fdlIBase0 + 1)
        var hrirSplit = DSPSplitComplex(realp: hRBase0 + 1, imagp: hIBase0 + 1)
        vDSP_zvmul(&fdlSplit, 1, &hrirSplit, 1, &accSplit, 1, len, 1)
        
        // OPTIMIZATION: Remaining partitions - stack-allocated structs per iteration
        // This allows the compiler to optimize struct lifetime and eliminates repeated mutations
        var p = 1
        while p < partitionCount {
            // FDL circular index calculation
            // CRITICAL: Must use partitionCount for wraparound, not partitionMask
            // because HRIR only has valid data in [0, partitionCount), not [0, partitionCountPow2)
            var fdlIdx = fdlIndex + p
            if fdlIdx >= partitionCount {
                fdlIdx -= partitionCount
            }
            
            // Calculate offsets into flat contiguous buffers (cache-friendly)
            let fdlOffset = fdlIdx * fftSizeHalf
            let hrirOffset = p * fftSizeHalf
            
            // Get base pointers from flat buffers (single pointer arithmetic, no double dereference)
            let fdlRBase = fdlRealDataLocal.advanced(by: fdlOffset)
            let fdlIBase = fdlImagDataLocal.advanced(by: fdlOffset)
            let hRBase = hrirRealDataLocal.advanced(by: hrirOffset)
            let hIBase = hrirImagDataLocal.advanced(by: hrirOffset)
            
            // Accumulate DC and Nyquist (no branch - always accumulate for p > 0)
            accRealDC.pointee += fdlRBase.pointee * hRBase.pointee
            accImagDC.pointee += fdlIBase.pointee * hIBase.pointee
            
            // Stack-allocated structs for complex bins (compiler can optimize lifetime)
            var fdl = DSPSplitComplex(realp: fdlRBase + 1, imagp: fdlIBase + 1)
            var hrir = DSPSplitComplex(realp: hRBase + 1, imagp: hIBase + 1)
            var temp = DSPSplitComplex(realp: tempMulReal + 1, imagp: tempMulImag + 1)
            var acc = DSPSplitComplex(realp: accRealDC + 1, imagp: accImagDC + 1)
            
            // vDSP operations
            vDSP_zvmul(&fdl, 1, &hrir, 1, &temp, 1, len, 1)
            vDSP_zvadd(&temp, 1, &acc, 1, &acc, 1, len)
            
            p += 1
        }
        
        // 5. Inverse FFT
        vDSP_fft_zrip(fftSetup, &accumulator, 1, log2n, FFTDirection(kFFTDirection_Inverse))
        
        // 6. Scale Output
        var scaleFactor = 0.25 / Float(fftSize)  // var so we can take pointer
        vDSP_vsmul(accumulator.realp, 1, &scaleFactor, accumulator.realp, 1, vDSP_Length(fftSizeHalf))
        vDSP_vsmul(accumulator.imagp, 1, &scaleFactor, accumulator.imagp, 1, vDSP_Length(fftSizeHalf))
        
        // 7. Unpack and Extract Valid Output
        inputBuffer.withMemoryRebound(to: DSPComplex.self, capacity: fftSizeHalf) { complexPtr in
            vDSP_ztoc(&accumulator, 1, complexPtr, 2, vDSP_Length(fftSizeHalf))
        }
        
        // The valid output is the second half
        memcpy(output, inputBuffer.advanced(by: blockSize), blockSize * MemoryLayout<Float>.size)
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
        // Use pre-allocated temp buffer (no allocation in real-time path)
        process(input: input, output: tempOutputBuffer)
        
        // Add to accumulator using vDSP
        vDSP_vadd(outputAccumulator, 1, tempOutputBuffer, 1, outputAccumulator, 1, vDSP_Length(blockSize))
    }
    
    /// Reset the engine state
    func reset() {
        memset(inputBuffer, 0, fftSize * MemoryLayout<Float>.size)
        memset(inputOverlapBuffer, 0, blockSize * MemoryLayout<Float>.size)
        
        // Reset flat FDL buffers
        let fdlTotalSize = partitionCountPow2 * fftSizeHalf
        memset(fdlRealData, 0, fdlTotalSize * MemoryLayout<Float>.size)
        memset(fdlImagData, 0, fdlTotalSize * MemoryLayout<Float>.size)
        
        fdlIndex = 0
    }
}
