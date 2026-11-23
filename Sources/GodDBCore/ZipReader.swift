import Compression
import Foundation

/// 아주 작은 ZIP 읽기 (DBeaver 프로젝트 내보내기 .dbp 용).
/// 저장(0) · deflate(8) 방식만, 암호 · ZIP64 는 지원하지 않는다.
enum ZipReader {
    enum ZipError: Error { case notZip, unsupported, corrupt }

    struct Entry {
        var path: String
        var method: UInt16
        var compressedSize: Int
        var size: Int
        var localHeaderOffset: Int
    }

    static func isZip(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
    }

    /// 파일 이름 → 내용. `filter` 가 true 인 항목만 푼다.
    static func read(_ data: Data, maxEntrySize: Int = 16 << 20, filter: (String) -> Bool) throws -> [String: Data] {
        let bytes = [UInt8](data)
        let entries = try centralDirectory(bytes)
        var out: [String: Data] = [:]
        for e in entries where filter(e.path) {
            guard e.size <= maxEntrySize else { throw ZipError.unsupported }
            out[e.path] = try extract(e, from: bytes)
        }
        return out
    }

    static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }

    static func centralDirectory(_ b: [UInt8]) throws -> [Entry] {
        guard b.count >= 22 else { throw ZipError.notZip }
        // 끝에서 End Of Central Directory(PK\5\6) 를 찾는다 (주석 최대 64KB)
        var eocd = -1
        var i = b.count - 22
        let stop = max(0, b.count - 22 - 0xFFFF)
        while i >= stop {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ZipError.notZip }
        let count = u16(b, eocd + 10)
        var p = u32(b, eocd + 16)
        var entries: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(b, p) == 0x0201_4B50 else { throw ZipError.corrupt }
            let flags = u16(b, p + 8)
            let nameLen = u16(b, p + 28), extraLen = u16(b, p + 30), commentLen = u16(b, p + 32)
            guard p + 46 + nameLen <= b.count else { throw ZipError.corrupt }
            let name = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            let csize = u32(b, p + 20), size = u32(b, p + 24), offset = u32(b, p + 42)
            if flags & 1 != 0 || csize == 0xFFFF_FFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
                throw ZipError.unsupported  // 암호화 · ZIP64
            }
            entries.append(Entry(path: name, method: UInt16(u16(b, p + 10)), compressedSize: csize, size: size, localHeaderOffset: offset))
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    static func extract(_ e: Entry, from b: [UInt8]) throws -> Data {
        let h = e.localHeaderOffset
        guard h + 30 <= b.count, u32(b, h) == 0x0403_4B50 else { throw ZipError.corrupt }
        let start = h + 30 + u16(b, h + 26) + u16(b, h + 28)
        guard start + e.compressedSize <= b.count else { throw ZipError.corrupt }
        let raw = Array(b[start..<(start + e.compressedSize)])
        switch e.method {
        case 0:
            return Data(raw)
        case 8:
            if e.size == 0 { return Data() }
            var out = [UInt8](repeating: 0, count: e.size)
            let n = compression_decode_buffer(&out, e.size, raw, raw.count, nil, COMPRESSION_ZLIB)
            guard n == e.size else { throw ZipError.corrupt }
            return Data(out)
        default:
            throw ZipError.unsupported
        }
    }
}
