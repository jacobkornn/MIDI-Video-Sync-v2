import Foundation
import AVFoundation
import AppKit
import CoreImage
import ImageIO

@MainActor
final class VideoSamplerModel: ObservableObject {

    // MARK: - Public bindings

    @Published var duration: Double = 0
    @Published var winStart: Double = 0.0      // global 0–1
    @Published var winEnd: Double = 1.0        // global 0–1
    @Published var status: String = "No video"
    @Published var videoSize = CGSize(width: 360, height: 640)

    @Published var latencyOffsetSec: Double = 0.0

    // Auto mode: continuous playback toggle
    @Published var autoContinuous: Bool = false

    enum WarpMode: Hashable {
        case linear
        case rate
    }

    @Published var warpMode: WarpMode = .linear
    var playbackRate: Float = 1.0

    // MARK: - Slice modes (expanded)

    enum SliceMode: Hashable {
        case auto
        case manual
        case chrom      // NEW
        case random     // NEW
    }

    @Published var sliceMode: SliceMode = .auto

    // MARK: - Manual window-relative slices

    /// All timing info is WINDOW-RELATIVE (0–1), not absolute video time.
    struct Slice: Identifiable, Hashable {
        let id: UUID
        /// Center position 0–1 inside the window
        var centerN: Double
        /// Half width 0–0.5 inside the window
        var halfWidthN: Double
        /// MIDI notes mapped to this slice
        var assignedNotes: Set<Int>

        init(
            id: UUID = UUID(),
            centerN: Double,
            halfWidthN: Double = 0.05,
            assignedNotes: Set<Int> = []
        ) {
            self.id = id
            self.centerN = centerN
            self.halfWidthN = halfWidthN
            self.assignedNotes = assignedNotes
        }

        var startN: Double { centerN - halfWidthN }
        var endN: Double { centerN + halfWidthN }
    }

    /// Slices are kept in memory regardless of sliceMode; auto mode just ignores them.
    @Published var slices: [Slice] = []

    // MARK: - Chromatic mode (virtual slices, non-deletable)

    /// Base octave for chromatic mode (C3 by default).
    @Published var chromaticBaseOctave: Int = 3

    /// Always 2 octaves in chromatic mode.
    let chromaticSliceCount: Int = 24

    /// MIDI notes used in Chrom mode (C<baseOctave> … B<baseOctave+1>).
    func chromaticNotes() -> [Int] {
        // Matches midiNoteName logic in ContentView: octave = note/12 - 2
        // So C(octave) = 12 * (octave + 2)
        let baseMidi = (chromaticBaseOctave + 2) * 12
        return (0..<chromaticSliceCount).map { baseMidi + $0 }
    }

    // MARK: - Random mode (virtual slices, non-deletable)

    /// Adjustable random note range – defaults C2–C4.
    @Published var randomRangeLow: Int = (2 + 2) * 12      // C2 = 48
    @Published var randomRangeHigh: Int = (4 + 2) * 12     // C4 = 72

    /// Note → index mapping for Random mode (visual/trigger ordering).
    @Published var randomMapping: [Int: Int] = [:]

    /// Shuffle mapping of notes in current range into random visual positions.
    func shuffleRandomSlices() {
        let low = min(randomRangeLow, randomRangeHigh)
        let high = max(randomRangeLow, randomRangeHigh)
        let notes = Array(low...high)
        guard !notes.isEmpty else {
            randomMapping = [:]
            return
        }

        let shuffledIndices = Array(0..<notes.count).shuffled()
        var map: [Int: Int] = [:]
        for (note, idx) in zip(notes, shuffledIndices) {
            map[note] = idx
        }
        randomMapping = map
    }

    // MARK: - Internal frame cache

    @Published var currentFrameImage: CGImage?

    private struct Frame {
        let time: Double   // seconds
        let image: CGImage
    }

    private var frames: [Frame] = []
    private var framesReady = false

    private var winOffset: Double = 0
    private var winScale: Double = 1

    private var triggerID: UInt64 = 0

