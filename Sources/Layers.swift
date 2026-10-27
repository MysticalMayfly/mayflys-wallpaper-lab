import AVFoundation

/// Turns the hardware encoder's temporal levels into the five-level layout the wallpaper player needs — without
/// re-encoding, only by relabelling.
///
/// What the player does with the levels (found from its logs on macOS 27):
/// - on lock it speeds the video up playing level 0 *alone*, then moves to level 1 at a level-1 switch point
///   (a TSA frame), and plays level 1 from then on;
/// - on unlock it steps through levels 1 → 2 → 3 → 4 while slowing down and stops on a level 0/1 frame;
/// - it takes the number of levels from the hvcC box and each frame's level from the 'tscl' sample-group table,
///   by the table's order. Without five declared levels it skips the stepping and the stop stutters.
/// The hardware encoder makes four levels (an 8-frame pattern 0 3 2 3 1 3 2 3), declares one in hvcC and
/// marks no level-1 frame as a switch point (they are safe switch points; decoding confirmed it).
/// `LayerLayout` keeps levels 0–2, splits level 3 (the odd frames, which nothing references) into levels 3 and
/// 4, marks every frame above level 0 as a switch point (TSA NAL types and attachments) and rewrites hvcC and
/// the VPS/SPS to declare five levels. `sortLevelTable` then puts the 'tscl' table in level order (the writer
/// lists levels in the order it first meets them, which here is 0, 1, 2, 4, 3).
struct LayerLayout {
    let format: CMFormatDescription

    /// `nil` when the video already declares five levels (nothing to do).
    init?(format old: CMFormatDescription) throws {
        var extensions = CMFormatDescriptionGetExtensions(old) as? [String: Any] ?? [:]
        var atoms = extensions["SampleDescriptionExtensionAtoms"] as? [String: Any] ?? [:]
        guard let hvcC = atoms["hvcC"] as? Data, hvcC.count > 23 else { throw Engine.Failure.exportFailed("no HEVC header") }
        let h = [UInt8](hvcC)
        if (h[21] >> 3) & 7 == 5 { return nil }

        var out = Array(h[0..<23])
        out[21] = (h[21] & 0b1100_0011) | (5 << 3) // numTemporalLayers = 5
        var i = 23
        for _ in 0..<Int(h[22]) {
            let type = h[i] & 0x3f
            let count = Int(h[i + 1]) << 8 | Int(h[i + 2])
            out += h[i..<(i + 3)]
            i += 3
            for _ in 0..<count {
                let length = Int(h[i]) << 8 | Int(h[i + 1])
                var nal = Array(h[(i + 2)..<(i + 2 + length)])
                i += 2 + length
                if type == 32 { nal = ParameterSets.vps(nal, maxSubLayersMinus1: 4) }
                if type == 33 { nal = ParameterSets.sps(nal, maxSubLayersMinus1: 4) }
                out += [UInt8(nal.count >> 8), UInt8(nal.count & 0xff)] + nal
            }
        }
        atoms["hvcC"] = Data(out)
        extensions["SampleDescriptionExtensionAtoms"] = atoms
        extensions.removeValue(forKey: "VerbatimSampleDescription") // would override the new hvcC
        let size = CMVideoFormatDescriptionGetDimensions(old)
        var created: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_HEVC, width: size.width,
                                                    height: size.height, extensions: extensions as CFDictionary,
                                                    formatDescriptionOut: &created)
        guard status == noErr, let created else { throw Engine.Failure.exportFailed("can't relabel layers (\(status))") }
        format = created
    }

    /// The same compressed frame with its new level. `frame` is its position in display order.
    func relabel(_ sample: CMSampleBuffer, frame: Int) throws -> CMSampleBuffer {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { throw Engine.Failure.exportFailed("empty frame") }
        let attachments = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [NSDictionary])?.first ?? [:]
        let info = attachments["HEVCTemporalLevelInfo"] as? NSDictionary
        let old = info?["TemporalLevel"] as? Int ?? 0
        let level = old < 3 ? old : (frame % 4 == 1 ? 3 : 4)

        // NAL headers: temporal ID, and TRAIL → TSA above level 0. Parameter sets stay at level 0.
        var data = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: data.count, destination: &data)
        var i = 0
        while i + 6 <= data.count {
            let length = Int(data[i]) << 24 | Int(data[i + 1]) << 16 | Int(data[i + 2]) << 8 | Int(data[i + 3])
            var type = (data[i + 4] >> 1) & 0x3f
            if !(32...34).contains(type) {
                if level >= 1 && type == 0 { type = 2 } // TRAIL_N → TSA_N
                if level >= 1 && type == 1 { type = 3 } // TRAIL_R → TSA_R
                data[i + 4] = (data[i + 4] & 0x81) | (type << 1)
                data[i + 5] = (data[i + 5] & ~7) | UInt8(level + 1)
            }
            i += 4 + length
        }

        var newBlock: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0,
                                           blockBufferOut: &newBlock)
        guard let newBlock else { throw Engine.Failure.exportFailed("out of memory") }
        data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: newBlock, offsetIntoDestination: 0, dataLength: data.count) }
        var timing = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
        var size = data.count
        var created: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: newBlock, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &created)
        guard let created, let array = CMSampleBufferGetSampleAttachmentsArray(created, createIfNecessary: true),
              CFArrayGetCount(array) > 0 else { throw Engine.Failure.exportFailed("can't relabel frame") }
        let labels = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: NSMutableDictionary.self)
        labels.addEntries(from: attachments as? [AnyHashable: Any] ?? [:])
        if let info, level != old {
            let changed = info.mutableCopy() as! NSMutableDictionary
            changed["TemporalLevel"] = level
            labels["HEVCTemporalLevelInfo"] = changed
        }
        if level >= 1 { labels["HEVCTemporalSubLayerAccess"] = true }
        return created
    }
}

