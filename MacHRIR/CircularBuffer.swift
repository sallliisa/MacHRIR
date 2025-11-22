//
//  CircularBuffer.swift
//  MacHRIR
//
//  Thread-safe circular buffer for decoupling input and output audio streams
//

import Foundation
import Darwin

/// Thread-safe ring buffer for audio data transfer between input and output callbacks
/// Thread-safe ring buffer for audio data transfer between input and output callbacks
/// Wraps C++ lock-free implementation
class CircularBuffer {
    private var cppBuffer: OpaquePointer?
    private let size: Int

    /// Initialize circular buffer with specified size
    /// - Parameter size: Buffer size in bytes (minimum 65536 recommended)
    init(size: Int) {
        self.size = size
        self.cppBuffer = circular_buffer_create(size)
        
        guard cppBuffer != nil else {
            fatalError("Failed to create C++ circular buffer")
        }
    }

    deinit {
        if let buffer = cppBuffer {
            circular_buffer_destroy(buffer)
        }
    }

    /// Write data to the circular buffer
    /// - Parameters:
    ///   - data: Pointer to source data
    ///   - size: Number of bytes to write
    /// - Returns: Number of bytes actually written
    @discardableResult
    func write(data: UnsafeRawPointer, size: Int) -> Int {
        guard let buffer = cppBuffer else { return 0 }
        return circular_buffer_write(buffer, data, size)
    }

    /// Read data from the circular buffer
    /// - Parameters:
    ///   - data: Pointer to destination buffer
    ///   - size: Number of bytes to read
    /// - Returns: Number of bytes actually read
    @discardableResult
    func read(into data: UnsafeMutableRawPointer, size: Int) -> Int {
        guard let buffer = cppBuffer else { return 0 }
        return circular_buffer_read(buffer, data, size)
    }

    /// Reset buffer to empty state
    func reset() {
        guard let buffer = cppBuffer else { return }
        circular_buffer_reset(buffer)
    }

    /// Get number of bytes available for writing
    /// - Returns: Available write space in bytes
    func availableWriteSpace() -> Int {
        guard let buffer = cppBuffer else { return 0 }
        return circular_buffer_available_write(buffer)
    }

    /// Get number of bytes available for reading
    /// - Returns: Available data in bytes
    func availableReadSpace() -> Int {
        guard let buffer = cppBuffer else { return 0 }
        return circular_buffer_available_read(buffer)
    }
}

