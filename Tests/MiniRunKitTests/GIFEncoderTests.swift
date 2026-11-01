import XCTest
@testable import MiniRunKit

final class GIFEncoderTests: XCTestCase {
    /// Frames of solid colour with a moving square, 4 bytes a pixel.
    private func frame(width: Int, height: Int, square: (x: Int, y: Int)?, background: (UInt8, UInt8, UInt8) = (240, 240, 245),
                       padding: Int = 0) -> [UInt8] {
        let bytesPerRow = width * 4 + padding
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * bytesPerRow + x * 4
                var color = background
                if let square, (square.x..<square.x + 8).contains(x), (square.y..<square.y + 8).contains(y) { color = (10, 120, 250) }
                // A horizontal gradient band, to need more than a handful of colours.
                if y < 6 { color = (UInt8(x * 255 / max(1, width - 1)), 60, UInt8(255 - x * 255 / max(1, width - 1))) }
                rgba[i] = color.0; rgba[i + 1] = color.1; rgba[i + 2] = color.2; rgba[i + 3] = 255
            }
        }
        return rgba
    }

    func testRoundTripsThroughADecoder() throws {
        let width = 40, height = 30, padding = 12
        var encoder = GIFEncoder(width: width, height: height)
        var sources: [[UInt8]] = []
        for step in 0..<5 {
            let rgba = frame(width: width, height: height, square: (x: 4 + step * 5, y: 10), padding: padding)
            sources.append(rgba)
            encoder.add(rgba: rgba, bytesPerRow: width * 4 + padding, duration: 0.1)
        }
        let gif = GIFDecoder(encoder.finish())
        let frames = try gif.frames()
        XCTAssertEqual(gif.width, width)
        XCTAssertEqual(gif.height, height)
        XCTAssertEqual(frames.count, 5)
        XCTAssertEqual(frames.map(\.delay), [10, 10, 10, 10, 10])
        for (canvas, source) in zip(frames.map(\.canvas), sources) {
            for y in 0..<height {
                for x in 0..<width {
                    let s = y * (width * 4 + padding) + x * 4, c = (y * width + x) * 3
                    for channel in 0..<3 {
                        XCTAssertLessThanOrEqual(abs(Int(canvas[c + channel]) - Int(source[s + channel])), 4, "pixel \(x),\(y)")
                    }
                }
            }
        }
        // After the first, frames hold only the moving square's rows.
        XCTAssertEqual(frames[0].rect.height, height)
        XCTAssertEqual(frames[1].rect.y, 10)
        XCTAssertEqual(frames[1].rect.height, 8)
    }

    func testStillFramesStretchTheOneBefore() throws {
        var encoder = GIFEncoder(width: 16, height: 16)
        let still = frame(width: 16, height: 16, square: (x: 2, y: 2))
        let moved = frame(width: 16, height: 16, square: (x: 6, y: 2))
        for _ in 0..<4 { encoder.add(rgba: still, bytesPerRow: 64, duration: 1.0 / 15) }
        encoder.add(rgba: moved, bytesPerRow: 64, duration: 1.0 / 15)
        for _ in 0..<2 { encoder.add(rgba: moved, bytesPerRow: 64, duration: 1.0 / 15) }
        let frames = try GIFDecoder(encoder.finish()).frames()
        XCTAssertEqual(frames.map(\.delay), [27, 20]) // 4/15 s and 3/15 s, in whole centiseconds
        XCTAssertEqual(encoder.storedFrames, 2)
    }

    func testSmallNoiseIsNotAChange() throws {
        var encoder = GIFEncoder(width: 16, height: 16, tolerance: 4)
        let base = frame(width: 16, height: 16, square: nil)
        var noisy = base
        for i in stride(from: 0, to: noisy.count, by: 4) { noisy[i] = noisy[i] &+ (i % 8 == 0 ? 3 : 0) }
        encoder.add(rgba: base, bytesPerRow: 64, duration: 0.5)
        encoder.add(rgba: noisy, bytesPerRow: 64, duration: 0.5)
        XCTAssertEqual(try GIFDecoder(encoder.finish()).frames().map(\.delay), [100])
    }

    func testManyColoursFitInAPalette() throws {
        let width = 64, height = 64
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                rgba[i] = UInt8(x * 4); rgba[i + 1] = UInt8(y * 4); rgba[i + 2] = UInt8((x + y) * 2)
            }
        }
        var encoder = GIFEncoder(width: width, height: height)
        encoder.add(rgba: rgba, bytesPerRow: width * 4, duration: 1)
        let canvas = try XCTUnwrap(GIFDecoder(encoder.finish()).frames().first).canvas
        var worst = 0, total = 0
        for p in 0..<(width * height) {
            for channel in 0..<3 {
                let error = abs(Int(canvas[p * 3 + channel]) - Int(rgba[p * 4 + channel]))
                worst = max(worst, error)
                total += error
            }
        }
        // 4096 colours squeezed into 255: close on average, never far off.
        XCTAssertLessThan(Double(total) / Double(width * height * 3), 6)
        XCTAssertLessThan(worst, 40)
    }

    func testLZWHandlesTableResets() throws {
        // Enough varied data to fill the 4096-entry table several times.
        var generator = SystemRandomNumberGenerator()
        let indices = (0..<200_000).map { _ in UInt8.random(in: 0...254, using: &generator) }
        var data = Data()
        LZW.encode(indices, minCodeSize: 8, into: &data)
        var reader = GIFDecoder.Reader(bytes: [UInt8](data))
        XCTAssertEqual(try GIFDecoder.decodeLZW(&reader, count: indices.count), indices)
    }
}

