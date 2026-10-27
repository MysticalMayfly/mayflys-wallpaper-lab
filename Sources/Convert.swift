import AVFoundation
import AppKit
import VideoToolbox

/// Conversion, done once per library video (see Library.swift):
/// 1. The clip is re-encoded into Apple's aerial format: 3840×2160 landscape, 10-bit HEVC Main10, BT.709,
///    constant 239.76 fps, *with HEVC temporal layers* (TSA). On unlock the player "ramps down"
///    (slows to a stop) by stepping down through those layers; a single-layer file makes that step fail
///    ("failed to acquire next sample") and the player stays stuck. Apple's files have 5 layers
///    (15→240 fps); the Lab uses only Apple's hardware encoder (LayeredEncoder), which makes 4. Step 3 relabels
///    them into the five levels the player needs, without re-encoding (see Layers.swift).
///    The encoder's pattern repeats every 8 frames instead of 16, so the unlock can stop on any 4th frame:
///    always a real frame for 60 fps videos, half the time a generated one for 30 fps videos.
/// 2. The missing frames up to 240 fps are *interpolated* (VideoToolbox's ML frame-rate conversion),
///    not repeated, so the slow-motion start and stop are smooth instead of stepping.
///    If interpolation isn't available it falls back to repeating frames.
/// 3. The clip is laid back to back to `loopSeconds` with passthrough (no re-encoding), relabelling its levels.
extension Engine {
    static let outputSize = CGSize(width: 3840, height: 2160)
    static let bitRate = 12_000_000
    static let outputFrameDuration = CMTime(value: 1001, timescale: 240_000) // 239.76 fps, like Apple's

    /// The lock screen plays the aerial once and then holds the last frame, so short clips are
    /// repeated until they are at least this long. The display sleeps well before this runs out.
    static let loopSeconds = 300.0

    struct Output {
        let loop: URL
        let still: URL
        let thumb: URL
        let format: URL
    }

    static func outputs(in dir: URL) -> Output {
        Output(loop: dir.appendingPathComponent("loop.mov"),
               still: dir.appendingPathComponent("still.png"),
               thumb: dir.appendingPathComponent("thumb.jpg"),
               format: dir.appendingPathComponent("format.txt"))
    }

    /// Which encoder made a conversion. Library videos made with an older one are re-converted in the
    /// background (and stay playable meanwhile). Without x265 the hardware version is the current one.
    static let currentFormat = "lab-hw-5level-v2"
    /// The earlier hardware format, whose loops only need their levels relabelled (`upgradeLevels`).
    static let fourLevelFormat = "lab-hw-4layer-v1"

