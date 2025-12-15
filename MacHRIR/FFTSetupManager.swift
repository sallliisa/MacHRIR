//
//  FFTSetupManager.swift
//  MacHRIR
//
//  Manages shared FFTSetup instances to reduce memory overhead
//

import Foundation
import Accelerate

/// Thread-safe manager for shared FFTSetup instances
/// Reduces memory usage by sharing FFT setup structures across multiple ConvolutionEngines
class FFTSetupManager {
    
    // MARK: - Singleton
    
    static let shared = FFTSetupManager()
    
    // MARK: - Private Properties
    
    private var setupCache: [vDSP_Length: FFTSetup] = [:]
    private let lock = NSLock()
    
    private init() {}
    
    deinit {
        lock.lock()
        defer { lock.unlock() }
        
        for (_, setup) in setupCache {
            vDSP_destroy_fftsetup(setup)
        }
        setupCache.removeAll()
    }
    
    // MARK: - Public Methods
    
    /// Get or create a shared FFTSetup for the given log2n size
    /// - Parameter log2n: log2 of the FFT size
    /// - Returns: Shared FFTSetup instance, or nil if creation failed
    func getSetup(log2n: vDSP_Length) -> FFTSetup? {
        lock.lock()
        defer { lock.unlock() }
        
        // Return cached setup if available
        if let existingSetup = setupCache[log2n] {
            return existingSetup
        }
        
        // Create new setup
        guard let newSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            Logger.log("[FFTSetupManager] Failed to create FFT setup for log2n=\(log2n)")
            return nil
        }
        
        setupCache[log2n] = newSetup
        Logger.log("[FFTSetupManager] Created shared FFT setup for log2n=\(log2n) (size=\(1 << log2n))")
        
        return newSetup
    }
    
    /// Get cache statistics for debugging
    func getCacheStats() -> (count: Int, sizes: [Int]) {
        lock.lock()
        defer { lock.unlock() }
        
        let sizes = setupCache.keys.map { 1 << $0 }.sorted()
        return (setupCache.count, sizes)
    }
}
