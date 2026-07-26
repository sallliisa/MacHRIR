import XCTest
@testable import Airwave

final class RealtimeAudioProcessorTests: XCTestCase {
    private let blockSize = 512
    private let maxFrames = 4096

    private func makeProcessor(rendererCount: Int = 2) -> RealtimeAudioProcessor {
        let renderers = (0..<rendererCount).map { index in
            let left = try! XCTUnwrap(ConvolutionEngine(
                hrirSamples: [Float(index + 1)],
                blockSize: blockSize
            ))
            let right = try! XCTUnwrap(ConvolutionEngine(
                hrirSamples: [Float(index + 1)],
                blockSize: blockSize
            ))
            return VirtualSpeakerRenderer(
                speaker: index == 0 ? .FL : .FR,
                convolverLeftEar: left,
                convolverRightEar: right
            )
        }
        return RealtimeAudioProcessor(
            renderers: renderers,
            blockSize: blockSize,
            maxFramesPerCallback: maxFrames
        )
    }

    private func process(
        _ processor: RealtimeAudioProcessor,
        size: Int,
        leftValue: Float = 1,
        rightValue: Float = 2
    ) -> ([Float], [Float]) {
        let left = [Float](repeating: leftValue, count: size)
        let right = [Float](repeating: rightValue, count: size)
        var outputLeft = [Float](repeating: .nan, count: size)
        var outputRight = [Float](repeating: .nan, count: size)
        left.withUnsafeBufferPointer { leftPtr in
            right.withUnsafeBufferPointer { rightPtr in
                outputLeft.withUnsafeMutableBufferPointer { leftOutPtr in
                    outputRight.withUnsafeMutableBufferPointer { rightOutPtr in
                        processor.process(
                            inputLeft: leftPtr.baseAddress!,
                            inputRight: rightPtr.baseAddress!,
                            leftOutput: leftOutPtr.baseAddress!,
                            rightOutput: rightOutPtr.baseAddress!,
                            frameCount: size
                        )
                    }
                }
            }
        }
        return (outputLeft, outputRight)
    }

    func testAllRequiredCallbackSizesWriteFiniteOutput() {
        for size in [1, 64, 128, 256, 511, 512, 513, 768, 1024, 4096] {
            let processor = makeProcessor()
            let (left, right) = process(processor, size: size)
            XCTAssertTrue(left.allSatisfy { $0.isFinite }, "left size \(size)")
            XCTAssertTrue(right.allSatisfy { $0.isFinite }, "right size \(size)")
        }
    }

    func testMixedCallbackSequencePreservesOrderAfterAdapterLatency() {
        let processor = makeProcessor(rendererCount: 1)
        var output: [Float] = []
        for size in [128, 128, 128, 128, 513, 768, 1024, 4096] {
            output.append(contentsOf: process(processor, size: size).0)
        }

        XCTAssertEqual(output.count, 6913)
        XCTAssertTrue(output.prefix(384).allSatisfy { $0 == 0 })
        XCTAssertTrue(output.dropFirst(384).allSatisfy { abs($0 - 1) < 0.0001 })
    }

    func testResetClearsPendingInputAndQueuedOutput() {
        let processor = makeProcessor(rendererCount: 1)
        _ = process(processor, size: 512)
        processor.reset()
        let (left, right) = process(processor, size: 1)

        XCTAssertEqual(left, [0])
        XCTAssertEqual(right, [0])
    }

    func testUnderflowSilenceAndMonoDuplication() {
        let processor = makeProcessor(rendererCount: 1)
        let (underflowLeft, underflowRight) = process(processor, size: 3, leftValue: 0.5, rightValue: 0.5)
        XCTAssertEqual(underflowLeft, [0, 0, 0])
        XCTAssertEqual(underflowRight, underflowLeft)
        let (left, right) = process(processor, size: 512, leftValue: 0.5, rightValue: 0.5)
        XCTAssertEqual(left, right)
    }

