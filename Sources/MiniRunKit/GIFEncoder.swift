import Foundation

/// Writes an animated GIF one frame at a time, tuned for screen recordings, where most of the
/// screen stays still from one frame to the next.
///
/// - Each frame stores only the rectangle that changed since the last one, and in that rectangle
///   the pixels that didn't change are transparent, so the previous frame shows through. A frame
///   where nothing changed isn't stored at all: the one before it stays up longer.
/// - Each frame has its own 255-colour palette, made by median cut from just the pixels that
///   changed, so a small change gets its colours exactly and a big one gets the best 255.
/// - No dithering: UI is mostly flat colour, and dither noise would make every frame "change".
///
/// Plain Swift with no image frameworks, so it builds and is tested on Linux too.
public struct GIFEncoder {
    public let width: Int
    public let height: Int
    /// How far (0–255, in any of red, green, blue) a pixel can drift from what was last drawn
    /// before it counts as changed. Hides video compression noise on still parts of the screen.
    public let tolerance: Int

    private var output: Data
    /// What each pixel's source colour was when it was last drawn, 3 bytes (RGB) a pixel.
    private var drawn: [UInt8]
    /// The frame waiting for its delay, which is known only once a frame that differs arrives.
    private var pending: (image: Data, start: Double, transparent: Bool)?
    private var elapsed = 0.0
    private var writtenCentiseconds = 0
    private var finished = false
    public private(set) var storedFrames = 0

    /// Shared scratch space for the palette, kept between frames to save allocations.
    private var quantizer = MedianCut()

    public init(width: Int, height: Int, tolerance: Int = 4) {
        precondition(width > 0 && height > 0 && width <= 0xFFFF && height <= 0xFFFF)
        self.width = width
        self.height = height
        self.tolerance = tolerance
        drawn = [UInt8](repeating: 0, count: width * height * 3)
        output = Data()
        output.append(contentsOf: Array("GIF89a".utf8))
        output.appendLE16(width)
        output.appendLE16(height)
        output.append(contentsOf: [0x00, 0x00, 0x00]) // no global colour table
        // Loop forever (NETSCAPE2.0 application extension).
        output.append(contentsOf: [0x21, 0xFF, 0x0B])
        output.append(contentsOf: Array("NETSCAPE2.0".utf8))
        output.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
    }

    /// Bytes so far, counting the frame still waiting for its delay.
    public var byteCount: Int { output.count + (pending?.image.count ?? 0) + 9 }

    /// Adds a frame shown for `duration` seconds. `rgba` is `height` rows of `bytesPerRow`
    /// bytes, 4 bytes a pixel in R, G, B, A order; alpha is ignored.
    public mutating func add(rgba: [UInt8], bytesPerRow: Int, duration: Double) {
        rgba.withUnsafeBufferPointer { add(rgba: $0, bytesPerRow: bytesPerRow, duration: duration) }
    }

    /// The same, reading the pixels where they are (e.g. a bitmap context's memory).
    public mutating func add(rgba: UnsafeBufferPointer<UInt8>, bytesPerRow: Int, duration: Double) {
        precondition(!finished, "add after finish")
        precondition(bytesPerRow >= width * 4 && rgba.count >= bytesPerRow * (height - 1) + width * 4)
        let first = pending == nil && storedFrames == 0
        let start = elapsed
        elapsed += max(0, duration)

        guard let box = changedBox(rgba, bytesPerRow: bytesPerRow, all: first) else { return }
        let image = encodeFrame(rgba, bytesPerRow: bytesPerRow, box: box, transparent: !first)
        flush(until: start)
        pending = (image, start, !first)
        storedFrames += 1
    }

    /// The finished GIF.
    public mutating func finish() -> Data {
        if !finished {
            flush(until: elapsed)
            output.append(0x3B)
            finished = true
        }
        return output
    }

    // MARK: - Frames

    private struct Box { var minX: Int, minY: Int, maxX: Int, maxY: Int }