    /// Converts `video` into `dir` (loop.mov, still.png, thumb.jpg). `progress` goes from 0 to 1.
    static func convert(_ video: URL, into dir: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = outputs(in: dir)
        let clip = dir.appendingPathComponent(".clip-\(UUID().uuidString).mov")
        let loop = dir.appendingPathComponent(".loop-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: clip); try? fm.removeItem(at: loop) }

        let madeWith = try await encodeClip(video, to: clip) { progress($0 * 0.95) }
        try await writeLoop(of: clip, to: loop)
        let still = try await stillImage(of: clip)
        let thumb = try await stillImage(of: clip, maxWidth: 640)
        guard let png = still.pngData, let jpg = thumb.jpegData else {
            throw Failure.exportFailed("couldn't make the desktop still")
        }
        try png.write(to: out.still, options: .atomic)
        try jpg.write(to: out.thumb, options: .atomic)
        try? fm.removeItem(at: out.loop)
        try fm.moveItem(at: loop, to: out.loop)
        try madeWith.write(to: out.format, atomically: true, encoding: .utf8)
        progress(1)
    }

    /// Reads the source scaled/cropped to 3840×2160, fills in frames up to 239.76 fps and encodes with
    /// VideoToolbox directly (AVAssetWriter won't pass the temporal-layer setting through).
    /// Returns the format it was made in (see `currentFormat`).
    static func encodeClip(_ video: URL, to out: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.exportFailed("no video track")
        }
        let (natural, transform, duration) = try await (
            track.load(.naturalSize), track.load(.preferredTransform), asset.load(.duration))

        // Undo the clip's rotation, then scale to fill 3840×2160 and centre it (crops the overflow).
        let rotated = CGRect(origin: .zero, size: natural).applying(transform)
        let shown = CGSize(width: abs(rotated.width), height: abs(rotated.height))
        let scale = max(outputSize.width / shown.width, outputSize.height / shown.height)
        let fit = transform
            .concatenating(CGAffineTransform(translationX: -rotated.minX, y: -rotated.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: (outputSize.width - shown.width * scale) / 2,
                                             y: (outputSize.height - shown.height * scale) / 2))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(fit, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = outputSize
        // A very fine grid so every source frame comes through once, with its own timestamp (a coarse grid
        // re-stamps frames onto it).
        composition.frameDuration = CMTime(value: 1, timescale: 240_000)
        composition.instructions = [instruction]
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        // The interpolator wants half-float RGBA frames; without it, 10-bit YUV is cheaper.
        let interpolator = Interpolator()
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: interpolator != nil
                ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        reader.add(output)

        // The Lab uses Apple's hardware encoder only (4 temporal layers) — no x265.
        let encoder: FrameEncoder = try LayeredEncoder(output: out)
        guard reader.startReading() else { throw Failure.exportFailed(reader.error?.localizedDescription ?? "can't read video") }

        let plan = try await RealFramePlan(asset: asset, track: track)

        try await Task.detached {
            var interpolator = interpolator
            var decoded = -1 // number of the last source frame read
            var current: CVPixelBuffer?
            func sourceFrame(_ number: Int) throws -> CVPixelBuffer {
                while decoded < number {
                    guard let sample = output.copyNextSampleBuffer() else {
                        throw Failure.exportFailed(reader.error?.localizedDescription ?? "video ended early")
                    }
                    guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                    current = buffer
                    decoded += 1
                }
                return current!
            }
            func time(_ index: Int) -> CMTime { CMTimeMultiply(outputFrameDuration, multiplier: Int32(index)) }

            do {
                var previous = plan.anchors[0]
                var previousBuffer = try sourceFrame(previous.frame)
                for anchor in plan.anchors.dropFirst() {
                    let buffer = try sourceFrame(anchor.frame)
                    // The real frame, then the generated frames up to the next real one.
                    try encoder.encode(previousBuffer, at: time(previous.index))
                    let between = Array((previous.index + 1)..<min(anchor.index, plan.frameCount))
                    var made: [CVPixelBuffer] = []
                    if !between.isEmpty, anchor.frame != previous.frame, let current = interpolator {
                        let span = Float(anchor.index - previous.index)
                        do {
                            made = try await current.frames(between: previousBuffer, at: time(previous.index), and: buffer, at: time(anchor.index),
                                                            phases: between.map { Float($0 - previous.index) / span }, times: between.map(time))
                        } catch {
                            interpolator = nil // keep going by repeating frames
                        }
                    }
                    for (i, index) in between.enumerated() {
                        try encoder.encode(i < made.count ? made[i] : previousBuffer, at: time(index))
                    }
                    if anchor.index >= plan.frameCount { break }
                    previous = anchor
                    previousBuffer = buffer
                    progress(Double(anchor.index) / Double(plan.frameCount))
                }
            } catch {
                reader.cancelReading()
                throw error
            }
            reader.cancelReading()
            interpolator?.end()
        }.value
        try await encoder.finish()
        return currentFormat
    }

    /// Repeats the already-encoded clip back to back as one continuous video: every copy's frames are re-timed
    /// to follow on at exact 1/239.76 s steps, with their levels relabelled for the player (`LayerLayout`). (Joining copies with an export
    /// session stored each copy's length rounded to 1/600 s, a third of a frame short: the timeline jumped at
    /// every join, which made the unlock slow-down step back and forth and could leave the desktop gray.)
    static func writeLoop(of clip: URL, to dest: URL) async throws {
        let asset = AVURLAsset(url: clip)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let format = try await track.load(.formatDescriptions).first else {
            throw Failure.exportFailed("converted clip has no video")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil) // compressed samples, untouched
        reader.add(output)
        guard reader.startReading() else { throw Failure.exportFailed(reader.error?.localizedDescription ?? "can't read clip") }
        var samples: [CMSampleBuffer] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { samples.append(sample) }
        }
        guard !samples.isEmpty else { throw Failure.exportFailed("converted clip is empty") }
        let clipLength = CMTimeMultiply(outputFrameDuration, multiplier: Int32(samples.count))
        let repeats = max(1, Int((loopSeconds / max(clipLength.seconds, 0.001)).rounded(.up)))
        if let layout = try LayerLayout(format: format) {
            samples = try samples.map { sample in
                let frame = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds / outputFrameDuration.seconds).rounded())
                return try layout.relabel(sample, frame: frame)
            }
        }

        let writer = try AVAssetWriter(outputURL: dest, fileType: .mov)
        writer.movieTimeScale = outputFrameDuration.timescale
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                       sourceFormatHint: samples.first.flatMap(CMSampleBufferGetFormatDescription) ?? format)
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = outputFrameDuration.timescale
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? Failure.exportFailed("can't write loop") }
        writer.startSession(atSourceTime: .zero)
        for copy in 0..<repeats {
            let shift = CMTimeMultiply(clipLength, multiplier: Int32(copy))
            for sample in samples {
                var timing = CMSampleTimingInfo()
                CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing)
                timing.presentationTimeStamp = CMTimeAdd(timing.presentationTimeStamp, shift)
                timing.decodeTimeStamp = CMTimeAdd(timing.decodeTimeStamp, shift)
                var moved: CMSampleBuffer?
                CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                                      sampleTimingArray: &timing, sampleBufferOut: &moved)
                guard let moved else { throw Failure.exportFailed("can't re-time loop") }
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                guard input.append(moved) else { throw writer.error ?? Failure.exportFailed("writing loop stopped") }
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.exportFailed("writing loop stopped") }
        try sortLevelTable(in: dest)
    }

    /// Brings a loop made in the four-level format up to date: the same frames, relabelled (no re-encoding).
    static func upgradeLevels(in dir: URL) async throws {
        let out = outputs(in: dir)
        let loop = dir.appendingPathComponent(".loop-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: loop) }
        try await writeLoop(of: out.loop, to: loop) // already long enough, so written once
        _ = try fm.replaceItemAt(out.loop, withItemAt: loop)
        try currentFormat.write(to: out.format, atomically: true, encoding: .utf8)
    }

    /// First frame of the converted clip — what the desktop shows by default instead of the aerial.
    static func stillImage(of clip: URL, maxWidth: CGFloat? = nil) async throws -> NSImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip))
        generator.appliesPreferredTrackTransform = true
        if let maxWidth { generator.maximumSize = CGSize(width: maxWidth, height: maxWidth) }
        let (image, _) = try await generator.image(at: .zero)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// Where the real (source) frames go in the 239.76 fps output.