/// Rewrites the sub-layer count in HEVC parameter sets (bit-level: the fields after it shift).
private enum ParameterSets {
    struct Reader {
        let bytes: [UInt8]
        var bit = 0
        mutating func u(_ n: Int) -> UInt64 {
            var value: UInt64 = 0
            for _ in 0..<n {
                value = value << 1 | UInt64((bytes[bit >> 3] >> (7 - UInt8(bit & 7))) & 1)
                bit += 1
            }
            return value
        }
        mutating func ue() -> UInt64 {
            var zeros = 0
            while u(1) == 0 { zeros += 1 }
            return (1 << zeros) - 1 + u(zeros)
        }
    }

    struct Writer {
        var bytes: [UInt8] = []
        var bit = 0
        mutating func u(_ n: Int, _ value: UInt64) {
            for i in stride(from: n - 1, through: 0, by: -1) {
                if bit & 7 == 0 { bytes.append(0) }
                if (value >> UInt64(i)) & 1 == 1 { bytes[bit >> 3] |= 1 << (7 - UInt8(bit & 7)) }
                bit += 1
            }
        }
        mutating func ue(_ value: UInt64) {
            let n = 64 - (value + 1).leadingZeroBitCount
            u(n - 1, 0)
            u(n, value + 1)
        }
    }

    static func vps(_ nal: [UInt8], maxSubLayersMinus1 new: Int) -> [UInt8] {
        var r = Reader(bytes: unescape(Array(nal[2...]))), w = Writer()
        copy(&r, &w, 12) // id, base layer flags, max_layers_minus1
        let old = Int(r.u(3)); w.u(3, UInt64(new))
        copy(&r, &w, 17) // temporal_id_nesting, reserved 0xffff
        profileTierLevel(&r, &w, old, new)
        orderingInfo(&r, &w, old, new)
        return Array(nal[0..<2]) + escape(rest(&r, &w))
    }

