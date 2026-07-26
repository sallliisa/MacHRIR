//
//  RealtimeAudioProcessor.swift
//  Airwave
//
//  Adapts arbitrary CoreAudio callback sizes to ConvolutionEngine's fixed block.
//

import Accelerate

/// Fixed-storage frame adapter for the audio render thread.
nonisolated final class RealtimeAudioProcessor {
    let blockSize: Int
    let maxFramesPerCallback: Int

    private let renderers: [VirtualSpeakerRenderer]
    private let pendingLeft: UnsafeMutablePointer<Float>
    private let pendingRight: UnsafeMutablePointer<Float>
    private let blockLeft: UnsafeMutablePointer<Float>
    private let blockRight: UnsafeMutablePointer<Float>
    private let leftTempBuffers: [UnsafeMutablePointer<Float>]
    private let rightTempBuffers: [UnsafeMutablePointer<Float>]
    private let fifoLeft: UnsafeMutablePointer<Float>
    private let fifoRight: UnsafeMutablePointer<Float>
    private let fifoCapacity: Int

    private var pendingCount = 0
    private var fifoReadIndex = 0
    private var fifoCount = 0

    init(
        renderers: [VirtualSpeakerRenderer],
        blockSize: Int = 512,
        maxFramesPerCallback: Int = 4096
    ) {
        precondition(blockSize > 0)
        precondition(maxFramesPerCallback > 0)

        self.renderers = renderers
        self.blockSize = blockSize
        self.maxFramesPerCallback = maxFramesPerCallback
        self.fifoCapacity = maxFramesPerCallback + blockSize

        pendingLeft = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        pendingRight = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        blockLeft = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        blockRight = UnsafeMutablePointer<Float>.allocate(capacity: blockSize)
        fifoLeft = UnsafeMutablePointer<Float>.allocate(capacity: fifoCapacity)
        fifoRight = UnsafeMutablePointer<Float>.allocate(capacity: fifoCapacity)

        var leftTemps: [UnsafeMutablePointer<Float>] = []
        var rightTemps: [UnsafeMutablePointer<Float>] = []
        leftTemps.reserveCapacity(renderers.count)
        rightTemps.reserveCapacity(renderers.count)
        for _ in renderers {
            leftTemps.append(UnsafeMutablePointer<Float>.allocate(capacity: blockSize))
            rightTemps.append(UnsafeMutablePointer<Float>.allocate(capacity: blockSize))
        }
        leftTempBuffers = leftTemps
        rightTempBuffers = rightTemps

        resetStorage()
    }

    deinit {
        pendingLeft.deallocate()
        pendingRight.deallocate()
        blockLeft.deallocate()
        blockRight.deallocate()
        fifoLeft.deallocate()
        fifoRight.deallocate()
        for buffer in leftTempBuffers { buffer.deallocate() }
        for buffer in rightTempBuffers { buffer.deallocate() }
    }

    /// Process any positive callback size up to maxFramesPerCallback.
    /// Underflow is deliberate: newly buffered samples produce silence until a full DSP block exists.
    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>?,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        precondition(frameCount <= maxFramesPerCallback)

        var inputOffset = 0
        while inputOffset < frameCount {
            let copyCount = min(blockSize - pendingCount, frameCount - inputOffset)
            memcpy(
                pendingLeft.advanced(by: pendingCount),
                inputLeft.advanced(by: inputOffset),
                copyCount * MemoryLayout<Float>.size
            )
            if let inputRight {
                memcpy(
                    pendingRight.advanced(by: pendingCount),
                    inputRight.advanced(by: inputOffset),
                    copyCount * MemoryLayout<Float>.size
                )
            } else {
                memcpy(
                    pendingRight.advanced(by: pendingCount),
                    inputLeft.advanced(by: inputOffset),
                    copyCount * MemoryLayout<Float>.size
                )
            }

            pendingCount += copyCount
            inputOffset += copyCount

            if pendingCount == blockSize {
                processPendingBlock()
                pendingCount = 0
            }
        }

        drain(leftOutput: leftOutput, rightOutput: rightOutput, frameCount: frameCount)
    }

    func reset() {
        for renderer in renderers {
            renderer.convolver.reset()
        }
        resetStorage()
    }

    private func resetStorage() {
        memset(pendingLeft, 0, blockSize * MemoryLayout<Float>.size)
        memset(pendingRight, 0, blockSize * MemoryLayout<Float>.size)
        memset(blockLeft, 0, blockSize * MemoryLayout<Float>.size)
        memset(blockRight, 0, blockSize * MemoryLayout<Float>.size)
        memset(fifoLeft, 0, fifoCapacity * MemoryLayout<Float>.size)
        memset(fifoRight, 0, fifoCapacity * MemoryLayout<Float>.size)
        pendingCount = 0
        fifoReadIndex = 0
        fifoCount = 0
    }

    private func processPendingBlock() {
        memset(blockLeft, 0, blockSize * MemoryLayout<Float>.size)
        memset(blockRight, 0, blockSize * MemoryLayout<Float>.size)

        let rendererCount = min(renderers.count, 2)
        for rendererIndex in 0..<rendererCount {
            let input = rendererIndex == 0 ? pendingLeft : pendingRight
            let renderer = renderers[rendererIndex]
            renderer.convolver.process(
                input: input,
                outputLeft: leftTempBuffers[rendererIndex],
                outputRight: rightTempBuffers[rendererIndex]
            )

            vDSP_vadd(
                blockLeft, 1,
                leftTempBuffers[rendererIndex], 1,
                blockLeft, 1,
                vDSP_Length(blockSize)
            )
            vDSP_vadd(
                blockRight, 1,
                rightTempBuffers[rendererIndex], 1,
                blockRight, 1,
                vDSP_Length(blockSize)
            )
        }

        // At most two segments: up to the end of the ring, then the wrap.
        let writeIndex = (fifoReadIndex + fifoCount) % fifoCapacity
        let firstCount = min(blockSize, fifoCapacity - writeIndex)
        memcpy(fifoLeft.advanced(by: writeIndex), blockLeft, firstCount * MemoryLayout<Float>.size)
        memcpy(fifoRight.advanced(by: writeIndex), blockRight, firstCount * MemoryLayout<Float>.size)
        if firstCount < blockSize {
            let remainder = blockSize - firstCount
            memcpy(fifoLeft, blockLeft.advanced(by: firstCount), remainder * MemoryLayout<Float>.size)
            memcpy(fifoRight, blockRight.advanced(by: firstCount), remainder * MemoryLayout<Float>.size)
        }
        fifoCount += blockSize
    }

    private func drain(
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        let available = min(fifoCount, frameCount)
        if available > 0 {
            let firstCount = min(available, fifoCapacity - fifoReadIndex)
            memcpy(leftOutput, fifoLeft.advanced(by: fifoReadIndex), firstCount * MemoryLayout<Float>.size)
            memcpy(rightOutput, fifoRight.advanced(by: fifoReadIndex), firstCount * MemoryLayout<Float>.size)
            if firstCount < available {
                let remainder = available - firstCount
                memcpy(leftOutput.advanced(by: firstCount), fifoLeft, remainder * MemoryLayout<Float>.size)
                memcpy(rightOutput.advanced(by: firstCount), fifoRight, remainder * MemoryLayout<Float>.size)
            }
            fifoReadIndex = (fifoReadIndex + available) % fifoCapacity
            fifoCount -= available
        }

        // Underflow is deliberate: silence until a full DSP block exists.
        if available < frameCount {
            let missing = frameCount - available
            memset(leftOutput.advanced(by: available), 0, missing * MemoryLayout<Float>.size)
            memset(rightOutput.advanced(by: available), 0, missing * MemoryLayout<Float>.size)
        }
    }
}