///
/// When you unlock, Apple's player slows the aerial to a stop and always stops on a frame of temporal layer 0
/// or 1 — in the 16-frame layer pattern, positions 0 and 8, i.e. every 8th frame (29.97 per second).
/// So every 8th output frame is made a real frame, and the frames in between are interpolated:
/// - 29.97/30 fps sources: source frame k at output 8k (a 30.00 fps clip plays 0.1% slower);
/// - 59.94/60 fps: frame k at 4k (every 4th is real, which covers every 8th); same for 15, 120, 240 fps;
/// - other rates (24, 25, 50 fps…): every 8th output frame shows the source frame nearest in time; speed stays
///   right, but some real frames repeat (a slight hitch, like film-to-TV conversion) or are skipped.
/// The clip is cut to whole 16-frame groups so the pattern stays the same each time the loop repeats it.
struct RealFramePlan {
    struct Anchor { let index: Int; let frame: Int }
    let anchors: [Anchor]
    /// Output frames in the clip (a multiple of 16).
    let frameCount: Int

    init(asset: AVAsset, track: AVAssetTrack) async throws {
        // Source frame times, in display order (no decoding needed).
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw Engine.Failure.exportFailed("can't read video") }
        var mediaTimes: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 { mediaTimes.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
        }
        // Those are times in the file's media; a file can have edits that show only part of it (e.g. a trimmed
        // trailer that starts 3 s in). Keep only frames that are shown, at the times they're shown — exactly the
        // frames the crop step delivers.
        let segments = try await track.load(.segments).filter { !$0.isEmpty }
        var times: [Double] = []
        for time in mediaTimes {
            if segments.isEmpty { times.append(time); continue }
            for segment in segments {
                let source = segment.timeMapping.source, target = segment.timeMapping.target
                guard time >= source.start.seconds - 0.0001, time < source.end.seconds - 0.0001 else { continue }
                let rate = source.duration.seconds > 0 ? target.duration.seconds / source.duration.seconds : 1
                times.append(target.start.seconds + (time - source.start.seconds) * rate)
                break
            }
        }
        times.sort()
        guard times.count >= 2 else { throw Engine.Failure.exportFailed("video too short") }

