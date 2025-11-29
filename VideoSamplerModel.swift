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

    @Published var latencyOffsetSec: Double = 0.0
    @Published var warpMode: WarpMode = .linear
    var playbackRate: Float = 1.0

    /// The frame currently being displayed by the view.
    @Published var currentFrameImage: CGImage?

    enum WarpMode: Hashable {
        case linear
        case rate
        case curve
    }

    // MARK: - Internal frame cache

    private struct Frame {
        let time: Double   // seconds
        let image: CGImage
    }

    private var frames: [Frame] = []
    private var framesReady = false

    private var winOffset: Double = 0
    private var winScale: Double = 1

    private var triggerID: UInt64 = 0

    // Playback state (sampler-style)
    private var isPlaying: Bool = false
    private var currentSliceStartSec: Double = 0
    private var currentSliceEndSec: Double = 0
    private var elapsedInSlice: Double = 0
    private var currentFrameIndex: Int = 0

    private let ciContext = CIContext()
    private var imageOrientation: CGImagePropertyOrientation = .up

    // MARK: - Window math

    private func recalcWindow() {
        let s = max(0, min(1, winStart))
        let e = max(s, min(1, winEnd))
        winOffset = s
        winScale = e - s
    }

    // MARK: - Video loading

    func openVideo(url: URL) {
        status = "Loading \(url.lastPathComponent)…"
        frames = []
        framesReady = false
        currentFrameImage = nil
        isPlaying = false

        Task {
            await loadAndDecode(url: url)
        }
    }

    private func loadAndDecode(url: URL) async {
        let asset = AVAsset(url: url)

        guard
            let track = asset.tracks(withMediaType: .video).first
        else {
            status = "Failed: no video track"
            return
        }

        duration = asset.duration.seconds

        // Size + orientation
        do {
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let oriented = naturalSize.applying(transform)
            videoSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            imageOrientation = Self.orientation(from: transform)
        } catch {
            videoSize = CGSize(width: 360, height: 640)
            imageOrientation = .up
        }

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

            while reader.status == .reading {
                guard let sampleBuffer = output.copyNextSampleBuffer() else {
                    break
                }
                guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    continue
                }

                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
                var ciImage = CIImage(cvPixelBuffer: pb)

                // Apply orientation
                ciImage = ciImage.oriented(imageOrientation)

                let rect = ciImage.extent
                if let cg = ciContext.createCGImage(ciImage, from: rect) {
                    newFrames.append(Frame(time: pts, image: cg))
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

    // MARK: - MIDI trigger (sampler style)

    func trigger(note: Int, i: Double, o: Double) {
        guard framesReady, !frames.isEmpty else { return }

        recalcWindow()
        triggerID &+= 1
        let _ = triggerID  // reserved if we want to guard async later

        let inN  = winOffset + i * winScale
        let outN = winOffset + o * winScale

        let wIn  = warp(inN)
        let wOut = warp(outN)

        let rawStart = clamp01(wIn)  * duration + latencyOffsetSec
        let rawEnd   = clamp01(wOut) * duration + latencyOffsetSec

        let startSec = max(0.0, min(duration, rawStart))
        let endSec   = max(0.0, min(duration, rawEnd))
        guard endSec > startSec else { return }

        startSlice(startSec: startSec, endSec: endSec)
    }

    func stopIfNeeded(note: Int) {
        isPlaying = false
    }

    // MARK: - Sampler engine

    private func startSlice(startSec: Double, endSec: Double) {
        // Mono: choke current playback and restart slice
        isPlaying = false
        elapsedInSlice = 0

        currentSliceStartSec = startSec
        currentSliceEndSec = endSec

        // Find first frame at or after startSec
        if let idx = frames.firstIndex(where: { $0.time >= startSec }) {
            currentFrameIndex = idx
        } else {
            currentFrameIndex = frames.count - 1
        }

        // Display that frame immediately
        currentFrameImage = frames[currentFrameIndex].image
        isPlaying = true
    }

    /// Called from the view's display timer (e.g. ~60Hz).
    func advanceFrame(deltaTime: Double) {
        guard isPlaying, framesReady, !frames.isEmpty else { return }

        let rate: Double = (warpMode == .rate) ? Double(max(0.01, playbackRate)) : 1.0

        elapsedInSlice += deltaTime * rate
        let nowSec = currentSliceStartSec + elapsedInSlice

        if nowSec >= currentSliceEndSec {
            isPlaying = false
            return
        }

        // Advance currentFrameIndex forward while we haven't reached nowSec
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
        case .curve:
            // Placeholder for curve mapping
            return t
        }
    }

    // MARK: - Orientation helper

    private static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        if t.a == 0 && t.b == 1 && t.c == -1 && t.d == 0 {
            return .right    // 90° right
        } else if t.a == 0 && t.b == -1 && t.c == 1 && t.d == 0 {
            return .left     // 90° left
        } else if t.a == -1 && t.b == 0 && t.c == 0 && t.d == -1 {
            return .down     // 180°
        } else {
            return .up
        }
    }

    // MARK: - Utils

    private func clamp01(_ x: Double) -> Double {
        min(max(x, 0), 1)
    }
}

