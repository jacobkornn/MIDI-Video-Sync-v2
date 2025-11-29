import Foundation
import AVFoundation
import AppKit
import ImageIO   // for CGImagePropertyOrientation

@MainActor
final class VideoSamplerModel: ObservableObject {

    // MARK: - Public bindings

    /// Backing player (AVQueuePlayer under the hood).
    @Published var player: AVPlayer

    @Published var duration: Double = 0
    @Published var winStart: Double = 0.0
    @Published var winEnd: Double = 1.0
    @Published var status: String = "No video"
    @Published var videoSize = CGSize(width: 360, height: 640)

    @Published var latencyOffsetSec: Double = 0.0
    @Published var warpMode: WarpMode = .linear
    var playbackRate: Float = 1.0

    enum WarpMode: Hashable {
        case linear
        case rate
        case curve
    }

    // MARK: - Internal state

    let queuePlayer: AVQueuePlayer
    private(set) var videoOutput: AVPlayerItemVideoOutput?

    private var asset: AVURLAsset?

    private var winOffset: Double = 0
    private var winScale: Double = 1

    private var triggerID: UInt64 = 0
    private var stopWorkItem: DispatchWorkItem?

    private let timeScale: CMTimeScale = 600

    private var ciOrientation: CGImagePropertyOrientation = .up

    /// Expose orientation for renderer.
    var imageOrientation: CGImagePropertyOrientation {
        ciOrientation
    }

    // MARK: - Init

    init() {
        let q = AVQueuePlayer()
        self.queuePlayer = q
        self.player = q

        q.isMuted = true
        q.actionAtItemEnd = .pause

        recalcWindow()
    }

    // MARK: - Window math

    private func recalcWindow() {
        let s = max(0, min(1, winStart))
        let e = max(s, min(1, winEnd))
        winOffset = s
        winScale = e - s
    }

    // MARK: - Video loading

    func openVideo(url: URL) {
        let a = AVURLAsset(url: url)
        asset = a

        let item = AVPlayerItem(asset: a)
        attachVideoOutput(to: item)

        queuePlayer.replaceCurrentItem(with: item)
        queuePlayer.pause()

        item.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)

        triggerID = 0

        Task { await loadMetadata(asset: a, url: url) }
    }

    private func attachVideoOutput(to item: AVPlayerItem) {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attrs)
        item.add(output)
        self.videoOutput = output
    }

    private func loadMetadata(asset: AVAsset, url: URL) async {
        do {
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let orientedSize = naturalSize.applying(transform)
                videoSize = CGSize(width: abs(orientedSize.width),
                                   height: abs(orientedSize.height))
                ciOrientation = Self.orientation(from: transform)
            }

            let dur = (try? await asset.load(.duration)) ?? asset.duration
            duration = max(0, dur.seconds)

            let durText = duration > 0 ? String(format: "%.2fs", duration) : "unknown"
            status = "Loaded: \(url.lastPathComponent) • \(durText)"
        } catch {
            status = "Loaded: \(url.lastPathComponent) • metadata error"
        }
    }

    // MARK: - MIDI trigger

    func trigger(note: Int, i: Double, o: Double) {
        guard duration > 0 else { return }
        guard queuePlayer.currentItem != nil else { return }

        recalcWindow()
        triggerID &+= 1
        let myID = triggerID

        let inN  = winOffset + i * winScale
        let outN = winOffset + o * winScale

        let wIn  = warp(inN)
        let wOut = warp(outN)

        let rawStart = clamp01(wIn)  * duration + latencyOffsetSec
        let rawEnd   = clamp01(wOut) * duration + latencyOffsetSec

        let startSec = max(0.0, min(duration, rawStart))
        let endSec   = max(0.0, min(duration, rawEnd))
        guard endSec > startSec else { return }

        startSlice(
            triggerID: myID,
            startSec: startSec,
            sliceDuration: endSec - startSec
        )
    }

    func stopIfNeeded(note: Int) {
        hardStop()
    }

    // MARK: - Core mono sampler (persistent item)

    private func startSlice(
        triggerID: UInt64,
        startSec: Double,
        sliceDuration: Double
    ) {
        stopWorkItem?.cancel()
        stopWorkItem = nil

        guard let item = queuePlayer.currentItem else { return }

        // Mono voice: choke current playback but keep item.
        queuePlayer.pause()
        item.cancelPendingSeeks()

        // Base time
        let baseTime = CMTime(seconds: startSec, preferredTimescale: timeScale)

        // Nudge back by 1 tick to break AVFoundation "same time" coalescing
        let oneTick = CMTime(value: 1, timescale: timeScale)
        let adjustedTime: CMTime
        if baseTime.value > 0 {
            adjustedTime = CMTimeSubtract(baseTime, oneTick)
        } else {
            adjustedTime = baseTime
        }

        let myID = triggerID
        let rate: Float = (warpMode == .rate) ? max(0.01, playbackRate) : 1.0
        let realTime = sliceDuration / Double(rate)

        item.seek(
            to: adjustedTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            guard let self else { return }

            Task { @MainActor in
                guard self.triggerID == myID else { return }

                self.queuePlayer.rate = rate
                self.queuePlayer.play()

                let work = DispatchWorkItem { [weak self] in
                    guard let self,
                          self.triggerID == myID else { return }
                    self.queuePlayer.pause()
                }

                self.stopWorkItem = work
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + realTime,
                    execute: work
                )
            }
        }
    }

    private func hardStop() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        queuePlayer.pause()
    }

    // MARK: - Warp

    private func warp(_ t: Double) -> Double {
        switch warpMode {
        case .linear, .rate:
            return t
        case .curve:
            return t
        }
    }

    // MARK: - Orientation helper

    private static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        // Common transform cases for iOS/macOS videos
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 {
            // 90° right
            return .right
        } else if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 {
            // 90° left
            return .left
        } else if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 {
            // 180°
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