    static func sps(_ nal: [UInt8], maxSubLayersMinus1 new: Int) -> [UInt8] {
        var r = Reader(bytes: unescape(Array(nal[2...]))), w = Writer()
        copy(&r, &w, 4) // vps id
        let old = Int(r.u(3)); w.u(3, UInt64(new))
        copy(&r, &w, 1) // temporal_id_nesting
        profileTierLevel(&r, &w, old, new)
        w.ue(r.ue()) // sps id
        let chroma = r.ue(); w.ue(chroma)
        if chroma == 3 { copy(&r, &w, 1) }
        w.ue(r.ue()); w.ue(r.ue()) // width, height
        let window = r.u(1); w.u(1, window)
        if window == 1 { for _ in 0..<4 { w.ue(r.ue()) } }
        w.ue(r.ue()); w.ue(r.ue()); w.ue(r.ue()) // bit depths, log2_max_pic_order_cnt_lsb_minus4
        orderingInfo(&r, &w, old, new)
        return Array(nal[0..<2]) + escape(rest(&r, &w))
    }

    private static func copy(_ r: inout Reader, _ w: inout Writer, _ bits: Int) {
        var left = bits
        while left > 0 {
            let n = min(left, 32)
            w.u(n, r.u(n))
            left -= n
        }
    }

    private static func profileTierLevel(_ r: inout Reader, _ w: inout Writer, _ old: Int, _ new: Int) {
        copy(&r, &w, 96) // general profile (88 bits) + level
        var profile: [UInt64] = [], level: [UInt64] = []
        for _ in 0..<old { profile.append(r.u(1)); level.append(r.u(1)) }
        if old > 0 { _ = r.u(2 * (8 - old)) }
        for i in 0..<new { w.u(1, i < old ? profile[i] : 0); w.u(1, i < old ? level[i] : 0) }
        if new > 0 { w.u(2 * (8 - new), 0) }
        for i in 0..<old {
            if profile[i] == 1 { copy(&r, &w, 88) }
            if level[i] == 1 { copy(&r, &w, 8) }
        }
    }

    /// Buffering/reordering per sub-layer; the new sub-layer gets the same values as the highest old one.
    private static func orderingInfo(_ r: inout Reader, _ w: inout Writer, _ old: Int, _ new: Int) {
        let perLayer = r.u(1); w.u(1, perLayer)
        var rows: [[UInt64]] = []
        for _ in (perLayer == 1 ? 0 : old)...old { rows.append([r.ue(), r.ue(), r.ue()]) }
        if perLayer == 1 { while rows.count < new + 1 { rows.append(rows.last!) } }
        for row in rows { row.forEach { w.ue($0) } }
    }

    /// Copies the remaining fields up to the stop bit, then ends the new payload with its own stop bit.
    private static func rest(_ r: inout Reader, _ w: inout Writer) -> [UInt8] {
        var last = r.bytes.count * 8 - 1
        while (r.bytes[last >> 3] >> (7 - UInt8(last & 7))) & 1 == 0 { last -= 1 }
        copy(&r, &w, last - r.bit)
        w.u(1, 1)
        while w.bit & 7 != 0 { w.u(1, 0) }
        return w.bytes
    }

    private static func unescape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [], zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte == 3 { zeros = 0; continue }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }

    private static func escape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [], zeros = 0
        for byte in bytes {
            if zeros >= 2 && byte <= 3 { out.append(3); zeros = 0 }
            out.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return out
    }
}

