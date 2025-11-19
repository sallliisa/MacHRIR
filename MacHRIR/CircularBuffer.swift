//
//  CircularBuffer.swift
//  MacHRIR
//
//  Thread-safe circular buffer for decoupling input and output audio streams
//

import Foundation
import Darwin

/// Thread-safe ring buffer for audio data transfer between input and output callbacks
class CircularBuffer {
    private var buffer: UnsafeMutableRawPointer
    private var size: Int
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    // Lock-free implementation for Single Producer Single Consumer (SPSC)
    // No NSLock needed if we use memory barriers correctly

    /// Initialize circular buffer with specified size
    /// - Parameter size: Buffer size in bytes (minimum 65536 recommended)
    init(size: Int) {
        self.size = size
        self.buffer = UnsafeMutableRawPointer.allocate(
            byteCount: size,
            alignment: MemoryLayout<Float>.alignment
        )
        // Zero out the buffer initially
        memset(buffer, 0, size)
    }

    deinit {
        buffer.deallocate()
    }

    /// Write data to the circular buffer
    /// - Parameters:
    ///   - data: Pointer to source data
    ///   - size: Number of bytes to write
    /// - Returns: Number of bytes actually written
    @discardableResult
    func write(data: UnsafeRawPointer, size: Int) -> Int {
        // Lock-free SPSC
        
        // Load readIndex with barrier (effectively)
        // In Swift, simple load is usually fine on TSO, but for ARM we rely on barriers later or implicit ordering.
        // Ideally we would use atomic load, but for this simple ring buffer:
        let currentReadIndex = readIndex
        
        let available = availableWrite(readIdx: currentReadIndex)
        let toWrite = min(size, available)

        if toWrite == 0 {
            return 0
        }

        // Handle wrap-around
        let firstChunk = min(toWrite, self.size - writeIndex)
        memcpy(buffer.advanced(by: writeIndex), data, firstChunk)

        if firstChunk < toWrite {
            // Write remaining data at beginning of buffer
            memcpy(buffer, data.advanced(by: firstChunk), toWrite - firstChunk)
        }

        // Memory Barrier to ensure data is written before index is updated
        OSMemoryBarrier()

        writeIndex = (writeIndex + toWrite) % self.size

        return toWrite
    }

    /// Read data from the circular buffer
    /// - Parameters:
    ///   - data: Pointer to destination buffer
    ///   - size: Number of bytes to read
    /// - Returns: Number of bytes actually read
    @discardableResult
    func read(into data: UnsafeMutableRawPointer, size: Int) -> Int {
        // Lock-free SPSC
        
        let currentWriteIndex = writeIndex
        
        let available = availableRead(writeIdx: currentWriteIndex)
        let toRead = min(size, available)

        if toRead == 0 {
            return 0
        }

        // Handle wrap-around
        let firstChunk = min(toRead, self.size - readIndex)
        memcpy(data, buffer.advanced(by: readIndex), firstChunk)

        if firstChunk < toRead {
            // Read remaining data from beginning of buffer
            memcpy(data.advanced(by: firstChunk), buffer, toRead - firstChunk)
        }

        // Memory Barrier to ensure data is read before index is updated
        OSMemoryBarrier()

        readIndex = (readIndex + toRead) % self.size

        return toRead
    }

    /// Reset buffer to empty state
    func reset() {
        writeIndex = 0
        readIndex = 0
        memset(buffer, 0, size)
        OSMemoryBarrier()
    }

    /// Get number of bytes available for writing
    /// - Returns: Available write space in bytes
    func availableWriteSpace() -> Int {
        return availableWrite(readIdx: readIndex)
    }

    /// Get number of bytes available for reading
    /// - Returns: Available data in bytes
    func availableReadSpace() -> Int {
        return availableRead(writeIdx: writeIndex)
    }

    // MARK: - Private Helper Methods

    private func availableWrite(readIdx: Int) -> Int {
        if writeIndex >= readIdx {
            return size - (writeIndex - readIdx) - 1
        } else {
            return readIdx - writeIndex - 1
        }
    }

    private func availableRead(writeIdx: Int) -> Int {
        if writeIdx >= readIndex {
            return writeIdx - readIndex
        } else {
            return size - (readIndex - writeIdx)
        }
    }
}
