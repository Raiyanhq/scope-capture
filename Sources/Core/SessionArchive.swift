import Foundation

/// Streaming, uncompressed ZIP64. No file-coordination/provider dependency.
/// ZIP64 preserves large recordings; memory use is bounded to a 64 KB buffer.
enum SessionArchive {
    private struct Entry {
        let name: Data
        let size: UInt64
        let crc: UInt32
        let offset: UInt64
    }
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) }
        return crc
    }
    private static func update(_ crc: inout UInt32, data: Data) {
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
    }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    private static func fingerprint(_ url: URL) throws -> (UInt64, UInt32) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var size: UInt64 = 0; var crc = UInt32.max
        while let data = try input.read(upToCount: 65536), !data.isEmpty {
            size += UInt64(data.count); update(&crc, data: data)
        }
        return (size, crc ^ UInt32.max)
    }
    static func write(root: URL, paths: [String], output: URL) throws {
        guard Set(paths).count == paths.count, !paths.isEmpty else {
            throw RecorderError(message: "The archive inventory is empty or duplicated.")
        }
        try Data().write(to: output, options: .withoutOverwriting)
        let file = try FileHandle(forWritingTo: output)
        var completed = false
        defer {
            try? file.close()
            if !completed { try? FileManager.default.removeItem(at: output) }
        }
        var entries: [Entry] = []
        for path in paths.sorted() {
            let source = try SessionFiles.safeURL(root: root, relative: path)
            let name = Data(path.utf8)
            guard name.count <= Int(UInt16.max) else { throw RecorderError(message: "Archive path is too long.") }
            let (size, crc) = try fingerprint(source)
            let offset = try file.offset()
            var local = Data()
            append(UInt32(0x04034b50), to: &local)
            append(UInt16(45), to: &local); append(UInt16(0x0800), to: &local)
            append(UInt16(0), to: &local) // Stored method; no lossy processing.
            append(UInt16(0), to: &local); append(UInt16(33), to: &local) // 1980-01-01
            append(crc, to: &local)
            append(UInt32.max, to: &local); append(UInt32.max, to: &local)
            append(UInt16(name.count), to: &local); append(UInt16(20), to: &local)
            local.append(name)
            append(UInt16(1), to: &local); append(UInt16(16), to: &local)
            append(size, to: &local); append(size, to: &local)
            try file.write(contentsOf: local)
            let input = try FileHandle(forReadingFrom: source)
            var copied: UInt64 = 0; var copiedCRC = UInt32.max
            do {
                while let data = try input.read(upToCount: 65536), !data.isEmpty {
                    try file.write(contentsOf: data)
                    copied += UInt64(data.count); update(&copiedCRC, data: data)
                }
                try input.close()
            } catch { try? input.close(); throw error }
            guard copied == size, copiedCRC ^ UInt32.max == crc else {
                throw RecorderError(message: "A source file changed while preparing the ZIP. Please retry.")
            }
            entries.append(Entry(name: name, size: size, crc: crc, offset: offset))
        }
        let centralOffset = try file.offset()
        for entry in entries {
            var central = Data()
            append(UInt32(0x02014b50), to: &central)
            append(UInt16(45), to: &central); append(UInt16(45), to: &central)
            append(UInt16(0x0800), to: &central); append(UInt16(0), to: &central)
            append(UInt16(0), to: &central); append(UInt16(33), to: &central)
            append(entry.crc, to: &central)
            append(UInt32.max, to: &central); append(UInt32.max, to: &central)
            append(UInt16(entry.name.count), to: &central); append(UInt16(28), to: &central)
            append(UInt16(0), to: &central); append(UInt16(0), to: &central)
            append(UInt16(0), to: &central); append(UInt32(0), to: &central)
            append(UInt32.max, to: &central); central.append(entry.name)
            append(UInt16(1), to: &central); append(UInt16(24), to: &central)
            append(entry.size, to: &central); append(entry.size, to: &central); append(entry.offset, to: &central)
            try file.write(contentsOf: central)
        }
        let zip64Offset = try file.offset()
        var end = Data()
        append(UInt32(0x06064b50), to: &end); append(UInt64(44), to: &end)
        append(UInt16(45), to: &end); append(UInt16(45), to: &end)
        append(UInt32(0), to: &end); append(UInt32(0), to: &end)
        append(UInt64(entries.count), to: &end); append(UInt64(entries.count), to: &end)
        append(zip64Offset - centralOffset, to: &end); append(centralOffset, to: &end)
        append(UInt32(0x07064b50), to: &end); append(UInt32(0), to: &end)
        append(zip64Offset, to: &end); append(UInt32(1), to: &end)
        append(UInt32(0x06054b50), to: &end)
        append(UInt16(0), to: &end); append(UInt16(0), to: &end)
        append(UInt16.max, to: &end); append(UInt16.max, to: &end)
        append(UInt32.max, to: &end); append(UInt32.max, to: &end); append(UInt16(0), to: &end)
        try file.write(contentsOf: end); try file.synchronize(); try file.close()
        completed = true
    }
}
