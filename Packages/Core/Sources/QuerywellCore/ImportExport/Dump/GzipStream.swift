import Foundation
import zlib

// Streaming gzip using the system zlib (`import zlib` works from the macOS SDK without extra linker
// settings). Chosen over Apple's Compression framework, which only does raw DEFLATE and would need a
// hand-written gzip header/trailer and CRC32; zlib's `windowBits = 31` does all of that and is the
// same code `gzip(1)` links against.

public enum GzipError: Error, Equatable, Sendable, LocalizedError {
    case corrupt(String)
    case truncated
    case initFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .corrupt(let m): "The compressed data is damaged (\(m))."
        case .truncated: "The compressed data ends unexpectedly (the file is incomplete)."
        case .initFailed(let c): "Could not start compression (zlib error \(c))."
        }
    }
}

/// Streaming gzip compressor. Not thread-safe; use from one task/thread at a time.
final class GzipCompressor {
    private let stream: UnsafeMutablePointer<z_stream>
    private var finished = false

    init(level: Int32 = 6) throws {
        stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        // windowBits 15 + 16 = gzip wrapper; memLevel 8 is zlib's default.
        let rc = deflateInit2_(stream, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else {
            stream.deallocate()
            throw GzipError.initFailed(rc)
        }
    }

    deinit {
        deflateEnd(stream)
        stream.deallocate()
    }

    func compress(_ data: Data) throws -> Data { try run(data, flush: Z_NO_FLUSH) }

    /// Flushes the remaining bytes and the gzip trailer. Call once.
    func finish() throws -> Data {
        guard !finished else { return Data() }
        finished = true
        return try run(Data(), flush: Z_FINISH)
    }

    private func run(_ input: Data, flush: Int32) throws -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.pointee.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress)
            stream.pointee.avail_in = UInt32(raw.count)
            repeat {
                let rc: Int32 = buffer.withUnsafeMutableBufferPointer { buf in
                    stream.pointee.next_out = buf.baseAddress
                    stream.pointee.avail_out = UInt32(buf.count)
                    return deflate(stream, flush)
                }
                guard rc == Z_OK || rc == Z_STREAM_END || rc == Z_BUF_ERROR else { throw GzipError.corrupt("deflate error \(rc)") }
                let produced = buffer.count - Int(stream.pointee.avail_out)
                out.append(contentsOf: buffer[0..<produced])
                if rc == Z_STREAM_END { break }
            } while stream.pointee.avail_out == 0
        }
        return out
    }
}

/// Streaming gzip decompressor; accepts concatenated members (as `cat a.gz b.gz` produces).
final class GzipDecompressor {
    private let stream: UnsafeMutablePointer<z_stream>
    private var memberEnded = false
    private var sawData = false

    init() throws {
        stream = UnsafeMutablePointer<z_stream>.allocate(capacity: 1)
        stream.initialize(to: z_stream())
        let rc = inflateInit2_(stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard rc == Z_OK else {
            stream.deallocate()
            throw GzipError.initFailed(rc)
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deallocate()
    }

    func decompress(_ input: Data) throws -> Data {
        guard !input.isEmpty else { return Data() }
        sawData = true
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var offset = 0
        while offset < input.count {
            if memberEnded {
                // Another member follows only if it starts with the gzip magic; anything else is padding.
                guard input[input.startIndex + offset] == 0x1F else { return out }
                inflateReset(stream)
                memberEnded = false
            }
            var failure: GzipError?
            let consumed: Int = input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
                let base = raw.bindMemory(to: UInt8.self).baseAddress!.advanced(by: offset)
                stream.pointee.next_in = UnsafeMutablePointer(mutating: base)
                stream.pointee.avail_in = UInt32(raw.count - offset)
                repeat {
                    let rc: Int32 = buffer.withUnsafeMutableBufferPointer { buf in
                        stream.pointee.next_out = buf.baseAddress
                        stream.pointee.avail_out = UInt32(buf.count)
                        return inflate(stream, Z_NO_FLUSH)
                    }
                    let produced = buffer.count - Int(stream.pointee.avail_out)
                    out.append(contentsOf: buffer[0..<produced])
                    if rc == Z_STREAM_END { memberEnded = true; break }
                    if rc == Z_BUF_ERROR { break }  // needs more input
                    if rc != Z_OK {
                        failure = .corrupt(stream.pointee.msg.map { String(cString: $0) } ?? "inflate error \(rc)")
                        break
                    }
                } while stream.pointee.avail_in > 0 || stream.pointee.avail_out == 0
                return (raw.count - offset) - Int(stream.pointee.avail_in)
            }
            if let failure { throw failure }
            offset += consumed
            if !memberEnded { break }
        }
        return out
    }

    /// Throws ``GzipError/truncated`` if the stream stopped inside a member.
    func finish() throws {
        if sawData && !memberEnded { throw GzipError.truncated }
    }
}

public enum Gzip {
    /// One-shot helpers for small data and tests.
    public static func compress(_ data: Data) throws -> Data {
        let c = try GzipCompressor()
        var out = try c.compress(data)
        out.append(try c.finish())
        return out
    }

    public static func decompress(_ data: Data) throws -> Data {
        let d = try GzipDecompressor()
        let out = try d.decompress(data)
        try d.finish()
        return out
    }
}