    /// The smallest rectangle holding every changed pixel, or nil when none changed.
    private func changedBox(_ src: UnsafeBufferPointer<UInt8>, bytesPerRow: Int, all: Bool) -> Box? {
        if all { return Box(minX: 0, minY: 0, maxX: width - 1, maxY: height - 1) }
        var box = Box(minX: width, minY: height, maxX: -1, maxY: -1)
        let tolerance = self.tolerance
        drawn.withUnsafeBufferPointer { ref in
            for y in 0..<height {
                let row = y * bytesPerRow, refRow = y * width * 3
                var first = -1, last = -1
                for x in 0..<width {
                    let s = row + x * 4, r = refRow + x * 3
                    if abs(Int(src[s]) - Int(ref[r])) > tolerance
                        || abs(Int(src[s + 1]) - Int(ref[r + 1])) > tolerance
                        || abs(Int(src[s + 2]) - Int(ref[r + 2])) > tolerance {
                        if first < 0 { first = x }
                        last = x
                    }
                }
                if first >= 0 {
                    box.minX = min(box.minX, first)
                    box.maxX = max(box.maxX, last)
                    box.minY = min(box.minY, y)
                    box.maxY = y
                }
            }
        }
        return box.maxX < 0 ? nil : box
    }

    /// The image descriptor, local colour table and LZW data for `box`. Marks what it draws.
    private mutating func encodeFrame(_ src: UnsafeBufferPointer<UInt8>, bytesPerRow: Int, box: Box, transparent: Bool) -> Data {
        let boxWidth = box.maxX - box.minX + 1, boxHeight = box.maxY - box.minY + 1
        let tolerance = transparent ? self.tolerance : -1
        // Which pixels in the box changed, as 6-bit-per-channel colour keys; -1 means unchanged.
        var keys = [Int32](repeating: -1, count: boxWidth * boxHeight)
        quantizer.reset()
        drawn.withUnsafeMutableBufferPointer { ref in
            keys.withUnsafeMutableBufferPointer { keys in
                var i = 0
                for y in box.minY...box.maxY {
                    let row = y * bytesPerRow, refRow = y * width * 3
                    for x in box.minX...box.maxX {
                        let s = row + x * 4, r = refRow + x * 3
                        let red = src[s], green = src[s + 1], blue = src[s + 2]
                        if abs(Int(red) - Int(ref[r])) > tolerance
                            || abs(Int(green) - Int(ref[r + 1])) > tolerance
                            || abs(Int(blue) - Int(ref[r + 2])) > tolerance {
                            keys[i] = Int32(quantizer.add(red, green, blue))
                            ref[r] = red; ref[r + 1] = green; ref[r + 2] = blue
                        }
                        i += 1
                    }
                }
            }
        }
        let palette = quantizer.makePalette(maxColors: 255)
        let transparentIndex: UInt8 = 255

        var indices = [UInt8](repeating: transparentIndex, count: keys.count)
        for i in 0..<keys.count where keys[i] >= 0 {
            indices[i] = quantizer.index(ofKey: Int(keys[i]))
        }

        var image = Data()
        image.append(0x2C)
        image.appendLE16(box.minX)
        image.appendLE16(box.minY)
        image.appendLE16(boxWidth)
        image.appendLE16(boxHeight)
        image.append(0x80 | 0x07) // local colour table of 256 entries, not interlaced
        for i in 0..<256 {
            if i < palette.count {
                image.append(contentsOf: [palette[i].r, palette[i].g, palette[i].b])
            } else {
                image.append(contentsOf: [0, 0, 0])
            }
        }
        LZW.encode(indices, minCodeSize: 8, into: &image)
        return image
    }

    /// Writes the waiting frame, now that it's known to last until `end` seconds.
    private mutating func flush(until end: Double) {
        guard let frame = pending else { return }
        pending = nil
        // Delays are whole centiseconds; rounding the running total keeps the clip in time.
        // Browsers stretch delays under 2 cs to 10 cs, so never go below 2.
        let endCS = max(Int((end * 100).rounded()), writtenCentiseconds + 2)
        let delay = min(0xFFFF, endCS - writtenCentiseconds)
        writtenCentiseconds += delay
        // Graphic control extension: leave the frame in place (disposal 1), optional transparency.
        output.append(contentsOf: [0x21, 0xF9, 0x04, frame.transparent ? 0x05 : 0x04] as [UInt8])
        output.appendLE16(delay)
        output.append(contentsOf: [0xFF, 0x00])
        output.append(frame.image)
    }
}

