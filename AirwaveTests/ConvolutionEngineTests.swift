import XCTest
@testable import Airwave

final class ConvolutionEngineTests: XCTestCase {
    private let blockSize = 8

    private func makeEngine() -> StereoConvolutionEngine {
        let impulse = [Float](arrayLiteral: 1, 0, 0, 0, 0, 0, 0, 0)
        return try! XCTUnwrap(StereoConvolutionEngine(
            leftEarHRIR: impulse,
            rightEarHRIR: impulse,
            blockSize: blockSize
        ))
    }

    /// Drives both ears and returns the left-ear output.
    private func process(_ engine: StereoConvolutionEngine, input: [Float]) -> [Float] {
        var left = [Float](repeating: 0, count: blockSize)
        var right = [Float](repeating: 0, count: blockSize)
        input.withUnsafeBufferPointer { inputPtr in
            left.withUnsafeMutableBufferPointer { leftPtr in
                right.withUnsafeMutableBufferPointer { rightPtr in
                    engine.process(
                        input: inputPtr.baseAddress!,
                        outputLeft: leftPtr.baseAddress!,
                        outputRight: rightPtr.baseAddress!
                    )
                }
            }
        }
        XCTAssertEqual(left, right, "both ears share one impulse response")
        return left
    }

    func testImpulsePreservesSampleOrder() {
        let engine = makeEngine()
        let input: [Float] = [0.25, -0.5, 1, 0.75, -1, 0.125, 0.5, -0.25]

        let output = process(engine, input: input)

        XCTAssertTrue(zip(output, input).allSatisfy { abs($0.0 - $0.1) < 0.0001 })
    }

    func testResetClearsOverlapAndFrequencyHistory() {
        let engine = makeEngine()
        var input = [Float](repeating: 0, count: blockSize)
        input[blockSize - 1] = 1
        _ = process(engine, input: input)

        engine.reset()
        input = [Float](repeating: 0, count: blockSize)
        let output = process(engine, input: input)

        XCTAssertTrue(output.allSatisfy { abs($0) < 0.0001 })
    }

    func testMultipleBlocksRemainFinite() {
        let engine = makeEngine()
        var input = (0..<blockSize).map { Float($0) / 7 }

        for _ in 0..<64 {
            let output = process(engine, input: input)
            XCTAssertTrue(output.allSatisfy { $0.isFinite })
            input = input.map { -$0 * 0.97 + 0.01 }
        }
    }

    func testIdenticalInputAfterResetProducesIdenticalOutput() {
        let engine = makeEngine()
        let input = Array([Float](stride(from: -0.75, through: 0.75, by: 0.2)).prefix(blockSize))

        let first = process(engine, input: input)
        engine.reset()
        let second = process(engine, input: input)

        XCTAssertTrue(zip(first, second).allSatisfy { abs($0.0 - $0.1) < 0.0001 })
    }
}

/// Golden-output guard for the convolution refactor: partitioned convolution
/// must match a direct time-domain reference, including a non-power-of-2
/// partition count (1200 taps at block 512 = 3 partitions).
final class ConvolutionCharacterizationTests: XCTestCase {
    private let blockSize = 512
    private let blocks = 8

    func testPartitionedConvolutionMatchesDirectConvolutionForBothEars() {
        let leftIR = Self.impulseResponse(taps: 1_200, seed: 7)
        let rightIR = Self.impulseResponse(taps: 1_200, seed: 11)
        let input = Self.noise(count: blockSize * blocks, seed: 3)

        let (left, right) = Self.render(input: input, leftIR: leftIR, rightIR: rightIR, blockSize: blockSize)
        let expectedLeft = Self.directConvolution(input: input, impulseResponse: leftIR)
        let expectedRight = Self.directConvolution(input: input, impulseResponse: rightIR)

        XCTAssertEqual(left.count, input.count)
        XCTAssertLessThan(Self.maximumError(left, expectedLeft), 1e-4)
        XCTAssertLessThan(Self.maximumError(right, expectedRight), 1e-4)
    }

    // MARK: - Helpers

    /// Runs the production engine block by block. Updated alongside the engine API.
    private static func render(
        input: [Float],
        leftIR: [Float],
        rightIR: [Float],
        blockSize: Int
    ) -> ([Float], [Float]) {
        let engine = StereoConvolutionEngine(
            leftEarHRIR: leftIR,
            rightEarHRIR: rightIR,
            blockSize: blockSize
        )!
        var left = [Float](repeating: 0, count: input.count)
        var right = [Float](repeating: 0, count: input.count)
        input.withUnsafeBufferPointer { inputPtr in
            left.withUnsafeMutableBufferPointer { leftPtr in
                right.withUnsafeMutableBufferPointer { rightPtr in
                    for block in stride(from: 0, to: input.count, by: blockSize) {
                        engine.process(
                            input: inputPtr.baseAddress!.advanced(by: block),
                            outputLeft: leftPtr.baseAddress!.advanced(by: block),
                            outputRight: rightPtr.baseAddress!.advanced(by: block)
                        )
                    }
                }
            }
        }
        return (left, right)
    }

    private static func directConvolution(input: [Float], impulseResponse: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        for n in 0..<input.count {
            var sum: Float = 0
            for k in 0..<min(impulseResponse.count, n + 1) {
                sum += impulseResponse[k] * input[n - k]
            }
            output[n] = sum
        }
        return output
    }

    private static func maximumError(_ actual: [Float], _ expected: [Float]) -> Float {
        zip(actual, expected).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    private static func impulseResponse(taps: Int, seed: UInt64) -> [Float] {
        var generator = LinearCongruential(seed: seed)
        return (0..<taps).map { index in
            let decay = 1 - Float(index) / Float(taps)
            return 0.02 * decay * generator.nextUnit()
        }
    }

    private static func noise(count: Int, seed: UInt64) -> [Float] {
        var generator = LinearCongruential(seed: seed)
        return (0..<count).map { _ in generator.nextUnit() }
    }

    private struct LinearCongruential {
        private var state: UInt64

        init(seed: UInt64) { state = seed &* 6_364_136_223_846_793_005 &+ 1 }

        mutating func nextUnit() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
        }
    }
}
