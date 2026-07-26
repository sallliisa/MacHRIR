import Accelerate
import Foundation
import os

nonisolated final class ParametricEqualizerState {
    static let maximumFilterCount = 64
    let sampleRate: Double
    let filterCount: Int
    let preampLinear: Double

    /// nil when there are no filters; that state only applies the preamp.
    private let setup: vDSP_biquadm_Setup?
    private var preampGain: Float
    private let inputPointers: UnsafeMutablePointer<UnsafePointer<Float>>
    private let outputPointers: UnsafeMutablePointer<UnsafeMutablePointer<Float>>

    init(
        sampleRate: Double,
        preampDB: Double,
        coefficients: [BiquadCoefficients]
    ) {
        self.sampleRate = sampleRate
        self.filterCount = coefficients.count
        self.preampLinear = pow(10, preampDB / 20)
        self.preampGain = Float(preampLinear)
        self.inputPointers = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: 2)
        self.outputPointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(capacity: 2)

        guard !coefficients.isEmpty else {
            self.setup = nil
            return
        }

        // Both channels run the same cascade. vDSP lays coefficients out
        // section-major: all channels of section 0, then section 1, and so on.
        // The preamp folds into the first section's feed-forward terms, saving a
        // separate gain pass on the render thread.
        var flattened = [Double]()
        flattened.reserveCapacity(2 * coefficients.count * 5)
        for (index, coefficient) in coefficients.enumerated() {
            let gain = index == 0 ? preampLinear : 1
            for _ in 0..<2 {
                flattened.append(coefficient.b0 * gain)
                flattened.append(coefficient.b1 * gain)
                flattened.append(coefficient.b2 * gain)
                flattened.append(coefficient.a1)
                flattened.append(coefficient.a2)
            }
        }
        self.setup = flattened.withUnsafeBufferPointer { pointer in
            vDSP_biquadm_CreateSetup(
                pointer.baseAddress!,
                vDSP_Length(coefficients.count),  // sections
                2                                 // channels
            )
        }
        if setup != nil { self.preampGain = 1 }
    }

    deinit {
        if let setup { vDSP_biquadm_DestroySetup(setup) }
        inputPointers.deallocate()
        outputPointers.deallocate()
    }

    func reset() {
        guard let setup else { return }
        vDSP_biquadm_ResetState(setup)
    }

    // BEGIN REALTIME CALLBACK
    @inline(__always)
    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>?,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }

        // Mono input feeds both channels. Copy it into the right output first so
        // each channel filters in place and channel 0 can never overwrite the
        // buffer channel 1 still has to read.
        let right: UnsafePointer<Float>
        if let inputRight {
            right = inputRight
        } else {
            memcpy(rightOutput, inputLeft, frameCount * MemoryLayout<Float>.size)
            right = UnsafePointer(rightOutput)
        }

        guard let setup else {
            vDSP_vsmul(inputLeft, 1, &preampGain, leftOutput, 1, vDSP_Length(frameCount))
            vDSP_vsmul(right, 1, &preampGain, rightOutput, 1, vDSP_Length(frameCount))
            return
        }

        inputPointers.initialize(to: inputLeft)
        inputPointers.advanced(by: 1).initialize(to: right)
        outputPointers.initialize(to: leftOutput)
        outputPointers.advanced(by: 1).initialize(to: rightOutput)
        vDSP_biquadm(
            setup,
            inputPointers, 1,
            outputPointers, 1,
            vDSP_Length(frameCount)
        )
    }
    // END REALTIME CALLBACK
}

nonisolated enum ParametricEqualizerPreparationError: Error, Equatable, LocalizedError {
    case invalidSampleRate
    case nonFinitePreamp
    case tooManyFilters(Int)
    case invalidFilter(index: Int, error: BiquadCoefficientError)

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate:
            return "Sample rate must be finite and positive."
        case .nonFinitePreamp:
            return "Preamp must produce a finite linear gain."
        case .tooManyFilters(let count):
            return "Equalizer supports at most \(ParametricEqualizerState.maximumFilterCount) filters; received \(count)."
        case .invalidFilter(let index, let error):
            return "Filter \(index + 1) is invalid: \(error.localizedDescription)"
        }
    }
}