    func testCanariesRemainUnchanged() {
        let processor = makeProcessor(rendererCount: 1)
        let size = 4096
        let canary: Float = 12345
        let inputStorage = UnsafeMutablePointer<Float>.allocate(capacity: size + 2)
        let outputStorage = UnsafeMutablePointer<Float>.allocate(capacity: size + 2)
        inputStorage.initialize(repeating: 0, count: size + 2)
        outputStorage.initialize(repeating: canary, count: size + 2)
        defer {
            inputStorage.deinitialize(count: size + 2)
            outputStorage.deinitialize(count: size + 2)
            inputStorage.deallocate()
            outputStorage.deallocate()
        }

        processor.process(
            inputLeft: UnsafePointer(inputStorage.advanced(by: 1)),
            inputRight: nil,
            leftOutput: outputStorage.advanced(by: 1),
            rightOutput: outputStorage.advanced(by: 1),
            frameCount: size
        )

        XCTAssertEqual(inputStorage[0], 0)
        XCTAssertEqual(inputStorage[size + 1], 0)
        XCTAssertEqual(outputStorage[0], canary)
        XCTAssertEqual(outputStorage[size + 1], canary)
    }

    func testTenSecondsOfStereoInputAcrossPerformanceCallbackSizes() {
        let sampleRate = 48_000
        let callbackSizes = [128, 512, 1024]
        var processedFrames = 0
        var finalLeftOutput: [Float] = []
        var finalRightOutput: [Float] = []

        measure {
            for size in callbackSizes {
                let processor = makeProcessor(rendererCount: 1)
                let input = [Float](repeating: 0.25, count: size)
                var leftOutput = [Float](repeating: 0, count: size)
                var rightOutput = [Float](repeating: 0, count: size)
                processedFrames = 0
                while processedFrames < sampleRate * 10 {
                    input.withUnsafeBufferPointer { inputPtr in
                        leftOutput.withUnsafeMutableBufferPointer { leftPtr in
                            rightOutput.withUnsafeMutableBufferPointer { rightPtr in
                                processor.process(
                                    inputLeft: inputPtr.baseAddress!,
                                    inputRight: inputPtr.baseAddress!,
                                    leftOutput: leftPtr.baseAddress!,
                                    rightOutput: rightPtr.baseAddress!,
                                    frameCount: size
                                )
                            }
                        }
                    }
                    processedFrames += size
                }
                finalLeftOutput = leftOutput
                finalRightOutput = rightOutput
            }
        }

        XCTAssertGreaterThanOrEqual(processedFrames, sampleRate * 10)
        XCTAssertTrue(finalLeftOutput.allSatisfy { $0.isFinite })
        XCTAssertTrue(finalRightOutput.allSatisfy { $0.isFinite })
    }
}

final class SpatialRendererCrossfaderTests: XCTestCase {
    private let blockSize = 512
    private let fadeLength = 1_024

    private func makeState(gain: Float) -> HRIRManager.RendererState {
        let left = ConvolutionEngine(hrirSamples: [gain], blockSize: blockSize)!
        let right = ConvolutionEngine(hrirSamples: [gain], blockSize: blockSize)!
        return HRIRManager.RendererState(
            renderers: [VirtualSpeakerRenderer(speaker: .FL, convolverLeftEar: left, convolverRightEar: right)],
            blockSize: blockSize
        )
    }

    private func makeCrossfader() -> SpatialRendererCrossfader {
        SpatialRendererCrossfader(primeLength: blockSize, fadeLength: fadeLength, maxFramesPerCallback: 4_096)
    }

    /// Drives a continuous 480 Hz sine through the crossfader in fixed callbacks
    /// and records the input and output streams for comparison.
    private final class Driver {
        let crossfader: SpatialRendererCrossfader
        private(set) var input: [Float] = []
        private(set) var outputLeft: [Float] = []
        private(set) var outputRight: [Float] = []
        private var frame = 0

        init(_ crossfader: SpatialRendererCrossfader) { self.crossfader = crossfader }

        func run(callbacks: Int, size: Int = 512) {
            for _ in 0..<callbacks {
                var chunk = [Float](repeating: 0, count: size)
                for index in 0..<size {
                    chunk[index] = Float(sin(2 * Double.pi * 480 * Double(frame + index) / 48_000))
                }
                frame += size
                var left = [Float](repeating: .nan, count: size)
                var right = [Float](repeating: .nan, count: size)
                chunk.withUnsafeBufferPointer { inputPtr in
                    left.withUnsafeMutableBufferPointer { leftPtr in
                        right.withUnsafeMutableBufferPointer { rightPtr in
                            crossfader.process(
                                inputLeft: inputPtr.baseAddress!,
                                inputRight: inputPtr.baseAddress!,
                                leftOutput: leftPtr.baseAddress!,
                                rightOutput: rightPtr.baseAddress!,
                                frameCount: size
                            )
                        }
                    }
                }
                input.append(contentsOf: chunk)
                outputLeft.append(contentsOf: left)
                outputRight.append(contentsOf: right)
            }
        }
    }

