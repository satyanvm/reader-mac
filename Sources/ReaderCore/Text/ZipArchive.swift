import Compression
import Foundation

public struct ZipError: Error, CustomStringConvertible {
    public let description: String
}

/// Read-only ZIP access, enough for EPUBs: stored and deflated entries, no ZIP64 or encryption.
/// The file is memory-mapped and never modified, so reads are thread-safe.
public final class ZipArchive: @unchecked Sendable {
    private struct Entry {
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    private let data: Data
    private let entries: [String: Entry]

    public init(url: URL) throws {
        data = try Data(contentsOf: url, options: .alwaysMapped)
        entries = try Self.readDirectory(data)
    }

    public var names: [String] { Array(entries.keys) }

    public func contains(_ name: String) -> Bool { entries[name] != nil }

    public func read(_ name: String) -> Data? {
        guard let e = entries[name] else { return nil }
        let h = e.localHeaderOffset
        guard h + 30 <= data.count, u32(data, h) == 0x04034b50 else { return nil }
        let start = h + 30 + Int(u16(data, h + 26)) + Int(u16(data, h + 28))
        guard start + e.compressedSize <= data.count else { return nil }
        let raw = data.subdata(in: start..<start + e.compressedSize)
        switch e.method {
        case 0: return raw
        case 8: return Self.inflate(raw, size: e.size)
        default: return nil
        }
    }

    public func text(_ name: String) -> String? {
        read(name).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func inflate(_ raw: Data, size: Int) -> Data? {
        if size == 0 { return Data() }
        var out = Data(count: size)
        let n = out.withUnsafeMutableBytes { dst in
            raw.withUnsafeBytes { src in
                // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is what ZIP stores.
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, size,
                    src.bindMemory(to: UInt8.self).baseAddress!, raw.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        return n == size ? out : nil
    }

    private static func readDirectory(_ d: Data) throws -> [String: Entry] {
        guard d.count >= 22 else { throw ZipError(description: "not a zip file") }
        var eocd = -1
        var i = d.count - 22
        let floor = max(0, d.count - 22 - 65_535)
        while i >= floor {
            if u32(d, i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError(description: "not a zip file") }
        let count = Int(u16(d, eocd + 10))
        var p = Int(u32(d, eocd + 16))
        var out: [String: Entry] = [:]
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(d, p) == 0x02014b50 else { throw ZipError(description: "corrupt zip directory") }
            let nameLen = Int(u16(d, p + 28))
            let extraLen = Int(u16(d, p + 30))
            let commentLen = Int(u16(d, p + 32))
            guard p + 46 + nameLen <= d.count else { throw ZipError(description: "corrupt zip directory") }
            let nameData = d.subdata(in: p + 46..<p + 46 + nameLen)
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)
            out[name] = Entry(
                method: u16(d, p + 10),
                compressedSize: Int(u32(d, p + 20)),
                size: Int(u32(d, p + 24)),
                localHeaderOffset: Int(u32(d, p + 42))
            )
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }
}

private func u16(_ d: Data, _ at: Int) -> UInt16 {
    let b = d.startIndex + at
    return UInt16(d[b]) | UInt16(d[b + 1]) << 8
}

private func u32(_ d: Data, _ at: Int) -> UInt32 {
    let b = d.startIndex + at
    return UInt32(d[b]) | UInt32(d[b + 1]) << 8 | UInt32(d[b + 2]) << 16 | UInt32(d[b + 3]) << 24
}
