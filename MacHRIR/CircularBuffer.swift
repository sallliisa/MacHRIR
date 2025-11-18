//
//  CircularBuffer.swift
//  MacHRIR
//
//  Thread-safe circular buffer for decoupling input and output audio streams
//

import Foundation

/// Thread-safe ring buffer for audio data transfer between input and output callbacks
class CircularBuffer {
    private var buffer: UnsafeMutableRawPointer
    private var size: Int
    private var writeIndex: Int = 0
    private var readIndex: Int = 0
    private let lock = NSLock()

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
        lock.lock()
        defer { lock.unlock() }

        let available = availableWrite()
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
        lock.lock()
        defer { lock.unlock() }

        let available = availableRead()
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

        readIndex = (readIndex + toRead) % self.size

        return toRead
    }

    /// Reset buffer to empty state
    func reset() {
        lock.lock()
        defer { lock.unlock() }

        writeIndex = 0
        readIndex = 0
        memset(buffer, 0, size)
    }

    /// Get number of bytes available for writing
    /// - Returns: Available write space in bytes
    func availableWriteSpace() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return availableWrite()
    }

    /// Get number of bytes available for reading
    /// - Returns: Available data in bytes
    func availableReadSpace() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return availableRead()
    }

    // MARK: - Private Helper Methods

    private func availableWrite() -> Int {
        if writeIndex >= readIndex {
            return size - (writeIndex - readIndex) - 1
        } else {
            return readIndex - writeIndex - 1
        }
    }

    private func availableRead() -> Int {
        if writeIndex >= readIndex {
            return writeIndex - readIndex
        } else {
            return size - (readIndex - writeIndex)
        }
    }
}