/// Just enough of a GIF decoder to check the encoder: no global colour tables, no interlacing.
struct GIFDecoder {
    struct Frame {
        var delay: Int
        var rect: (x: Int, y: Int, width: Int, height: Int)
        /// The whole picture after this frame, 3 bytes a pixel.
        var canvas: [UInt8]
    }

    struct Reader {
        var bytes: [UInt8]
        var at = 0
        mutating func byte() throws -> Int {
            guard at < bytes.count else { throw ToolError("ran off the end") }
            defer { at += 1 }
            return Int(bytes[at])
        }
        mutating func le16() throws -> Int { let low = try byte(); return try low | byte() << 8 }
        mutating func skip(_ n: Int) { at += n }
        mutating func subBlocks() throws -> [UInt8] {
            var out: [UInt8] = []
            while true {
                let n = try byte()
                if n == 0 { return out }
                guard at + n <= bytes.count else { throw ToolError("short block") }
                out += bytes[at..<(at + n)]
                at += n
            }
        }
    }

    let data: Data
    var width: Int { Int(data[6]) | Int(data[7]) << 8 }
    var height: Int { Int(data[8]) | Int(data[9]) << 8 }

    init(_ data: Data) { self.data = data }

    func frames() throws -> [Frame] {
        var reader = Reader(bytes: [UInt8](data))
        guard String(decoding: reader.bytes.prefix(6), as: UTF8.self) == "GIF89a" else { throw ToolError("not a GIF89a") }
        reader.skip(13)
        var canvas = [UInt8](repeating: 0, count: width * height * 3)
        var frames: [Frame] = []
        var delay = 0, transparent: Int?
        while true {
            switch try reader.byte() {
            case 0x21:
                let label = try reader.byte()
                let body = try reader.subBlocks()
                if label == 0xF9 {
                    delay = Int(body[1]) | Int(body[2]) << 8
                    transparent = body[0] & 1 == 1 ? Int(body[3]) : nil
                }
            case 0x2C:
                let x = try reader.le16(), y = try reader.le16(), w = try reader.le16(), h = try reader.le16()
                let flags = try reader.byte()
                guard flags & 0x80 != 0 else { throw ToolError("expected a local colour table") }
                let entries = 2 << (flags & 7)
                let table = Array(reader.bytes[reader.at..<(reader.at + entries * 3)])
                reader.skip(entries * 3)
                let indices = try Self.decodeLZW(&reader, count: w * h)
                for row in 0..<h {
                    for col in 0..<w {
                        let index = Int(indices[row * w + col])
                        if index == transparent { continue }
                        let c = ((y + row) * width + x + col) * 3
                        canvas[c] = table[index * 3]; canvas[c + 1] = table[index * 3 + 1]; canvas[c + 2] = table[index * 3 + 2]
                    }
                }
                frames.append(Frame(delay: delay, rect: (x, y, w, h), canvas: canvas))
            case 0x3B:
                return frames
            case let other:
                throw ToolError("unexpected block \(other)")
            }
        }
    }

    static func decodeLZW(_ reader: inout Reader, count: Int) throws -> [UInt8] {
        let minCodeSize = try reader.byte()
        let bytes = try reader.subBlocks()
        let clear = 1 << minCodeSize, end = clear + 1
        var codeSize = minCodeSize + 1
        var dictionary: [[UInt8]] = []
        func resetDictionary() {
            dictionary = (0..<clear).map { [UInt8($0)] } + [[], []]
            codeSize = minCodeSize + 1
        }
        resetDictionary()
        var out: [UInt8] = []
        var previous: [UInt8]?
        var bitPosition = 0
        while bitPosition + codeSize <= bytes.count * 8 {
            var code = 0
            for bit in 0..<codeSize {
                let p = bitPosition + bit
                if bytes[p >> 3] >> (p & 7) & 1 == 1 { code |= 1 << bit }
            }
            bitPosition += codeSize
            if code == clear { resetDictionary(); previous = nil; continue }
            if code == end { break }
            let entry: [UInt8]
            if code < dictionary.count {
                entry = dictionary[code]
            } else if let previous, code == dictionary.count {
                entry = previous + [previous[0]]
            } else {
                throw ToolError("bad code \(code)")
            }
            out += entry
            if let previous, dictionary.count < 4096 { dictionary.append(previous + [entry[0]]) }
            if dictionary.count == 1 << codeSize, codeSize < 12 { codeSize += 1 }
            previous = entry
        }
        guard out.count == count else { throw ToolError("decoded \(out.count) pixels, expected \(count)") }
        return out
    }
}
