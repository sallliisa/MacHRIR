import Foundation
import XCTest
@testable import Airwave

final class ParametricEqualizerProcessorTests: XCTestCase {
    func testGoldenCoefficientsMatchEqualizerAPOQEquationsAtSupportedSampleRates() throws {
        let cases: [(EqualizerFilterType, Double, Double, Double, Double, [Double])] = [
            (.peaking, 6, 1_000, 0.707, 44_100, [
                1.066059044304402, -1.848333006078428, 0.801193953602049,
                -1.848333006078428, 0.867252997906451
            ]),
            (.peaking, 6, 1_000, 0.707, 48_000, [
                1.061051079218484, -1.861255902473044, 0.816265527066576,
                -1.861255902473044, 0.877316606285061
            ]),
            (.peaking, 6, 1_000, 0.707, 96_000, [
                1.031556835547465, -1.932439513787206, 0.905029057291346,
                -1.932439513787206, 0.936585892838811
            ]),
            (.lowShelf, 4, 250, 0.8, 44_100, [
                1.005181131876713, -1.959818685223499, 0.956203632826288,
                -1.960107660288434, 0.961095789638066
            ]),
            (.lowShelf, 4, 250, 0.8, 48_000, [
                1.004757001839771, -1.963119655421762, 0.959686684133658,
                -1.963363967297150, 0.964199374098040
            ]),
            (.lowShelf, 4, 250, 0.8, 96_000, [
                1.002369381638864, -1.981663998355715, 0.979628621963737,
                -1.981725629447349, 0.981936372510967
            ]),
            (.highShelf, -5, 6_000, 0.8, 44_100, [
                0.659738038304301, -0.493423574823573, 0.211192786614601,
                -1.024348043481364, 0.401855293576692
            ]),
            (.highShelf, -5, 6_000, 0.8, 48_000, [
                0.651371052565336, -0.549995923363222, 0.224963798271964,
                -1.105037860095793, 0.431376787569872
            ]),
            (.highShelf, -5, 6_000, 0.8, 96_000, [
                0.605207918981539, -0.855707120775878, 0.345827037126246,
                -1.558782199620635, 0.654110034952544
            ])
        ]

        for (type, gain, frequency, q, sampleRate, expected) in cases {
            let actual = try BiquadCoefficientBuilder.make(
                type: type,
                gainDB: gain,
                frequencyHz: frequency,
                q: q,
                sampleRate: sampleRate
            )
            XCTAssertEqual(actual.b0, expected[0], accuracy: 1e-12)
            XCTAssertEqual(actual.b1, expected[1], accuracy: 1e-12)
            XCTAssertEqual(actual.b2, expected[2], accuracy: 1e-12)
            XCTAssertEqual(actual.a1, expected[3], accuracy: 1e-12)
            XCTAssertEqual(actual.a2, expected[4], accuracy: 1e-12)
        }
    }

    func testGoldenMagnitudeChecksCoverDCCenterAndHighFrequencyResponse() throws {
        let cases: [(EqualizerFilterType, Double, Double, Double, Double, [Double])] = [
            (.peaking, 6, 1_000, 0.707, 48_000, [0, 6, 0]),
            (.lowShelf, 4, 250, 0.8, 48_000, [4, 2, 0]),
            (.highShelf, -5, 6_000, 0.8, 48_000, [0, -2.5, -5])
        ]

        for (type, gain, frequency, q, sampleRate, expected) in cases {
            let coefficients = try BiquadCoefficientBuilder.make(
                type: type,
                gainDB: gain,
                frequencyHz: frequency,
                q: q,
                sampleRate: sampleRate
            )
            for (index, testFrequency) in [0, frequency, sampleRate / 2 - 1].enumerated() {
                XCTAssertEqual(
                    magnitudeDB(coefficients, frequencyHz: testFrequency, sampleRate: sampleRate),
                    expected[index],
                    accuracy: 1e-9
                )
            }
        }
    }