    // Playback state
    private var isPlaying: Bool = false
    private var currentSliceStartSec: Double = 0
    private var currentSliceEndSec: Double = 0
    private var elapsedInSlice: Double = 0
    private var currentFrameIndex: Int = 0

    private let ciContext = CIContext()
    private var imageOrientation: CGImagePropertyOrientation = .up

    // ✅ NEW: cap approximate frame cache size (tweak this if you want)
    private let maxCacheMemoryMB: Double = 512.0

    // MARK: - Window math

    private func recalcWindow() {
        let s = clamp01(winStart)
        let e = max(s, clamp01(winEnd))
        winOffset = s
        winScale = max(e - s, 1e-6)
    }

    // MARK: - Public slice helpers (window-relative)

    /// Create a slice whose center is at `centerN` inside the window (0–1).
    func addSliceAtWindowPosition(centerN: Double, defaultHalfWidth: Double = 0.05) {
        let c = clamp01(centerN)
        let hw = max(0.001, min(0.5, defaultHalfWidth))
        let slice = Slice(centerN: c, halfWidthN: hw)
        slices.append(slice)
    }

    /// Assign a MIDI note (e.g. 36 == C1) to an existing slice.
    func assign(note: Int, to sliceID: UUID) {
        guard let idx = slices.firstIndex(where: { $0.id == sliceID }) else { return }
        var s = slices[idx]
        s.assignedNotes.insert(note)
        slices[idx] = s
    }

    /// Replace the primary note mapping for a slice (used by note editing).
    func setPrimaryNote(_ note: Int, for sliceID: UUID) {
        guard let idx = slices.firstIndex(where: { $0.id == sliceID }) else { return }
        var s = slices[idx]
        s.assignedNotes = [note]
        slices[idx] = s
    }

    /// Update slice center after dragging (still window-relative 0–1).
    func updateSliceCenter(sliceID: UUID, newCenterN: Double) {
        guard let idx = slices.firstIndex(where: { $0.id == sliceID }) else { return }
        var s = slices[idx]

        let hw = max(0.001, min(0.5, s.halfWidthN))
        var c = clamp01(newCenterN)

        // Keep full slice inside [0,1]
        if c - hw < 0 {
            c = hw
        } else if c + hw > 1 {
            c = 1 - hw
        }

        s.centerN = c
        s.halfWidthN = hw
        slices[idx] = s
    }

    // MARK: - Video loading

    func openVideo(url: URL) {
        status = "Loading \(url.lastPathComponent)…"
        frames = []
        framesReady = false
        currentFrameImage = nil
        isPlaying = false
        duration = 0

        Task {
            await loadAndDecode(url: url)
        }
    }