        let gaps = zip(times.dropFirst(), times).map { $0 - $1 }.filter { $0 > 0.001 }.sorted()
        let frameRate = 1 / (gaps.isEmpty ? 1.0 / 30 : gaps[gaps.count / 2])
        let slotRate = 1 / (Engine.outputFrameDuration.seconds * 8) // 29.97: one real frame per 8 output frames

        var anchors: [Anchor] = []
        if let spacing = [8, 4, 2, 1, 16].first(where: { abs(frameRate / (slotRate * 8 / Double($0)) - 1) < 0.012 }) {
            anchors = times.indices.map { Anchor(index: $0 * spacing, frame: $0) }
        } else {
            let slots = Int(((times.last! - times[0]) * slotRate).rounded(.down)) + 1
            var k = 0
            for slot in 0..<slots {
                let target = times[0] + Double(slot) / slotRate
                while k + 1 < times.count, abs(times[k + 1] - target) <= abs(times[k] - target) { k += 1 }
                anchors.append(Anchor(index: slot * 8, frame: k))
            }
        }
        // Whole 16-frame groups; the anchor at the cut is only used to interpolate towards.
        let count = max(16, anchors.last!.index / 16 * 16)
        if anchors.last!.index < count { anchors.append(Anchor(index: count, frame: anchors.last!.frame)) }
        self.anchors = anchors
        self.frameCount = count
    }
}

/// VideoToolbox's ML frame-rate conversion at 3840×2160. `nil` when the Mac doesn't support it.
final class Interpolator: @unchecked Sendable {
    private let processor = VTFrameProcessor()
    private let pool: CVPixelBufferPool
    private var sequential = false

    init?() {
        guard VTFrameRateConversionConfiguration.isSupported,
              let config = VTFrameRateConversionConfiguration(
                frameWidth: Int(Engine.outputSize.width), frameHeight: Int(Engine.outputSize.height),
                usePrecomputedFlow: false, qualityPrioritization: .normal,
                revision: VTFrameRateConversionConfiguration.defaultRevision)
        else { return nil }
        var created: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, config.destinationPixelBufferAttributes as CFDictionary, &created)
        guard let created, (try? processor.startSession(configuration: config)) != nil else { return nil }
        pool = created
    }

    /// New frames between `a` and `b`, one per phase (0…1 = position between them).
    func frames(between a: CVPixelBuffer, at ta: CMTime, and b: CVPixelBuffer, at tb: CMTime,
                phases: [Float], times: [CMTime]) async throws -> [CVPixelBuffer] {
        guard let source = VTFrameProcessorFrame(buffer: a, presentationTimeStamp: ta),
              let next = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: tb) else {
            throw Engine.Failure.exportFailed("interpolation input")
        }
        var buffers: [CVPixelBuffer] = []
        var destinations: [VTFrameProcessorFrame] = []
        for time in times {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer, let frame = VTFrameProcessorFrame(buffer: buffer, presentationTimeStamp: time) else {
                throw Engine.Failure.exportFailed("interpolation output")
            }
            CVBufferPropagateAttachments(a, buffer) // keep the BT.709 colour tags for the encoder
            buffers.append(buffer)
            destinations.append(frame)
        }
        guard let parameters = VTFrameRateConversionParameters(
            sourceFrame: source, nextFrame: next, opticalFlow: nil, interpolationPhase: phases,
            submissionMode: sequential ? .sequential : .random, destinationFrames: destinations)
        else { throw Engine.Failure.exportFailed("interpolation parameters") }
        sequential = true
        // The completion-handler form: the async overload returned before the work was done.
        let error: Error? = await withCheckedContinuation { done in
            processor.process(parameters: parameters) { _, error in done.resume(returning: error) }
        }
        if let error { throw error }
        return buffers
    }

    func end() { processor.endSession() }
}

