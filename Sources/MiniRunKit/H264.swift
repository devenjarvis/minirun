import Foundation

/// H.264 bitstream helpers for the live view.
public enum H264 {
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Converts length-prefixed NAL units (what VideoToolbox produces) to an Annex B byte stream
    /// (what browsers decode without extra setup), with `parameterSets` (SPS and PPS) first.
    /// Returns nil if a length runs past the end of the data.
    public static func annexB(lengthPrefixed data: Data, lengthSize: Int = 4, parameterSets: [Data] = []) -> Data? {
        guard (1...4).contains(lengthSize) else { return nil }
        let bytes = [UInt8](data)
        var output = Data(capacity: bytes.count + parameterSets.reduce(0) { $0 + $1.count + 4 } + 16)
        for set in parameterSets {
            output.append(contentsOf: startCode)
            output.append(set)
        }
        var offset = 0
        while offset < bytes.count {
            guard offset + lengthSize <= bytes.count else { return nil }
            var length = 0
            for byte in bytes[offset..<offset + lengthSize] { length = length << 8 | Int(byte) }
            offset += lengthSize
            guard length <= bytes.count - offset else { return nil }
            output.append(contentsOf: startCode)
            output.append(contentsOf: bytes[offset..<offset + length])
            offset += length
        }
        return output
    }

    /// The encoder's target bitrate for a stream: more bits per pixel at higher quality. Screens are
    /// mostly static, so real streams average well below this.
    public static func bitrate(width: Int, height: Int, fps: Int, quality: Int) -> Int {
        let bitsPerPixel = 0.02 + 0.08 * Double(min(100, max(1, quality))) / 100
        let target = Double(width * height) * Double(max(1, fps)) * bitsPerPixel
        return Int(min(8_000_000, max(150_000, target)))
    }
}