    private func loadAndDecode(url: URL) async {
        let asset = AVAsset(url: url)

        guard let track = asset.tracks(withMediaType: .video).first else {
            status = "Failed: no video track"
            return
        }

        duration = asset.duration.seconds

        // size + orientation + nominal frame rate
        var nominalFPS: Float = 30.0

        do {
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let oriented = naturalSize.applying(transform)
            videoSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            imageOrientation = Self.orientation(from: transform)

            nominalFPS = (try? await track.load(.nominalFrameRate)) ?? 30.0
        } catch {
            videoSize = CGSize(width: 360, height: 640)
            imageOrientation = .up
            nominalFPS = 30.0
        }

        // Compute an approximate max frame count based on memory budget
        let bytesPerFrameEstimate = max(
            1.0,
            Double(videoSize.width * videoSize.height * 4) // BGRA
        )
        let maxFramesByMemory = Int(
            (maxCacheMemoryMB * 1024.0 * 1024.0) / bytesPerFrameEstimate
        )
        let maxFrames = max(60, maxFramesByMemory) // never less than ~2 seconds of 30fps

        // Decide target FPS so duration * fps <= maxFrames (but don't go below a floor)
        let safeDuration = max(duration, 0.1)
        let maxFPSFromMemory = Double(maxFrames) / safeDuration
        let targetFPS = max(
            5.0,
            min(Double(nominalFPS), maxFPSFromMemory)
        )
        let frameInterval = 1.0 / targetFPS

        do {
            let reader = try AVAssetReader(asset: asset)
            let outputSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
            reader.add(output)

            guard reader.startReading() else {
                status = "Decode error"
                return
            }

            var newFrames: [Frame] = []
            var lastKeptPTS: Double? = nil

            while reader.status == .reading {
                guard let sampleBuffer = output.copyNextSampleBuffer() else {
                    break
                }
                guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    continue
                }

                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

                // Downsample in time: only keep frames at least `frameInterval` apart
                if let last = lastKeptPTS, pts - last < frameInterval {
                    continue
                }

                var ciImage = CIImage(cvPixelBuffer: pb)
                ciImage = ciImage.oriented(imageOrientation)

                let rect = ciImage.extent
                if let cg = ciContext.createCGImage(ciImage, from: rect) {
                    newFrames.append(Frame(time: pts, image: cg))
                    lastKeptPTS = pts

                    // Small extra safety: if we somehow overshoot, trim oldest
                    if newFrames.count > maxFrames {
                        let overflow = newFrames.count - maxFrames
                        newFrames.removeFirst(overflow)
                    }
                }
            }

            if reader.status == .completed, !newFrames.isEmpty {
                frames = newFrames
                framesReady = true
                duration = max(duration, newFrames.last?.time ?? 0)
                currentFrameImage = frames.first?.image
                status = "Loaded: \(url.lastPathComponent) • \(String(format: "%.2fs", duration))"
            } else {
                status = "Decode failed"
            }
        } catch {
            status = "Decode exception"
        }
    }

    // MARK: - MIDI trigger entry point

    func trigger(note: Int, i: Double, o: Double) {
        guard framesReady, !frames.isEmpty else { return }

        recalcWindow()
        triggerID &+= 1

        switch sliceMode {
        case .auto:
            triggerAuto(note: note, i: i, o: o)
        case .manual:
            triggerManual(note: note, fallbackI: i, fallbackO: o)
        case .chrom:
            triggerChrom(note: note, fallbackI: i, fallbackO: o)
        case .random:
            triggerRandom(note: note, fallbackI: i, fallbackO: o)
        }
    }

    func stopIfNeeded(note: Int) {
        isPlaying = false
    }

    // MARK: - Auto (Simpler i/o) mode

    private func triggerAuto(note: Int, i: Double, o: Double) {
        let inN  = winOffset + i * winScale
        let outN = winOffset + o * winScale

        let wIn  = warp(inN)
        let wOut = warp(outN)

        let rawStart = clamp01(wIn)  * duration + latencyOffsetSec
        let rawEnd   = clamp01(wOut) * duration + latencyOffsetSec

        let startSec = max(0.0, min(duration, rawStart))
        let endSec   = max(0.0, min(duration, rawEnd))
        guard endSec > startSec else { return }

        if autoContinuous {
            startSlice(startSec: startSec, endSec: duration)
        } else {
            startSlice(startSec: startSec, endSec: endSec)
        }
    }

    // MARK: - Manual (window-relative) mode

    private func sliceFor(note: Int) -> Slice? {
        // First check explicit mapping
        if let s = slices.first(where: { $0.assignedNotes.contains(note) }) {
            return s
        }
        guard !slices.isEmpty else { return nil }

        // Fallback: index mapping starting at C1 (36)
        let base = 36
        let idx = max(0, min(slices.count - 1, note - base))
        return slices[idx]
    }

    private func triggerManual(note: Int, fallbackI: Double, fallbackO: Double) {
        guard duration > 0 else { return }

        guard let s = sliceFor(note: note) else {
            // If no manual slice, fall back to Simpler’s i/o so nothing feels dead
            triggerAuto(note: note, i: fallbackI, o: fallbackO)
            return
        }

        // Convert window-relative slice → global normalized → seconds
        recalcWindow()

        let startWindowN = s.startN
        let endWindowN   = s.endN

        let startGlobalN = winOffset + startWindowN * winScale
        let endGlobalN   = winOffset + endWindowN   * winScale

        var startSec = clamp01(startGlobalN) * duration + latencyOffsetSec
        var endSec   = clamp01(endGlobalN)   * duration + latencyOffsetSec

        let trimStartSec = winOffset * duration
        let trimEndSec   = (winOffset + winScale) * duration

        startSec = max(trimStartSec, min(duration, startSec))
        endSec   = max(startSec, min(trimEndSec, endSec))
        guard endSec > startSec else { return }

        startSlice(startSec: startSec, endSec: endSec)
    }

    // MARK: - Chrom / Random virtual slices

    /// Shared helper: play a virtual slice centered at `centerWindowN` (0–1 in window space).
    private func triggerVirtual(centerWindowN: Double) {
        guard duration > 0 else { return }

        recalcWindow()

        let hwN = 0.05
        let startWindowN = max(0.0, centerWindowN - hwN)
        let endWindowN   = min(1.0, centerWindowN + hwN)

        let startGlobalN = winOffset + startWindowN * winScale
        let endGlobalN   = winOffset + endWindowN   * winScale

        var startSec = clamp01(startGlobalN) * duration + latencyOffsetSec
        var endSec   = clamp01(endGlobalN)   * duration + latencyOffsetSec

        let trimStartSec = winOffset * duration
        let trimEndSec   = (winOffset + winScale) * duration

        startSec = max(trimStartSec, min(duration, startSec))
        endSec   = max(startSec, min(trimEndSec, endSec))
        guard endSec > startSec else { return }

        startSlice(startSec: startSec, endSec: endSec)
    }

    private func triggerChrom(note: Int, fallbackI: Double, fallbackO: Double) {
        let notes = chromaticNotes()
        guard let idx = notes.firstIndex(of: note) else {
            // fall back to auto if note not in chromatic range
            triggerAuto(note: note, i: fallbackI, o: fallbackO)
            return
        }
        let count = max(notes.count, 1)
        let centerN = (Double(idx) + 0.5) / Double(count)
        triggerVirtual(centerWindowN: centerN)
    }

    private func triggerRandom(note: Int, fallbackI: Double, fallbackO: Double) {
        guard !randomMapping.isEmpty,
              let idx = randomMapping[note] else {
            // fall back to auto if note not currently mapped
            triggerAuto(note: note, i: fallbackI, o: fallbackO)
            return
        }

        let count = max(randomMapping.count, 1)
        let centerN = (Double(idx) + 0.5) / Double(count)
        triggerVirtual(centerWindowN: centerN)
    }

    // MARK: - Sampler engine

    private func startSlice(startSec: Double, endSec: Double) {
        isPlaying = false
        elapsedInSlice = 0

        currentSliceStartSec = startSec
        currentSliceEndSec = endSec

        if let idx = frames.firstIndex(where: { $0.time >= startSec }) {
            currentFrameIndex = idx
        } else {
            currentFrameIndex = frames.count - 1
        }

        currentFrameImage = frames[currentFrameIndex].image
        isPlaying = true
    }

    func advanceFrame(deltaTime: Double) {
        guard isPlaying, framesReady, !frames.isEmpty else { return }

        let rate: Double = (warpMode == .rate) ? Double(max(0.01, playbackRate)) : 1.0
        elapsedInSlice += deltaTime * rate
        let nowSec = currentSliceStartSec + elapsedInSlice

        if nowSec >= currentSliceEndSec {
            isPlaying = false
            return
        }

        var idx = currentFrameIndex
        let count = frames.count

        while idx + 1 < count && frames[idx + 1].time <= nowSec {
            idx += 1
        }

        currentFrameIndex = idx
        currentFrameImage = frames[currentFrameIndex].image
    }

    // MARK: - Warp

    private func warp(_ t: Double) -> Double {
        switch warpMode {
        case .linear, .rate:
            return t
        }
    }

    // MARK: - Orientation helper

    private static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 {
            return .right
        } else if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 {
            return .left
        } else if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 {
            return .down
        } else {
            return .up
        }
    }

    // MARK: - Utils

    private func clamp01(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }
}