/// What `Engine.encodeClip` feeds frames into.
protocol FrameEncoder: AnyObject, Sendable {
    func encode(_ buffer: CVPixelBuffer, at time: CMTime) throws
    func finish() async throws
}

/// Hardware HEVC encoder producing temporal layers, writing the compressed frames into a .mov.
/// The writer is created when the first frame comes out, because it needs that frame's format.
final class LayeredEncoder: FrameEncoder, @unchecked Sendable {
    private let session: VTCompressionSession
    private let url: URL
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var failure: Error?
    private var pending = 0

    /// Interpolated 4K frames are large; don't let more than this many wait inside the encoder.
    private let maxPending = 24

    init(output url: URL) throws {
        self.url = url
        var created: VTCompressionSession?
        let size = Engine.outputSize
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(size.width), height: Int32(size.height), codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let created else { throw Engine.Failure.exportFailed("HEVC encoder unavailable (\(status))") }
        session = created
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main10_AutoLevel,
            kVTCompressionPropertyKey_RealTime: false,
            kVTCompressionPropertyKey_AverageBitRate: Engine.bitRate,
            kVTCompressionPropertyKey_ExpectedFrameRate: 240,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 1200, // a keyframe every 5 s, like Apple's
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality: true,
            // Asking for a 15 fps base layer gives the most layers the hardware supports (30/60/120/240 fps).
            kVTCompressionPropertyKey_BaseLayerFrameRate: 15,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ buffer: CVPixelBuffer, at time: CMTime) throws {
        while lock.withLock({ pending >= maxPending && failure == nil }) { usleep(1000) }
        if let failure = lock.withLock({ self.failure }) { throw failure }
        lock.withLock { pending += 1 }
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: buffer, presentationTimeStamp: time, duration: Engine.outputFrameDuration,
            frameProperties: nil, infoFlagsOut: nil) { [self] status, _, sample in
            defer { lock.withLock { pending -= 1 } }
            guard status == noErr, let sample else {
                fail(Engine.Failure.exportFailed("encoder error \(status)"))
                return
            }
            write(sample)
        }
        if status != noErr {
            lock.withLock { pending -= 1 }
            throw Engine.Failure.exportFailed("encoder error \(status)")
        }
    }

    func finish() async throws {
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        if let failure = lock.withLock({ self.failure }) { throw failure }
        guard let writer, let input else { throw Engine.Failure.exportFailed("no frames were encoded") }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw Engine.Failure.exportFailed(writer.error?.localizedDescription ?? "writing stopped")
        }
    }

    /// Called on VideoToolbox's output thread, one frame at a time in decode order.
    private func write(_ sample: CMSampleBuffer) {
        do {
            if writer == nil {
                let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil,
                                               sourceFormatHint: CMSampleBufferGetFormatDescription(sample))
                input.expectsMediaDataInRealTime = false
                input.mediaTimeScale = Engine.outputFrameDuration.timescale // exact 1001/240000 s frames
                writer.add(input)
                guard writer.startWriting() else { throw writer.error ?? Engine.Failure.exportFailed("can't write video") }
                writer.startSession(atSourceTime: .zero)
                self.writer = writer
                self.input = input
            }
            guard let input else { return }
            while !input.isReadyForMoreMediaData { usleep(500) }
            if !input.append(sample) {
                throw writer?.error ?? Engine.Failure.exportFailed("writing stopped")
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        lock.withLock { if failure == nil { failure = error } }
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    var jpegData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }

}
