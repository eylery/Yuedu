import Foundation
import zlib

/// A deliberately small, read-only ZIP reader. No archive path is ever written to disk.
struct EPUBArchive {
    private struct Entry {
        var flags: UInt16
        var method: UInt16
        var checksum: UInt32
        var compressedSize: Int
        var size: Int
        var offset: Int
        var filename: [UInt8]
    }
    private let bytes: [UInt8]
    private let directoryOffset: Int
    private var entries: [String: Entry] = [:]

    init(data: Data) throws {
        guard data.count >= 22 else { throw BookImportError.invalidArchive("文件不完整") }
        bytes = Array(data)
        var end: Int?
        for offset in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if bytes.u32(offset) == 0x06054B50,
               offset + 22 + Int(bytes.u16(offset + 20)) == bytes.count { end = offset; break }
        }
        guard let end else { throw BookImportError.invalidArchive("未找到 ZIP 目录") }
        let count = Int(bytes.u16(end + 10))
        let directorySize = Int(bytes.u32(end + 12))
        directoryOffset = Int(bytes.u32(end + 16))
        guard bytes.u16(end + 4) == 0, bytes.u16(end + 6) == 0, bytes.u16(end + 8) == count,
              count > 0, count <= 10_000, directoryOffset <= end,
              directorySize <= end - directoryOffset else {
            throw BookImportError.invalidArchive("不支持分卷、ZIP64 或异常数量的文件")
        }
        var offset = directoryOffset
        var totalSize = 0
        for _ in 0..<count {
            guard offset + 46 <= end, bytes.u32(offset) == 0x02014B50 else { throw BookImportError.invalidArchive("目录记录损坏") }
            let flags = bytes.u16(offset + 8)
            guard flags & 0x0041 == 0 else { throw BookImportError.encryptedEPUB }
            let nameLength = Int(bytes.u16(offset + 28))
            let recordSize = 46 + nameLength + Int(bytes.u16(offset + 30)) + Int(bytes.u16(offset + 32))
            guard recordSize <= end - offset, bytes.u16(offset + 34) == 0 else { throw BookImportError.invalidArchive("目录记录越界") }
            let filename = Array(bytes[(offset + 46)..<(offset + 46 + nameLength)])
            guard let path = String(bytes: filename, encoding: .utf8), Self.isSafePath(path), entries[path] == nil else {
                throw BookImportError.invalidArchive("文件路径无效或重复")
            }
            let entry = Entry(flags: flags, method: bytes.u16(offset + 10), checksum: bytes.u32(offset + 16),
                              compressedSize: Int(bytes.u32(offset + 20)), size: Int(bytes.u32(offset + 24)),
                              offset: Int(bytes.u32(offset + 42)), filename: filename)
            guard entry.size <= 16 * 1_024 * 1_024, entry.compressedSize <= data.count else { throw BookImportError.tooLarge }
            totalSize += entry.size
            guard totalSize <= 64 * 1_024 * 1_024 else { throw BookImportError.tooLarge }
            entries[path] = entry
            offset += recordSize
        }
        guard offset == directoryOffset + directorySize else { throw BookImportError.invalidArchive("目录长度不一致") }
    }

    func contains(_ path: String) -> Bool { entries[path] != nil }

    func read(_ path: String) throws -> Data {
        guard let entry = entries[path] else { throw BookImportError.invalidEPUB("缺少文件 \(path)") }
        let offset = entry.offset
        guard offset >= 0, offset <= directoryOffset - 30, bytes.u32(offset) == 0x04034B50,
              bytes.u16(offset + 6) == entry.flags, bytes.u16(offset + 8) == entry.method else {
            throw BookImportError.invalidArchive("文件记录不一致")
        }
        let nameLength = Int(bytes.u16(offset + 26))
        let extraLength = Int(bytes.u16(offset + 28))
        let dataStart = offset + 30 + nameLength + extraLength
        guard dataStart <= directoryOffset, entry.compressedSize <= directoryOffset - dataStart,
              Array(bytes[(offset + 30)..<(offset + 30 + nameLength)]) == entry.filename else {
            throw BookImportError.invalidArchive("压缩数据越界")
        }
        let compressed = Array(bytes[dataStart..<(dataStart + entry.compressedSize)])
        let output: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.size else { throw BookImportError.invalidArchive("文件长度不一致") }
            output = Data(compressed)
        case 8:
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw BookImportError.invalidArchive("无法初始化解压器")
            }
            defer { inflateEnd(&stream) }
            // The extra byte distinguishes exact output from a dishonest uncompressed-size header.
            var inflated = [UInt8](repeating: 0, count: entry.size + 1)
            let status = compressed.withUnsafeBytes { input in
                inflated.withUnsafeMutableBytes { destination in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                    stream.avail_in = uInt(compressed.count)
                    stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size, stream.total_in == entry.compressedSize else {
                throw BookImportError.invalidArchive("压缩数据损坏或解压大小不符")
            }
            output = Data(inflated.prefix(entry.size))
        default:
            throw BookImportError.invalidArchive("不支持的 ZIP 压缩方式")
        }
        let checksum = output.withUnsafeBytes { data in crc32(0, data.bindMemory(to: Bytef.self).baseAddress, uInt(output.count)) }
        guard UInt32(checksum) == entry.checksum else { throw BookImportError.invalidArchive("文件校验失败") }
        return output
    }

    /// Resolves OPF-relative references while keeping every path inside the archive.
    static func resolve(_ href: String, relativeTo base: String = "") throws -> String {
        let fragmentFree = String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard let decoded = fragmentFree.removingPercentEncoding, !decoded.isEmpty,
              !decoded.hasPrefix("/"), !decoded.contains("\\"), !decoded.contains(":"), !decoded.contains("\0") else {
            throw BookImportError.invalidEPUB("正文链接不是有效的本地路径")
        }
        var components = base.split(separator: "/").map(String.init)
        if !components.isEmpty { components.removeLast() }
        for component in decoded.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { throw BookImportError.invalidEPUB("正文路径超出书籍目录") }
                components.removeLast()
            } else { components.append(String(component)) }
        }
        let path = components.joined(separator: "/")
        guard isSafePath(path) else { throw BookImportError.invalidEPUB("正文路径无效") }
        return path
    }

    private static func isSafePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains(":") && !path.contains("\0") &&
        !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." })
    }
}

private extension Array where Element == UInt8 {
    // Every call is preceded by a containing-structure bounds check.
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24
    }
}
