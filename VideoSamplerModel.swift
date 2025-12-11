import Foundation
import AVFoundation
import AppKit
import CoreImage
import ImageIO

@MainActor
final class VideoSamplerModel: ObservableObject {

    // MARK: - Public bindings

    @Published var duration: Double = 0
    @Published var winStart: Double = 0.0
    @Published var winEnd: Double = 1.0
    @Published var status: String = "No video"
    @Published var videoSize = CGSize(width: 360, height: 640)
    @Published var autoContinuous: Bool = false

    @Published var latencyOffsetSec: Double = 0.0

    enum WarpMode: Hashable { case linear, rate }
    @Published var warpMode: WarpMode = .linear
    var playbackRate: Float = 1.0

    // MARK: - Slice modes (RESTORED)
    enum SliceMode: Hashable {
        case auto
        case manual
        case chrom
        case random
    }

    @Published var sliceMode: SliceMode = .auto

    // MARK: - Manual slices

    struct Slice: Identifiable, Hashable {
        let id: UUID
        var centerN: Double
        var halfWidthN: Double
        var assignedNotes: Set<Int>

        init(id: UUID = UUID(), centerN: Double, halfWidthN: Double = 0.05, assignedNotes: Set<Int> = []) {
            self.id = id
            self.centerN = centerN
            self.halfWidthN = halfWidthN
            self.assignedNotes = assignedNotes
        }

        var startN: Double { centerN - halfWidthN }
        var endN: Double   { centerN + halfWidthN }
    }

    @Published var slices: [Slice] = []

    // MARK: - Chromatic mode (RESTORED)

    @Published var chromaticBaseOctave: Int = 3
    let chromaticSliceCount: Int = 24

    func chromaticNotes() -> [Int] {
        let baseMidi = (chromaticBaseOctave + 2) * 12
        return (0..<chromaticSliceCount).map { baseMidi + $0 }
    }

    // MARK: - Random mode (RESTORED)

    @Published var randomRangeLow: Int = (2 + 2) * 12     // C2 = 48
    @Published var randomRangeHigh: Int = (4 + 2) * 12    // C4 = 72
    @Published var randomMapping: [Int: Int] = [:]

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

    // MARK: - Playback Layers

    @Published var currentFrameImage: CGImage?
    private var imageGenerator: AVAssetImageGenerator?

    @Published var player = AVPlayer()
    private var playerItem: AVPlayerItem?
    private var asset: AVAsset?

    // MARK: - Hybrid frame cache

    private let cacheWindowSec: Double = 0.25
    private var cachedFrames: [CGImage] = []
    private var cachedTimes: [Double] = []
    private var cachedFPS: Double = 30.0
    private var cachedBurstIndex: Int = 0
    private var cachedBurstActive: Bool = false

    private let ciContext = CIContext()

    // MARK: - Window math

    private var winOffset: Double = 0
    private var winScale: Double = 1

    private func recalcWindow() {
        let s = clamp01(winStart)
        let e = max(s, clamp01(winEnd))
        winOffset = s
        winScale = max(e - s, 1e-6)
    }

    // MARK: - Slice Helpers

    func addSliceAtWindowPosition(centerN: Double, defaultHalfWidth: Double = 0.05) {
        let c = clamp01(centerN)
        let hw = max(0.001, min(0.5, defaultHalfWidth))
        slices.append(Slice(centerN: c, halfWidthN: hw))
    }

    func assign(note: Int, to sliceID: UUID) {
        guard let idx = slices.firstIndex(where: { $0.id == sliceID }) else { return }
        var s = slices[idx]
        s.assignedNotes.insert(note)
        slices[idx] = s
    }

    func updateSliceCenter(sliceID: UUID, newCenterN: Double) {
        guard let idx = slices.firstIndex(where: { $0.id == sliceID }) else { return }
        var s = slices[idx]

        let hw = max(0.001, min(0.5, s.halfWidthN))
        var c = clamp01(newCenterN)

        if c - hw < 0 { c = hw }
        else if c + hw > 1 { c = 1 - hw }

        s.centerN = c
        s.halfWidthN = hw
        slices[idx] = s
    }

    // MARK: - Video Loading

    func openVideo(url: URL) {
        status = "Loading \(url.lastPathComponent)…"
        duration = 0
        currentFrameImage = nil
        cachedFrames = []
        cachedTimes = []
        cachedBurstActive = false
        player.pause()

        Task { await loadVideo(url: url) }
    }

    private func loadVideo(url: URL) async {
        let original = AVAsset(url: url)

        guard let videoTrack = try? await original.loadTracks(withMediaType: .video).first else {
            status = "Failed: no video track"
            return
        }

        duration = original.duration.seconds

        do {
            let natural = try await videoTrack.load(.naturalSize)
            let transform = try await videoTrack.load(.preferredTransform)
            let oriented = natural.applying(transform)
            videoSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        } catch {
            videoSize = CGSize(width: 360, height: 640)
        }

        // Remove audio entirely
        let comp = AVMutableComposition()
        do {
            let compTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try compTrack?.insertTimeRange(
                CMTimeRange(start: .zero, duration: original.duration),
                of: videoTrack,
                at: .zero
            )
        } catch {
            status = "Track insertion failed"
        }

        asset = comp

        let item = AVPlayerItem(asset: comp)
        playerItem = item
        player.replaceCurrentItem(with: item)
        player.isMuted = true
        player.volume = 0

        setupImageGenerator(comp)

        status = "Loaded \(url.lastPathComponent)"
    }

    private func setupImageGenerator(_ asset: AVAsset) {
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceAfter  = .zero
        gen.requestedTimeToleranceBefore = .zero
        imageGenerator = gen
    }

