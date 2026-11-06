import Foundation

/// A WAV file whose writer never closed it (the app crashed, the Mac lost power) has a header
/// that says it is empty: the RIFF and data chunk sizes are written last. This reads the sizes
/// back from the file's length, so the recording plays and transcribes.
public enum WAVRepair {
    /// True when the header needed fixing and was fixed; false when it was fine. Throws when
    /// the file isn't a WAV at all.
    @discardableResult
    public static func repair(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard size >= 12, let head = try handle.read(upToCount: 12), head.count == 12,
              String(decoding: head[0..<4], as: UTF8.self) == "RIFF", String(decoding: head[8..<12], as: UTF8.self) == "WAVE" else {
            throw Problem("not a WAV file")
        }
        var fixed = false
        let riffSize = UInt32(min(size - 8, UInt64(UInt32.max)))
        if head.uint32(at: 4) != riffSize {
            try handle.seek(toOffset: 4)
            try handle.write(contentsOf: riffSize.littleEndianData)
            fixed = true
        }
        // Walk the chunks to the data chunk; its size runs to the end of the file.
        var offset: UInt64 = 12
        while offset + 8 <= size {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: 8), chunk.count == 8 else { break }
            let id = String(decoding: chunk[0..<4], as: UTF8.self)
            let declared = chunk.uint32(at: 4)
            if id == "data" {
                let actual = UInt32(min(size - offset - 8, UInt64(UInt32.max)))
                if declared != actual {
                    try handle.seek(toOffset: offset + 4)
                    try handle.write(contentsOf: actual.littleEndianData)
                    fixed = true
                }
                return fixed
            }
            offset += 8 + UInt64(declared) + UInt64(declared % 2)
        }
        throw Problem("no data chunk")
    }

    public struct Problem: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

extension Data {
    func uint32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}

extension UInt32 {
    var littleEndianData: Data {
        Data([UInt8(self & 0xff), UInt8((self >> 8) & 0xff), UInt8((self >> 16) & 0xff), UInt8((self >> 24) & 0xff)])
    }
}