/// Fixed-storage stereo equalizer with non-blocking target publication and bounded crossfades.
nonisolated final class ParametricEqualizerProcessor {
    static let crossfadeDurationSeconds = 0.020
    static let maximumCallbackFrames = 4_096

    let sampleRate: Double
    let maxFramesPerCallback: Int

    private let unityState: ParametricEqualizerState
    private let targetLock = OSAllocatedUnfairLock<ParametricEqualizerState?>(initialState: nil)
    private let retirementLock = OSAllocatedUnfairLock<ParametricEqualizerState?>(initialState: nil)
    private let resetLock = OSAllocatedUnfairLock<Bool>(initialState: false)
    private var audioThreadTarget: ParametricEqualizerState?
    private var activeState: ParametricEqualizerState
    private var transitionFrom: ParametricEqualizerState?
    private var transitionTo: ParametricEqualizerState?
    private var pendingTarget: ParametricEqualizerState?
    private var observedTarget: ParametricEqualizerState?
    private var transitionFrame = 0
    private let transitionLength: Int
    private let oldScratch: UnsafeMutablePointer<Float>
    private let oldRightScratch: UnsafeMutablePointer<Float>
    private let newScratch: UnsafeMutablePointer<Float>
    private let newRightScratch: UnsafeMutablePointer<Float>
    // Render-thread-only hold used when the control-side retirement slot is full.
    // A pending transition waits until the control side drains the slot.
    private var pendingRetirement: ParametricEqualizerState?

    init(sampleRate: Double, maxFramesPerCallback: Int = 4_096) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw ParametricEqualizerPreparationError.invalidSampleRate
        }
        guard maxFramesPerCallback > 0, maxFramesPerCallback <= Self.maximumCallbackFrames else {
            throw ParametricEqualizerPreparationError.tooManyFilters(maxFramesPerCallback)
        }

        self.sampleRate = sampleRate
        self.maxFramesPerCallback = maxFramesPerCallback
        self.unityState = try Self.prepare(definition: nil, sampleRate: sampleRate)
        self.activeState = unityState
        self.transitionLength = max(1, Int((sampleRate * Self.crossfadeDurationSeconds).rounded()))
        self.oldScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        self.oldRightScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        self.newScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
        self.newRightScratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFramesPerCallback)
    }

    deinit {
        oldScratch.deallocate()
        oldRightScratch.deallocate()
        newScratch.deallocate()
        newRightScratch.deallocate()
    }

    static func prepare(
        definition: EqualizerDefinition?,
        sampleRate: Double
    ) throws -> ParametricEqualizerState {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw ParametricEqualizerPreparationError.invalidSampleRate
        }

        let preampDB = definition?.preampDB ?? 0
        guard preampDB.isFinite else {
            throw ParametricEqualizerPreparationError.nonFinitePreamp
        }
        let preampLinear = pow(10, preampDB / 20)
        guard preampLinear.isFinite else {
            throw ParametricEqualizerPreparationError.nonFinitePreamp
        }

        let enabledFilters = definition?.filters.filter(\.isEnabled) ?? []
        guard enabledFilters.count <= ParametricEqualizerState.maximumFilterCount else {
            throw ParametricEqualizerPreparationError.tooManyFilters(enabledFilters.count)
        }

        var coefficients: [BiquadCoefficients] = []
        coefficients.reserveCapacity(enabledFilters.count)
        for (index, filter) in enabledFilters.enumerated() {
            do {
                coefficients.append(try BiquadCoefficientBuilder.make(
                    type: filter.type,
                    gainDB: filter.gainDB,
                    frequencyHz: filter.frequencyHz,
                    q: filter.q,
                    sampleRate: sampleRate
                ))
            } catch let error as BiquadCoefficientError {
                throw ParametricEqualizerPreparationError.invalidFilter(index: index, error: error)
            }
        }

        return ParametricEqualizerState(
            sampleRate: sampleRate,
            preampDB: preampDB,
            coefficients: coefficients
        )
    }

    func publish(_ state: ParametricEqualizerState) throws {
        guard state.sampleRate == sampleRate else {
            throw ParametricEqualizerPreparationError.invalidSampleRate
        }
        targetLock.withLock { target in
            target = state
        }
    }

    #if DEBUG
    func withPublicationLockForTesting(_ body: () -> Void) {
        targetLock.withLock { _ in
            body()
        }
    }
    #endif

    func setTarget(definition: EqualizerDefinition?) throws {
        try publish(Self.prepare(definition: definition, sampleRate: sampleRate))
    }

    func reset() {
        resetLock.withLock { requested in
            requested = true
        }
    }

    /// Releases states retired by the render thread. Call from the control thread.
    func drainRetiredStates() {
        retirementLock.withLock { retired in
            retired = nil
        }
    }

    // BEGIN REALTIME CALLBACK
    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>?,
        leftOutput: UnsafeMutablePointer<Float>,
        rightOutput: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        precondition(frameCount <= maxFramesPerCallback)
        observePublishedTarget()
        flushPendingRetirement()
        applyPendingReset()

        var offset = 0
        while offset < frameCount {
            guard let from = transitionFrom, let to = transitionTo else {
                activeState.process(
                    inputLeft: inputLeft.advanced(by: offset),
                    inputRight: inputRight?.advanced(by: offset),
                    leftOutput: leftOutput.advanced(by: offset),
                    rightOutput: rightOutput.advanced(by: offset),
                    frameCount: frameCount - offset
                )
                return
            }

            let remaining = transitionLength - transitionFrame
            let segment = min(remaining, frameCount - offset)
            from.process(
                inputLeft: inputLeft.advanced(by: offset),
                inputRight: inputRight?.advanced(by: offset),
                leftOutput: oldScratch,
                rightOutput: oldRightScratch,
                frameCount: segment
            )
            to.process(
                inputLeft: inputLeft.advanced(by: offset),
                inputRight: inputRight?.advanced(by: offset),
                leftOutput: newScratch,
                rightOutput: newRightScratch,
                frameCount: segment
            )

            for index in 0..<segment {
                let progress = Double(transitionFrame + index + 1) / Double(transitionLength)
                let inverse = 1 - progress
                leftOutput[offset + index] = Float(
                    Double(oldScratch[index]) * inverse + Double(newScratch[index]) * progress
                )
                rightOutput[offset + index] = Float(
                    Double(oldRightScratch[index]) * inverse + Double(newRightScratch[index]) * progress
                )
            }

            transitionFrame += segment
            offset += segment
            if transitionFrame == transitionLength {
                finishTransition()
            }
        }
    }
    // END REALTIME CALLBACK

    private func observePublishedTarget() {
        enum TargetRead {
            case value(ParametricEqualizerState?)
        }

        if let read = targetLock.withLockIfAvailable({ TargetRead.value($0) }),
           case .value(let published) = read,
           let published {
            audioThreadTarget = published
        }

        guard let target = audioThreadTarget, target !== observedTarget else { return }
        observedTarget = target
        if transitionTo != nil {
            if target !== transitionTo {
                pendingTarget = target
            }
        } else if pendingRetirement != nil {
            pendingTarget = target
        } else if target !== activeState {
            beginTransition(to: target)
        }
    }

    private func applyPendingReset() {
        guard let requested = resetLock.withLockIfAvailable({ requested in
            let value = requested
            requested = false
            return value
        }), requested else {
            return
        }
        activeState.reset()
        transitionFrom?.reset()
        transitionTo?.reset()
    }

    private func beginTransition(to target: ParametricEqualizerState) {
        guard target !== activeState else { return }
        transitionFrom = activeState
        transitionTo = target
        transitionFrame = 0
    }

    private func finishTransition() {
        guard let from = transitionFrom, let to = transitionTo else { return }
        activeState = to
        transitionFrom = nil
        transitionTo = nil
        transitionFrame = 0
        guard retire(from) else { return }

        if let pending = pendingTarget {
            pendingTarget = nil
            if pending !== activeState {
                beginTransition(to: pending)
            }
        }
    }

    @discardableResult
    private func retire(_ state: ParametricEqualizerState) -> Bool {
        guard pendingRetirement == nil else { return false }
        if retirementLock.withLockIfAvailable({ retired in
            guard retired == nil else { return false }
            retired = state
            return true
        }) == true {
            return true
        }
        pendingRetirement = state
        return false
    }

    private func flushPendingRetirement() {
        guard let pendingRetirement else { return }
        guard retirementLock.withLockIfAvailable({ retired in
            guard retired == nil else { return false }
            retired = pendingRetirement
            return true
        }) == true else {
            return
        }
        self.pendingRetirement = nil
        if let pending = pendingTarget {
            pendingTarget = nil
            if pending !== activeState {
                beginTransition(to: pending)
            }
        }
    }
}
