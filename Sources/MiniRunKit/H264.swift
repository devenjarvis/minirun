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

    /// Makes an SPS (NAL unit, header byte first) say frames are never reordered: a VUI with
    /// `max_num_reorder_frames` 0 and `max_dec_frame_buffering` the reference count. Without that,
    /// decoders (Chrome's and Safari's hardware ones) hold back as many frames as the level allows
    /// before showing any, so the live view runs ~6 frames late. VideoToolbox's default mode
    /// leaves the VUI out, so this adds one; its low-latency mode writes a VUI with the restriction
    /// already in it, which is kept as is. A VUI without the restriction gets it added. Returns the
    /// SPS unchanged if it already has the restriction or uses something this doesn't parse.
    public static func withoutReordering(sps: Data) -> Data {
        let bytes = [UInt8](sps)
        guard bytes.count > 4, bytes[0] & 0x1f == 7 else { return sps }
        var reader = BitReader(unescape(Array(bytes[1...])))
        guard let maxNumRefFrames = readSPSUpToVUI(&reader) else { return sps }
        let vuiFlagBit = reader.position
        guard let hasVUI = reader.bit() else { return sps }
        let restrictionFlagBit: Int
        if hasVUI == 1 {
            guard skipVUIUpToRestriction(&reader) else { return sps }
            restrictionFlagBit = reader.position
            guard reader.bit() == 0 else { return sps }
        } else {
            restrictionFlagBit = vuiFlagBit
        }

        // Copy everything before the flag that's 0, then write the rest of the VUI.
        var writer = BitWriter()
        var copy = BitReader(reader.bytes)
        for _ in 0..<restrictionFlagBit { writer.bit(copy.bit()!) }
        if hasVUI == 0 {
            writer.bit(1) // vui_parameters_present_flag
            for _ in 0..<8 { writer.bit(0) } // aspect ratio, overscan, video signal, chroma loc, timing, NAL HRD, VCL HRD, pic struct
        }
        writer.bit(1) // bitstream_restriction_flag
        writer.bit(1) // motion_vectors_over_pic_boundaries_flag
        writer.ue(0) // max_bytes_per_pic_denom (no limit)
        writer.ue(0) // max_bits_per_mb_denom (no limit)
        writer.ue(15) // log2_max_mv_length_horizontal (the default)
        writer.ue(15) // log2_max_mv_length_vertical
        writer.ue(0) // max_num_reorder_frames
        writer.ue(max(1, maxNumRefFrames)) // max_dec_frame_buffering
        writer.bit(1) // rbsp_stop_one_bit
        while writer.count % 8 != 0 { writer.bit(0) }
        return Data([bytes[0]] + escape(writer.bytes))
    }

    /// The `max_num_reorder_frames` an SPS declares, or nil if it declares none (or this can't
    /// parse it). Decoders only show frames straight away when this is 0.
    static func maxNumReorderFrames(sps: Data) -> Int? {
        let bytes = [UInt8](sps)
        guard bytes.count > 4, bytes[0] & 0x1f == 7 else { return nil }
        var r = BitReader(unescape(Array(bytes[1...])))
        guard readSPSUpToVUI(&r) != nil, r.bit() == 1, skipVUIUpToRestriction(&r), r.bit() == 1 else { return nil }
        guard r.bit() != nil, r.ue() != nil, r.ue() != nil, r.ue() != nil, r.ue() != nil else { return nil }
        return r.ue()
    }

    /// Reads a VUI from just after vui_parameters_present_flag up to, not including,
    /// bitstream_restriction_flag. False if it has HRD parameters (not parsed here) or ends early.
    private static func skipVUIUpToRestriction(_ r: inout BitReader) -> Bool {
        guard let aspectRatio = r.bit() else { return false }
        if aspectRatio == 1 {
            guard let idc = r.bits(8) else { return false }
            if idc == 255 { guard r.bits(32) != nil else { return false } } // Extended_SAR
        }
        guard let overscan = r.bit() else { return false }
        if overscan == 1 { guard r.bit() != nil else { return false } }
        guard let videoSignal = r.bit() else { return false }
        if videoSignal == 1 {
            guard r.bits(4) != nil, let colour = r.bit() else { return false } // video_format, full_range
            if colour == 1 { guard r.bits(24) != nil else { return false } }
        }
        guard let chromaLocation = r.bit() else { return false }
        if chromaLocation == 1 { guard r.ue() != nil, r.ue() != nil else { return false } }
        guard let timing = r.bit() else { return false }
        if timing == 1 { guard r.bits(32) != nil, r.bits(32) != nil, r.bit() != nil else { return false } }
        guard r.bit() == 0, r.bit() == 0 else { return false } // NAL and VCL HRD parameters
        return r.bit() != nil // pic_struct_present_flag
    }

    /// Reads an SPS RBSP (after the NAL header) up to, not including, vui_parameters_present_flag.
    /// Returns max_num_ref_frames.
    private static func readSPSUpToVUI(_ r: inout BitReader) -> Int? {
        guard let profile = r.bits(8), r.bits(16) != nil, r.ue() != nil else { return nil } // profile, constraints + level, sps id
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            guard let chroma = r.ue() else { return nil }
            if chroma == 3 { guard r.bit() != nil else { return nil } }
            guard r.ue() != nil, r.ue() != nil, r.bit() != nil, let scaling = r.bit() else { return nil }
            if scaling == 1 { return nil } // scaling lists: not worth parsing here
        }
        guard r.ue() != nil, let pocType = r.ue() else { return nil } // log2_max_frame_num_minus4
        if pocType == 0 {
            guard r.ue() != nil else { return nil }
        } else if pocType == 1 {
            guard r.bit() != nil, r.se() != nil, r.se() != nil, let cycle = r.ue(), cycle < 256 else { return nil }
            for _ in 0..<cycle { guard r.se() != nil else { return nil } }
        }
        guard let refs = r.ue(), r.bit() != nil, r.ue() != nil, r.ue() != nil, let frameMbsOnly = r.bit() else { return nil }
        if frameMbsOnly == 0 { guard r.bit() != nil else { return nil } }
        guard r.bit() != nil, let cropping = r.bit() else { return nil }
        if cropping == 1 { for _ in 0..<4 { guard r.ue() != nil else { return nil } } }
        return refs
    }

    /// Removes emulation prevention bytes (00 00 03 -> 00 00).
    static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte == 3 { zeros = 0; continue }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    /// Adds emulation prevention bytes where 00 00 would be followed by 00-03.
    static func escape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte <= 3 { out.append(3); zeros = 0 }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    struct BitReader {
        let bytes: [UInt8]
        private(set) var position = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func bit() -> Int? {
            guard position < bytes.count * 8 else { return nil }
            defer { position += 1 }
            return Int(bytes[position / 8] >> (7 - UInt8(position % 8)) & 1)
        }

        mutating func bits(_ count: Int) -> Int? {
            var value = 0
            for _ in 0..<count {
                guard let b = bit() else { return nil }
                value = value << 1 | b
            }
            return value
        }

        /// Unsigned Exp-Golomb.
        mutating func ue() -> Int? {
            var zeros = 0
            while true {
                guard let b = bit() else { return nil }
                if b == 1 { break }
                zeros += 1
                if zeros > 31 { return nil }
            }
            guard let rest = bits(zeros) else { return nil }
            return (1 << zeros) - 1 + rest
        }

        /// Signed Exp-Golomb.
        mutating func se() -> Int? {
            guard let k = ue() else { return nil }
            return k % 2 == 1 ? (k + 1) / 2 : -(k / 2)
        }
    }

    struct BitWriter {
        private(set) var bytes: [UInt8] = []
        private(set) var count = 0

        mutating func bit(_ value: Int) {
            if count % 8 == 0 { bytes.append(0) }
            if value != 0 { bytes[bytes.count - 1] |= 1 << (7 - UInt8(count % 8)) }
            count += 1
        }

        mutating func ue(_ value: Int) {
            let coded = value + 1
            let length = Int.bitWidth - coded.leadingZeroBitCount
            for _ in 0..<(length - 1) { bit(0) }
            for i in stride(from: length - 1, through: 0, by: -1) { bit((coded >> i) & 1) }
        }
    }
}