    // MARK: - Scrubbing

    func updatePreview(to sec: Double) {
        let t = CMTime(seconds: sec, preferredTimescale: 600)
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)

        guard let gen = imageGenerator else { return }

        Task {
            if let cg = try? gen.copyCGImage(at: t, actualTime: nil) {
                self.currentFrameImage = cg
            }
        }
    }

    // MARK: - MIDI Trigger

    func trigger(note: Int, i: Double, o: Double) {
        guard duration > 0 else { return }

        recalcWindow()

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

    func stopIfNeeded(note: Int) { }

    // MARK: - AUTO MODE

    private func triggerAuto(note: Int, i: Double, o: Double) {
        let inN  = winOffset + i * winScale
        let outN = winOffset + o * winScale

        let wIn  = warp(inN)
        let wOut = warp(outN)

        let s = clamp01(wIn)  * duration + latencyOffsetSec
        let e = clamp01(wOut) * duration + latencyOffsetSec

        guard e > s else { return }
        playHybridSlice(start: s, end: e)
    }

    // MARK: - MANUAL MODE

    private func sliceFor(note: Int) -> Slice? {
        if let s = slices.first(where: { $0.assignedNotes.contains(note) }) { return s }
        guard !slices.isEmpty else { return nil }
        let idx = max(0, min(slices.count - 1, note - 36))
        return slices[idx]
    }

    private func triggerManual(note: Int, fallbackI: Double, fallbackO: Double) {
        guard duration > 0 else { return }

        guard let s = sliceFor(note: note) else {
            triggerAuto(note: note, i: fallbackI, o: fallbackO)
            return
        }

        recalcWindow()

        let startWindowN = s.startN
        let endWindowN   = s.endN

        let startGlobalN = winOffset + startWindowN * winScale
        let endGlobalN   = winOffset + endWindowN * winScale

        var startSec = clamp01(startGlobalN) * duration + latencyOffsetSec
        var endSec   = clamp01(endGlobalN)   * duration + latencyOffsetSec

        let trimS = winOffset * duration
        let trimE = (winOffset + winScale) * duration

        startSec = max(trimS, min(duration, startSec))
        endSec   = max(startSec, min(trimE, endSec))

        guard endSec > startSec else { return }

        playHybridSlice(start: startSec, end: endSec)
    }

    // MARK: - CHROMATIC MODE (RESTORED)

    private func triggerChrom(note: Int, fallbackI: Double, fallbackO: Double) {
        let notes = chromaticNotes()
        guard let idx = notes.firstIndex(of: note) else {
            triggerAuto(note: note, i: fallbackI, o: fallbackO)
            return
        }

        let count = max(notes.count, 1)
        let centerN = (Double(idx) + 0.5) / Double(count)
        triggerVirtual(centerWindowN: centerN)
    }

    // MARK: - RANDOM MODE (RESTORED)

    private func triggerRandom(note: Int, fallbackI: Double, fallbackO: Double) {
        guard !randomMapping.isEmpty, let idx = randomMapping[note] else {
            triggerAuto(note: note, i: fallbackI, o: fallbackO)
            return
        }

        let count = max(randomMapping.count, 1)
        let centerN = (Double(idx) + 0.5) / Double(count)
        triggerVirtual(centerWindowN: centerN)
    }

    // MARK: - VIRTUAL SLICE (RESTORED)

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

        let trimS = winOffset * duration
        let trimE = (winOffset + winScale) * duration

        startSec = max(trimS, min(duration, startSec))
        endSec   = max(startSec, min(trimE, endSec))

        guard endSec > startSec else { return }

        playHybridSlice(start: startSec, end: endSec)
    }

    // MARK: - HYBRID PLAYBACK

    private func playHybridSlice(start: Double, end: Double) {
        generateCacheAround(startTime: start)

        cachedBurstIndex = 0
        cachedBurstActive = true
        stepCachedBurst()

        let sCM = CMTime(seconds: start, preferredTimescale: 600)
        let eCM = CMTime(seconds: end,   preferredTimescale: 600)

        player.seek(to: sCM, toleranceBefore: .zero, toleranceAfter: .zero)
        player.rate = 1.0

        player.addBoundaryTimeObserver(forTimes: [NSValue(time: eCM)], queue: .main) { [weak self] in
            self?.player.rate = 0.0
        }
    }

    private func generateCacheAround(startTime: Double) {
        cachedFrames.removeAll()
        cachedTimes.removeAll()

        guard let gen = imageGenerator else { return }

        let fps = cachedFPS
        let frameDur = 1.0 / fps
        let framesCount = Int(cacheWindowSec / frameDur)

        for i in 0..<framesCount {
            let t = startTime + Double(i) * frameDur
            if t > duration { break }

            let cm = CMTime(seconds: t, preferredTimescale: 600)
            if let cg = try? gen.copyCGImage(at: cm, actualTime: nil) {
                cachedFrames.append(cg)
                cachedTimes.append(t)
            }
        }
    }

    private func stepCachedBurst() {
        guard cachedBurstActive else { return }

        if cachedBurstIndex >= cachedFrames.count {
            cachedBurstActive = false
            return
        }

        currentFrameImage = cachedFrames[cachedBurstIndex]
        cachedBurstIndex += 1

        let frameDur = 1.0 / cachedFPS

        DispatchQueue.main.asyncAfter(deadline: .now() + frameDur) { [weak self] in
            self?.stepCachedBurst()
        }
    }

    // MARK: - WARP

    private func warp(_ t: Double) -> Double {
        switch warpMode {
        case .linear, .rate: return t
        }
    }

    // MARK: - UTILS

    private func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
}