extension Engine {
    /// Puts the 'tscl' sample-group table of a written .mov in level order (0, 1, 2, …) and renumbers the frames'
    /// references to it. Only the movie header is rewritten, in place; sizes don't change.
    static func sortLevelTable(in file: URL) throws {
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var offset: UInt64 = 0
        while offset + 8 <= end {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { break }
            let h = [UInt8](header)
            var size = UInt64(be32(h, 0))
            if size == 1, h.count >= 16 { size = UInt64(be32(h, 8)) << 32 | UInt64(be32(h, 12)) }
            if size == 0 { size = end - offset }
            if h[4...7].elementsEqual("moov".utf8) {
                try handle.seek(toOffset: offset)
                guard var moov = try handle.read(upToCount: Int(size)).map({ [UInt8]($0) }) else { return }
                if sortLevelTable(&moov, from: 8, to: moov.count) {
                    try handle.seek(toOffset: offset)
                    try handle.write(contentsOf: Data(moov))
                }
                return
            }
            offset += size
        }
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    /// Walks trak/mdia/minf/stbl and patches the tscl table and its users. Returns whether anything changed.
    private static func sortLevelTable(_ b: inout [UInt8], from start: Int, to end: Int) -> Bool {
        var boxes: [(type: String, body: Int, end: Int)] = []
        var pos = start
        while pos + 8 <= end {
            let size = Int(be32(b, pos))
            guard size >= 8, pos + size <= end else { break }
            boxes.append((String(decoding: b[(pos + 4)..<(pos + 8)], as: UTF8.self), pos + 8, pos + size))
            pos += size
        }
        var changed = false
        for box in boxes where ["trak", "mdia", "minf"].contains(box.type) {
            changed = sortLevelTable(&b, from: box.body, to: box.end) || changed
        }
        guard boxes.contains(where: { $0.type == "stsd" }) else { return changed }

        // The table: version 1 'sgpd' with fixed-size entries; an entry's first byte is its level.
        var renumber: [Int: Int] = [:]
        for box in boxes where box.type == "sgpd" && b[box.body] == 1 && b[(box.body + 4)..<(box.body + 8)].elementsEqual("tscl".utf8) {
            let length = Int(be32(b, box.body + 8)), count = Int(be32(b, box.body + 12)), first = box.body + 16
            guard length > 0 else { continue }
            let entries = (0..<count).map { Array(b[(first + $0 * length)..<(first + ($0 + 1) * length)]) }
            let order = entries.indices.sorted { entries[$0][0] < entries[$1][0] }
            guard order != Array(entries.indices) else { return changed }
            for (new, old) in order.enumerated() {
                b.replaceSubrange((first + new * length)..<(first + (new + 1) * length), with: entries[old])
                renumber[old + 1] = new + 1
            }
        }
        guard !renumber.isEmpty else { return changed }

        for box in boxes {
            let body = box.body
            if box.type == "csgm" && b[(body + 4)..<(body + 8)].elementsEqual("tscl".utf8) {
                // As AVAssetWriter writes it: version/flags, grouping type, parameter, index size in bits,
                // pattern count, (pattern length, sample count) pairs, then the indices packed at that size.
                let bits = Int(be32(b, body + 12)), patterns = Int(be32(b, body + 16))
                var bit = (body + 20 + 8 * patterns) * 8
                let total = (0..<patterns).reduce(0) { $0 + Int(be32(b, body + 20 + 8 * $1)) }
                for _ in 0..<total {
                    var value = 0
                    for k in 0..<bits { value = value << 1 | Int((b[(bit + k) >> 3] >> (7 - UInt8((bit + k) & 7))) & 1) }
                    if let new = renumber[value] {
                        for k in 0..<bits {
                            let byte = (bit + k) >> 3, shift = 7 - UInt8((bit + k) & 7)
                            b[byte] = (b[byte] & ~(1 << shift)) | UInt8((new >> (bits - 1 - k)) & 1) << shift
                        }
                    }
                    bit += bits
                }
            }
            if box.type == "sbgp" && b[(body + 4)..<(body + 8)].elementsEqual("tscl".utf8) {
                let first = body + 8 + (b[body] == 1 ? 4 : 0)
                for k in 0..<Int(be32(b, first)) {
                    let at = first + 4 + 8 * k + 4
                    if let new = renumber[Int(be32(b, at))] {
                        b.replaceSubrange(at..<(at + 4), with: withUnsafeBytes(of: UInt32(new).bigEndian, Array.init))
                    }
                }
            }
        }
        return true
    }
}