// MARK: - Palette

/// Median cut over a 6-bit-per-channel histogram, weighted by how many pixels have each colour.
struct MedianCut {
    struct Color: Equatable { var r: UInt8, g: UInt8, b: UInt8 }

    private static let bins = 1 << 18
    private var count = [UInt32](repeating: 0, count: MedianCut.bins)
    private var sumR = [UInt32](repeating: 0, count: MedianCut.bins)
    private var sumG = [UInt32](repeating: 0, count: MedianCut.bins)
    private var sumB = [UInt32](repeating: 0, count: MedianCut.bins)
    private var lookup = [UInt8](repeating: 0, count: MedianCut.bins)
    private var used: [Int] = []

    mutating func reset() {
        for key in used { count[key] = 0; sumR[key] = 0; sumG[key] = 0; sumB[key] = 0 }
        used.removeAll(keepingCapacity: true)
    }

    /// Counts one pixel and returns its key.
    @inline(__always)
    mutating func add(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Int {
        let key = Int(r >> 2) << 12 | Int(g >> 2) << 6 | Int(b >> 2)
        if count[key] == 0 { used.append(key) }
        count[key] &+= 1
        sumR[key] &+= UInt32(r); sumG[key] &+= UInt32(g); sumB[key] &+= UInt32(b)
        return key
    }

    func index(ofKey key: Int) -> UInt8 { lookup[key] }

    private struct Cell {
        var start: Int, end: Int // into `used`, end exclusive
        var population: Int
        var lo: (Int, Int, Int), hi: (Int, Int, Int)
        var longest: (axis: Int, length: Int) {
            let r = hi.0 - lo.0, g = hi.1 - lo.1, b = hi.2 - lo.2
            // Green matters most to the eye, then red, so ties go that way.
            if g >= r && g >= b { return (1, g) }
            return r >= b ? (0, r) : (2, b)
        }
        var splittable: Bool { end - start > 1 }
    }

    private static func channel(_ key: Int, _ axis: Int) -> Int {
        switch axis {
        case 0: return key >> 12
        case 1: return (key >> 6) & 63
        default: return key & 63
        }
    }

    private func cell(_ start: Int, _ end: Int) -> Cell {
        var lo = (63, 63, 63), hi = (0, 0, 0), population = 0
        for i in start..<end {
            let key = used[i]
            let r = key >> 12, g = (key >> 6) & 63, b = key & 63
            lo = (min(lo.0, r), min(lo.1, g), min(lo.2, b))
            hi = (max(hi.0, r), max(hi.1, g), max(hi.2, b))
            population += Int(count[key])
        }
        return Cell(start: start, end: end, population: population, lo: lo, hi: hi)
    }

    /// Up to `maxColors` colours for everything added since `reset`, and sets up `index(ofKey:)`.
    mutating func makePalette(maxColors: Int) -> [Color] {
        guard !used.isEmpty else { return [] }
        var cells = [cell(0, used.count)]
        // Split by population first, so the big areas get accurate colours; then by population
        // times size, so small details (text, icons) still get their own colours.
        while cells.count < maxColors {
            let byVolume = cells.count >= maxColors / 2
            var best = -1, bestScore = 0.0
            for (i, c) in cells.enumerated() where c.splittable {
                let length = c.longest.length
                guard length > 0 else { continue }
                let score = byVolume ? Double(c.population) * Double(length) : Double(c.population)
                if score > bestScore { best = i; bestScore = score }
            }
            guard best >= 0 else { break }
            let c = cells[best]
            let axis = c.longest.axis
            let count = self.count
            used[c.start..<c.end].sort { Self.channel($0, axis) < Self.channel($1, axis) }
            // Split at the weighted median, keeping both halves non-empty.
            var running = 0, split = c.start + 1
            for i in c.start..<c.end {
                running += Int(count[used[i]])
                if running * 2 >= c.population { split = i + 1; break }
            }
            split = min(max(split, c.start + 1), c.end - 1)
            // Don't split one colour value across two cells.
            let value = Self.channel(used[split - 1], axis)
            var moved = split
            while moved < c.end, Self.channel(used[moved], axis) == value { moved += 1 }
            if moved == c.end {
                moved = split
                while moved > c.start + 1, Self.channel(used[moved - 1], axis) == Self.channel(used[moved], axis) { moved -= 1 }
            }
            split = moved
            cells[best] = cell(c.start, split)
            cells.append(cell(split, c.end))
        }
        var palette: [Color] = []
        palette.reserveCapacity(cells.count)
        for (index, c) in cells.enumerated() {
            var r = 0, g = 0, b = 0, n = 0
            for i in c.start..<c.end {
                let key = used[i]
                r += Int(sumR[key]); g += Int(sumG[key]); b += Int(sumB[key]); n += Int(count[key])
                lookup[key] = UInt8(index)
            }
            palette.append(Color(r: UInt8((r + n / 2) / n), g: UInt8((g + n / 2) / n), b: UInt8((b + n / 2) / n)))
        }
        return palette
    }
}

// MARK: - LZW

enum LZW {
    /// GIF's variable-width LZW, written as length-prefixed sub-blocks with the terminator.
    static func encode(_ indices: [UInt8], minCodeSize: Int, into out: inout Data) {
        out.append(UInt8(minCodeSize))
        var writer = BlockWriter()
        let clear = 1 << minCodeSize, end = clear + 1
        var codeSize = minCodeSize + 1
        var next = end + 1
        // (prefix code << 8 | byte) → code + 1; 0 means none. Cleared entry by entry on reset.
        var table = [UInt16](repeating: 0, count: 4096 << 8)
        var filled: [Int] = []
        filled.reserveCapacity(4096)

        writer.write(clear, bits: codeSize)
        guard var prefix = indices.first.map(Int.init) else {
            writer.write(end, bits: codeSize)
            writer.finish(into: &out)
            return
        }
        table.withUnsafeMutableBufferPointer { table in
            for i in 1..<indices.count {
                let byte = Int(indices[i])
                let slot = prefix << 8 | byte
                let found = Int(table[slot])
                if found != 0 {
                    prefix = found - 1
                    continue
                }
                writer.write(prefix, bits: codeSize)
                if next < 4096 {
                    table[slot] = UInt16(next + 1)
                    filled.append(slot)
                    next += 1
                    if next > 1 << codeSize, codeSize < 12 { codeSize += 1 }
                } else {
                    writer.write(clear, bits: codeSize)
                    for slot in filled { table[slot] = 0 }
                    filled.removeAll(keepingCapacity: true)
                    codeSize = minCodeSize + 1
                    next = end + 1
                }
                prefix = byte
            }
        }
        writer.write(prefix, bits: codeSize)
        writer.write(end, bits: codeSize)
        writer.finish(into: &out)
    }

    struct BlockWriter {
        private var bytes: [UInt8] = []
        private var buffer = 0, bufferBits = 0

        init() { bytes.reserveCapacity(1 << 16) }

        @inline(__always)
        mutating func write(_ code: Int, bits: Int) {
            buffer |= code << bufferBits
            bufferBits += bits
            while bufferBits >= 8 {
                bytes.append(UInt8(truncatingIfNeeded: buffer))
                buffer >>= 8
                bufferBits -= 8
            }
        }

        mutating func finish(into out: inout Data) {
            if bufferBits > 0 { bytes.append(UInt8(truncatingIfNeeded: buffer)) }
            var i = 0
            while i < bytes.count {
                let n = min(255, bytes.count - i)
                out.append(UInt8(n))
                out.append(contentsOf: bytes[i..<(i + n)])
                i += n
            }
            out.append(0x00)
        }
    }
}

private extension Data {
    mutating func appendLE16(_ value: Int) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }
}