    func testUnityAndPreampOnlyStatesProcessStereoWithoutCrossTalk() throws {
        let unity = try ParametricEqualizerProcessor.prepare(definition: nil, sampleRate: 48_000)
        let preampDefinition = EqualizerDefinition(preampDB: 6, filters: [])
        let preamp = try ParametricEqualizerProcessor.prepare(
            definition: preampDefinition,
            sampleRate: 48_000
        )

        let inputLeft: [Float] = [0.25, -0.5, 1]
        let inputRight: [Float] = [-0.75, 0.5, 0.125]
        let unityOutput = process(unity, left: inputLeft, right: inputRight)
        let preampOutput = process(preamp, left: inputLeft, right: inputRight)
        let gain = Float(pow(10.0, 6.0 / 20.0))

        XCTAssertEqual(unityOutput.left, inputLeft)
        XCTAssertEqual(unityOutput.right, inputRight)
        XCTAssertEqual(preampOutput.left[0], inputLeft[0] * gain, accuracy: 1e-6)
        XCTAssertEqual(preampOutput.right[0], inputRight[0] * gain, accuracy: 1e-6)
        XCTAssertEqual(preampOutput.left[2], inputLeft[2] * gain, accuracy: 1e-6)
        XCTAssertEqual(preampOutput.right[2], inputRight[2] * gain, accuracy: 1e-6)
    }

    func testKnownImpulseResponsePreservesCascadeOrder() throws {
        let filters = [
            makeFilter(.peaking, frequency: 1_000, gain: 6, q: 0.707),
            makeFilter(.peaking, frequency: 3_000, gain: -3, q: 1.1)
        ]
        let state = try ParametricEqualizerProcessor.prepare(
            definition: EqualizerDefinition(filters: filters),
            sampleRate: 48_000
        )

        let result = process(state, left: [1, 0, 0, 0, 0, 0], right: [0, 0, 0, 0, 0, 0])
        let expected: [Float] = [
            1.007962105198731,
            0.026656172367575,
            0.046848317472827,
            0.062845911221200,
            0.072328817552935,
            0.074696369241889
        ]
        XCTAssertEqual(result.left.count, expected.count)
        for (actual, expected) in zip(result.left, expected) {
            XCTAssertEqual(actual, expected, accuracy: 1e-6)
        }
        XCTAssertTrue(result.right.allSatisfy { $0 == 0 })
    }

    func testDisabledFiltersAreExcludedAndSubnormalStateIsFlushed() throws {
        let disabled = makeFilter(.peaking, frequency: 1_000, gain: 12, q: 0.7, enabled: false)
        let state = try ParametricEqualizerProcessor.prepare(
            definition: EqualizerDefinition(filters: [disabled]),
            sampleRate: 48_000
        )
        let result = process(state, left: [1, 0], right: [1, 0])
        XCTAssertEqual(result.left, [1, 0])
        XCTAssertEqual(result.right, [1, 0])

        let active = try ParametricEqualizerProcessor.prepare(
            definition: EqualizerDefinition(filters: [makeFilter(.peaking, frequency: 1_000, gain: 6, q: 0.707)]),
            sampleRate: 48_000
        )
        let subnormal = process(active, left: [Float.leastNonzeroMagnitude, 0], right: [0, 0])
        XCTAssertNotEqual(subnormal.left[0], 0)
        XCTAssertEqual(subnormal.left[1], 0)
    }

    func testInPlaceProcessingPreservesCanariesAtAllCallbackSizes() throws {
        let state = try ParametricEqualizerProcessor.prepare(
            definition: EqualizerDefinition(filters: [makeFilter(.highShelf, frequency: 6_000, gain: -5, q: 0.8)]),
            sampleRate: 48_000
        )
        let size = 4_096
        let canary: Float = 12_345
        let left = UnsafeMutablePointer<Float>.allocate(capacity: size + 2)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: size + 2)
        defer {
            left.deinitialize(count: size + 2)
            right.deinitialize(count: size + 2)
            left.deallocate()
            right.deallocate()
        }
        left.initialize(repeating: canary, count: size + 2)
        right.initialize(repeating: canary, count: size + 2)
        for index in 0..<size {
            left[index + 1] = Float(index % 17) / 17
            right[index + 1] = -Float(index % 13) / 13
        }

        state.process(
            inputLeft: UnsafePointer(left.advanced(by: 1)),
            inputRight: UnsafePointer(right.advanced(by: 1)),
            leftOutput: left.advanced(by: 1),
            rightOutput: right.advanced(by: 1),
            frameCount: size
        )