    private func maximumStepDelta(_ samples: [Float]) -> Float {
        var maximum: Float = 0
        for index in 1..<samples.count {
            maximum = max(maximum, abs(samples[index] - samples[index - 1]))
        }
        return maximum
    }

    func testSwapProducesNoOutputDiscontinuity() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        let stateA = makeState(gain: 1)
        let stateB = makeState(gain: 0.5)

        crossfader.observe(stateA)
        driver.run(callbacks: 6)
        crossfader.observe(stateB)
        driver.run(callbacks: 8)

        // A hard swap steps by ~0.5 (half the sine amplitude); the sine itself
        // steps by at most 0.063 per sample at 480 Hz / 48 kHz.
        XCTAssertLessThan(maximumStepDelta(driver.outputLeft), 0.1)
        XCTAssertLessThan(maximumStepDelta(driver.outputRight), 0.1)
        XCTAssertTrue(driver.outputLeft.allSatisfy { $0.isFinite })
    }

    func testFadeCompletesOnIncomingState() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        crossfader.observe(makeState(gain: 1))
        driver.run(callbacks: 6)
        crossfader.observe(makeState(gain: 0.5))
        driver.run(callbacks: 8)

        XCTAssertFalse(crossfader.isFadingForTesting)
        let tail = driver.outputLeft.suffix(512)
        let expected = driver.input.suffix(512).map { $0 * 0.5 }
        for (actual, want) in zip(tail, expected) {
            XCTAssertEqual(actual, want, accuracy: 1e-5)
        }
    }

    func testRetiredStateIsHandedToControlThreadAndDrained() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        crossfader.observe(makeState(gain: 1))
        driver.run(callbacks: 6)
        XCTAssertEqual(crossfader.retiredStateCountForTesting, 0) // faded in from passthrough

        crossfader.observe(makeState(gain: 0.5))
        driver.run(callbacks: 8)

        XCTAssertEqual(crossfader.retiredStateCountForTesting, 1)
        crossfader.drainRetiredStates()
        XCTAssertEqual(crossfader.retiredStateCountForTesting, 0)
    }

    func testRapidDoubleSwitchSettlesOnNewestState() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        crossfader.observe(makeState(gain: 1))
        driver.run(callbacks: 6)

        crossfader.observe(makeState(gain: 0.5))
        driver.run(callbacks: 1) // still priming
        crossfader.observe(makeState(gain: 0.25))
        driver.run(callbacks: 12)

        XCTAssertFalse(crossfader.isFadingForTesting)
        XCTAssertLessThan(maximumStepDelta(driver.outputLeft), 0.1)
        let tail = driver.outputLeft.suffix(512)
        let expected = driver.input.suffix(512).map { $0 * 0.25 }
        for (actual, want) in zip(tail, expected) {
            XCTAssertEqual(actual, want, accuracy: 1e-5)
        }
    }

    func testRemovingPresetFadesToPassthrough() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        crossfader.observe(makeState(gain: 0.5))
        driver.run(callbacks: 6)

        crossfader.observe(nil)
        XCTAssertTrue(crossfader.isRenderingSpatialAudio)
        driver.run(callbacks: 4)

        XCTAssertFalse(crossfader.isRenderingSpatialAudio)
        XCTAssertLessThan(maximumStepDelta(driver.outputLeft), 0.1)
        let tail = Array(driver.outputLeft.suffix(512))
        let expected = Array(driver.input.suffix(512))
        for (actual, want) in zip(tail, expected) {
            XCTAssertEqual(actual, want, accuracy: 1e-5)
        }
    }

    func testResetDropsStateWithoutFadingAndRetiresIt() {
        let crossfader = makeCrossfader()
        let driver = Driver(crossfader)
        let state = makeState(gain: 0.5)
        crossfader.observe(state)
        driver.run(callbacks: 6)

        crossfader.requestReset()
        driver.run(callbacks: 1)

        XCTAssertFalse(crossfader.isFadingForTesting)
        XCTAssertNil(crossfader.activeStateForTesting)
        XCTAssertEqual(crossfader.retiredStateCountForTesting, 1)
        let tail = Array(driver.outputLeft.suffix(512))
        let expected = Array(driver.input.suffix(512))
        for (actual, want) in zip(tail, expected) {
            XCTAssertEqual(actual, want, accuracy: 1e-5)
        }
    }
}