        XCTAssertEqual(left[0], canary)
        XCTAssertEqual(left[size + 1], canary)
        XCTAssertEqual(right[0], canary)
        XCTAssertEqual(right[size + 1], canary)
        XCTAssertTrue((0..<size).allSatisfy { left[$0 + 1].isFinite && right[$0 + 1].isFinite })
    }

    func testPreparationRejectsInvalidSampleRatesFrequenciesAndFilterCounts() {
        XCTAssertThrowsError(try ParametricEqualizerProcessor.prepare(definition: nil, sampleRate: 0))
        XCTAssertThrowsError(try ParametricEqualizerProcessor.prepare(
            definition: EqualizerDefinition(filters: [makeFilter(.peaking, frequency: 24_000, gain: 1, q: 1)]),
            sampleRate: 48_000
        ))
        XCTAssertThrowsError(try ParametricEqualizerProcessor.prepare(
            definition: EqualizerDefinition(filters: [makeFilter(.peaking, frequency: 1_000, gain: 1, q: 0)]),
            sampleRate: 48_000
        ))

        let filters = (0..<65).map { index in
            makeFilter(.peaking, frequency: Double(500 + index), gain: 1, q: 1)
        }
        XCTAssertThrowsError(try ParametricEqualizerProcessor.prepare(
            definition: EqualizerDefinition(filters: filters),
            sampleRate: 48_000
        ))
    }

    func testCrossfadeUsesExactTwentyMillisecondRampAcrossCallbackBoundaries() throws {
        for sampleRate in [44_100.0, 48_000.0, 96_000.0] {
            let processor = try ParametricEqualizerProcessor(sampleRate: sampleRate, maxFramesPerCallback: 4_096)
            let gain = Float(pow(10.0, 6.0 / 20.0))
            try processor.setTarget(definition: EqualizerDefinition(preampDB: 6))
            let length = max(1, Int((sampleRate * 0.020).rounded()))
            let firstHalf = max(1, length / 2)

            let first = process(processor, frameCount: firstHalf, leftValue: 1, rightValue: 1)
            let second = process(processor, frameCount: length - firstHalf, leftValue: 1, rightValue: 1)

            XCTAssertEqual(first.left[0], 1 + (gain - 1) / Float(length), accuracy: 1e-5)
            XCTAssertEqual(second.left.last!, gain, accuracy: 1e-5)
            XCTAssertEqual(second.right.last!, gain, accuracy: 1e-5)
            XCTAssertTrue((first.left + second.left).allSatisfy { $0.isFinite })
        }
    }

    func testTransitionsToAndFromUnityUseTheSameRamp() throws {
        let processor = try ParametricEqualizerProcessor(sampleRate: 48_000)
        try processor.setTarget(definition: EqualizerDefinition(preampDB: 6))
        let length = 960
        _ = process(processor, frameCount: length, leftValue: 1, rightValue: 1)

        try processor.setTarget(definition: nil)
        let result = process(processor, frameCount: length, leftValue: 1, rightValue: 1)
        let gain = Float(pow(10.0, 6.0 / 20.0))
        XCTAssertEqual(result.left[0], gain - (gain - 1) / Float(length), accuracy: 1e-5)
        XCTAssertEqual(result.left.last!, 1, accuracy: 1e-5)
        XCTAssertEqual(result.right.last!, 1, accuracy: 1e-5)
    }

    func testRapidPublicationQueuesNewestTargetUntilCurrentRampCompletes() throws {
        let processor = try ParametricEqualizerProcessor(sampleRate: 48_000)
        let positive = Float(pow(10.0, 6.0 / 20.0))
        let negative = Float(pow(10.0, -6.0 / 20.0))
        let length = 960

        try processor.setTarget(definition: EqualizerDefinition(preampDB: 6))
        _ = process(processor, frameCount: length / 2, leftValue: 1, rightValue: 1)
        try processor.setTarget(definition: EqualizerDefinition(preampDB: -6))
        let completesFirst = process(processor, frameCount: length / 2, leftValue: 1, rightValue: 1)
        XCTAssertEqual(completesFirst.left.last!, positive, accuracy: 1e-5)

        let startsNewest = process(processor, frameCount: length, leftValue: 1, rightValue: 1)
        XCTAssertEqual(startsNewest.left.last!, negative, accuracy: 1e-5)
        XCTAssertTrue(startsNewest.left.allSatisfy { $0.isFinite })
        XCTAssertTrue(startsNewest.right.allSatisfy { $0.isFinite })
    }

    func testRetirementPressureDefersAdditionalTransitionUntilControlDrain() throws {
        let processor = try ParametricEqualizerProcessor(sampleRate: 48_000)
        let length = 960
        let firstGain = Float(pow(10.0, 6.0 / 20.0))
        let secondGain = Float(pow(10.0, -6.0 / 20.0))
        let newestGain = Float(pow(10.0, 12.0 / 20.0))

        try processor.setTarget(definition: EqualizerDefinition(preampDB: 6))
        _ = process(processor, frameCount: length, leftValue: 1, rightValue: 1)

        try processor.setTarget(definition: EqualizerDefinition(preampDB: -6))
        let second = process(processor, frameCount: length, leftValue: 1, rightValue: 1)
        XCTAssertEqual(second.left.last!, secondGain, accuracy: 1e-5)

        try processor.setTarget(definition: EqualizerDefinition(preampDB: 12))
        let held = process(processor, frameCount: length, leftValue: 1, rightValue: 1)
        XCTAssertEqual(held.left.last!, secondGain, accuracy: 1e-5)

        processor.drainRetiredStates()
        let newest = process(processor, frameCount: length, leftValue: 1, rightValue: 1)
        XCTAssertEqual(newest.left.last!, newestGain, accuracy: 1e-5)
        XCTAssertEqual(second.left.first!, firstGain + (secondGain - firstGain) / Float(length), accuracy: 1e-5)
    }

    func testRenderCallbackKeepsPriorTargetWhenPublicationLockIsContended() throws {
        let processor = try ParametricEqualizerProcessor(sampleRate: 48_000)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            processor.withPublicationLockForTesting {
                entered.signal()
                _ = release.wait(timeout: .now() + 1)
            }
        }

        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let result = process(processor, frameCount: 128, leftValue: 1, rightValue: 2)
        release.signal()
        XCTAssertEqual(result.left, [Float](repeating: 1, count: 128))
        XCTAssertEqual(result.right, [Float](repeating: 2, count: 128))
    }

    func testResetClearsPublishedStateHistories() throws {
        let processor = try ParametricEqualizerProcessor(sampleRate: 48_000)
        let filter = makeFilter(.peaking, frequency: 1_000, gain: 6, q: 0.707)
        try processor.setTarget(definition: EqualizerDefinition(filters: [filter]))
        _ = process(processor, frameCount: 960, leftValue: 1, rightValue: 1)
        processor.reset()
        try processor.setTarget(definition: nil)
        _ = process(processor, frameCount: 960, leftValue: 1, rightValue: 1)
        let afterReset = process(processor, frameCount: 1, leftValue: 0, rightValue: 0)
        XCTAssertEqual(afterReset.left, [0])
        XCTAssertEqual(afterReset.right, [0])
    }

    func testTenFilterReferenceWorkloadStaysFiniteAcrossCallbackSizes() throws {
        let filters = (0..<10).map { index in
            makeFilter(
                index.isMultiple(of: 2) ? .peaking : .highShelf,
                frequency: Double(250 + index * 1_000),
                gain: Double(index % 3) - 1,
                q: 0.8
            )
        }
        let state = try ParametricEqualizerProcessor.prepare(
            definition: EqualizerDefinition(preampDB: -3, filters: filters),
            sampleRate: 48_000
        )

        measure {
            for callbackSize in [128, 512, 1_024] {
                var processed = 0
                let input = [Float](repeating: 0.25, count: callbackSize)
                var left = [Float](repeating: 0, count: callbackSize)
                var right = [Float](repeating: 0, count: callbackSize)
                while processed < 48_000 * 10 {
                    input.withUnsafeBufferPointer { inputPointer in
                        left.withUnsafeMutableBufferPointer { leftPointer in
                            right.withUnsafeMutableBufferPointer { rightPointer in
                                state.process(
                                    inputLeft: inputPointer.baseAddress!,
                                    inputRight: inputPointer.baseAddress!,
                                    leftOutput: leftPointer.baseAddress!,
                                    rightOutput: rightPointer.baseAddress!,
                                    frameCount: callbackSize
                                )
                            }
                        }
                    }
                    processed += callbackSize
                }
                XCTAssertTrue(left.allSatisfy { $0.isFinite })
                XCTAssertTrue(right.allSatisfy { $0.isFinite })
            }
        }
    }

    func testReferenceFixtureBuildsTenFilterStateAndMatchesRepresentativeCurve() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CCA CRA ParametricEq.txt")
        let definition = try EqualizerAPOParser.parse(
            data: Data(contentsOf: fixtureURL),
            filename: fixtureURL.lastPathComponent
        )
        XCTAssertEqual(definition.filters.filter(\.isEnabled).count, 10)

        let sampleRate = 48_000.0
        let frameCount = 48_000
        let discardCount = 24_000
        let expected: [(Double, Double)] = [
            (20, -5.3379478445),
            (1_000, -0.9694887656),
            (10_000, -4.2646888095)
        ]

        for (frequency, expectedDB) in expected {
            let state = try ParametricEqualizerProcessor.prepare(
                definition: definition,
                sampleRate: sampleRate
            )
            let input = (0..<frameCount).map { index in
                Float(sin(2 * Double.pi * frequency * Double(index) / sampleRate))
            }
            let result = process(state, left: input, right: input)
            let inputRMS = sqrt(input[discardCount...].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frameCount - discardCount))
            let outputRMS = sqrt(result.left[discardCount...].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frameCount - discardCount))
            let measuredDB = 20 * log10(outputRMS / inputRMS)
            XCTAssertTrue(result.left.allSatisfy { $0.isFinite })
            XCTAssertTrue(result.right.allSatisfy { $0.isFinite })
            XCTAssertEqual(measuredDB, expectedDB, accuracy: 0.03, "frequency \(frequency) Hz")
        }
    }

    func testCrossfadeToNewTargetStaysContinuousAndSettlesOnTheNewCurve() throws {
        let sampleRate = 48_000.0
        let first = EqualizerDefinition(filters: [makeFilter(.peaking, frequency: 1_000, gain: 6, q: 0.707)])
        let second = EqualizerDefinition(filters: [
            makeFilter(.peaking, frequency: 3_000, gain: -6, q: 1.1),
            makeFilter(.lowShelf, frequency: 120, gain: 4, q: 0.7)
        ])

        let processor = try ParametricEqualizerProcessor(sampleRate: sampleRate)
        try processor.setTarget(definition: first)
        var output: [Float] = []
        // Warm up on the first curve, then swap mid-stream.
        for _ in 0..<4 { output.append(contentsOf: sine(processor, frames: 256, from: output.count)) }
        try processor.setTarget(definition: second)
        for _ in 0..<12 { output.append(contentsOf: sine(processor, frames: 256, from: output.count)) }

        // A 480 Hz sine at 48 kHz steps by at most 0.063 per sample; a hard
        // state swap mid-fade would jump far beyond that.
        var maximumDelta: Float = 0
        for index in 1..<output.count {
            maximumDelta = max(maximumDelta, abs(output[index] - output[index - 1]))
        }
        XCTAssertLessThan(maximumDelta, 0.2)

        let settled = try ParametricEqualizerProcessor(sampleRate: sampleRate)
        try settled.setTarget(definition: second)
        var reference: [Float] = []
        for _ in 0..<16 { reference.append(contentsOf: sine(settled, frames: 256, from: reference.count)) }

        // Both processors see the same input; after the fade they must agree.
        for index in (output.count - 512)..<output.count {
            XCTAssertEqual(output[index], reference[index], accuracy: 1e-4)
        }
    }

    /// Feeds a continuous 480 Hz sine and returns the left output.
    private func sine(
        _ processor: ParametricEqualizerProcessor,
        frames: Int,
        from startFrame: Int
    ) -> [Float] {
        let input = (0..<frames).map { index in
            Float(sin(2 * Double.pi * 480 * Double(startFrame + index) / 48_000))
        }
        var outputLeft = [Float](repeating: .nan, count: frames)
        var outputRight = [Float](repeating: .nan, count: frames)
        input.withUnsafeBufferPointer { inputPointer in
            outputLeft.withUnsafeMutableBufferPointer { leftPointer in
                outputRight.withUnsafeMutableBufferPointer { rightPointer in
                    processor.process(
                        inputLeft: inputPointer.baseAddress!,
                        inputRight: inputPointer.baseAddress!,
                        leftOutput: leftPointer.baseAddress!,
                        rightOutput: rightPointer.baseAddress!,
                        frameCount: frames
                    )
                }
            }
        }
        return outputLeft
    }

    private func makeFilter(
        _ type: EqualizerFilterType,
        frequency: Double,
        gain: Double,
        q: Double,
        enabled: Bool = true
    ) -> EqualizerFilter {
        EqualizerFilter(
            sourceLine: 1,
            sourceNumber: nil,
            isEnabled: enabled,
            type: type,
            frequencyHz: frequency,
            gainDB: gain,
            q: q
        )
    }

    private func process(
        _ state: ParametricEqualizerState,
        left: [Float],
        right: [Float]
    ) -> (left: [Float], right: [Float]) {
        var outputLeft = [Float](repeating: .nan, count: left.count)
        var outputRight = [Float](repeating: .nan, count: left.count)
        left.withUnsafeBufferPointer { leftPointer in
            right.withUnsafeBufferPointer { rightPointer in
                outputLeft.withUnsafeMutableBufferPointer { leftOutputPointer in
                    outputRight.withUnsafeMutableBufferPointer { rightOutputPointer in
                        state.process(
                            inputLeft: leftPointer.baseAddress!,
                            inputRight: rightPointer.baseAddress!,
                            leftOutput: leftOutputPointer.baseAddress!,
                            rightOutput: rightOutputPointer.baseAddress!,
                            frameCount: left.count
                        )
                    }
                }
            }
        }
        return (outputLeft, outputRight)
    }

    private func process(
        _ processor: ParametricEqualizerProcessor,
        frameCount: Int,
        leftValue: Float,
        rightValue: Float
    ) -> (left: [Float], right: [Float]) {
        let left = [Float](repeating: leftValue, count: frameCount)
        let right = [Float](repeating: rightValue, count: frameCount)
        var outputLeft = [Float](repeating: .nan, count: frameCount)
        var outputRight = [Float](repeating: .nan, count: frameCount)
        left.withUnsafeBufferPointer { leftPointer in
            right.withUnsafeBufferPointer { rightPointer in
                outputLeft.withUnsafeMutableBufferPointer { leftOutputPointer in
                    outputRight.withUnsafeMutableBufferPointer { rightOutputPointer in
                        processor.process(
                            inputLeft: leftPointer.baseAddress!,
                            inputRight: rightPointer.baseAddress!,
                            leftOutput: leftOutputPointer.baseAddress!,
                            rightOutput: rightOutputPointer.baseAddress!,
                            frameCount: frameCount
                        )
                    }
                }
            }
        }
        return (outputLeft, outputRight)
    }

    private func magnitudeDB(
        _ coefficients: BiquadCoefficients,
        frequencyHz: Double,
        sampleRate: Double
    ) -> Double {
        let omega = 2 * Double.pi * frequencyHz / sampleRate
        let z = Complex(real: cos(omega), imaginary: sin(omega))
        let numerator = Complex(real: coefficients.b0)
            + Complex(real: coefficients.b1) / z
            + Complex(real: coefficients.b2) / (z * z)
        let denominator = Complex(real: 1)
            + Complex(real: coefficients.a1) / z
            + Complex(real: coefficients.a2) / (z * z)
        return 20 * log10((numerator / denominator).magnitude)
    }
}

private struct Complex {
    let real: Double
    let imaginary: Double

    init(real: Double, imaginary: Double = 0) {
        self.real = real
        self.imaginary = imaginary
    }

    var magnitude: Double { hypot(real, imaginary) }

    static func + (lhs: Complex, rhs: Complex) -> Complex {
        Complex(real: lhs.real + rhs.real, imaginary: lhs.imaginary + rhs.imaginary)
    }

    static func * (lhs: Complex, rhs: Complex) -> Complex {
        Complex(
            real: lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
            imaginary: lhs.real * rhs.imaginary + lhs.imaginary * rhs.real
        )
    }

    static func / (lhs: Complex, rhs: Complex) -> Complex {
        let denominator = rhs.real * rhs.real + rhs.imaginary * rhs.imaginary
        return Complex(
            real: (lhs.real * rhs.real + lhs.imaginary * rhs.imaginary) / denominator,
            imaginary: (lhs.imaginary * rhs.real - lhs.real * rhs.imaginary) / denominator
        )
    }
}
