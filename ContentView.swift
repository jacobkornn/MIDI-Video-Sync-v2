import SwiftUI
import AVKit
import AppKit
import CoreImage

struct ContentView: View {
    @StateObject private var model = VideoSamplerModel()
    @State private var osc: OSCReceiver?

    private let videoWidth: CGFloat = 360
    private let videoHeight: CGFloat = 640

    var body: some View {
        VStack(spacing: 12) {

            // ---- VIDEO FRAME ----
            ZStack {
                Rectangle().fill(Color.black)

                VideoSurfaceView(model: model)
                    .frame(width: videoWidth, height: videoHeight)
                    .clipped()
            }
            .frame(width: videoWidth, height: videoHeight)

            // ---- CONTROLS ----
            VStack(alignment: .leading, spacing: 8) {

                // Top row
                HStack {
                    Button("Open Video…") {
                        openVideo()
                    }
                    Spacer()
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // -------- Warp Mode --------
                HStack {
                    Text("Warp")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Picker("", selection: $model.warpMode) {
                        Text("Linear").tag(VideoSamplerModel.WarpMode.linear)
                        Text("Rate").tag(VideoSamplerModel.WarpMode.rate)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }

                // -------- Rate --------
                HStack {
                    Text("Rate")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Slider(
                        value: Binding(
                            get: { Double(model.playbackRate) },
                            set: { model.playbackRate = Float($0) }
                        ),
                        in: 0.25...2.0
                    )
                    .disabled(model.warpMode != .rate)

                    Text(String(format: "%.2fx", model.playbackRate))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                        .foregroundStyle(
                            model.warpMode == .rate ? .primary : .secondary
                        )
                }

                // -------- Latency --------
                HStack {
                    Text("Latency")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Slider(
                        value: $model.latencyOffsetSec,
                        in: -0.05...0.05,
                        step: 0.001
                    )

                    Text(String(format: "%+.0f ms", model.latencyOffsetSec * 1000))
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }

                Divider()

                // -------- Window --------
                Text("Window (0–1)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Slider(value: $model.winStart, in: 0...(model.winEnd - 0.01))
                    Text(String(format: "%.2f", model.winStart))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }

                HStack {
                    Slider(value: $model.winEnd, in: (model.winStart + 0.01)...1)
                    Text(String(format: "%.2f", model.winEnd))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
        .padding()
        .frame(width: videoWidth + 40)
        .onAppear { setupOSC() }
    }

    // MARK: - Video loading

    private func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        if panel.runModal() == .OK, let url = panel.url {
            model.openVideo(url: url)
        }
    }

    // MARK: - OSC

    private func setupOSC() {
        let r = OSCReceiver(port: 57120)

        r.onNoteSlice = { [weak model] note, i, o, _ in
            DispatchQueue.main.async {
                model?.trigger(note: note, i: i, o: o)
            }
        }

        r.onNoteOff = { [weak model] note in
            DispatchQueue.main.async {
                model?.stopIfNeeded(note: note)
            }
        }

        osc = r
    }
}

// MARK: - Custom Video Surface (no AVPlayerView)

struct VideoSurfaceView: NSViewRepresentable {
    @ObservedObject var model: VideoSamplerModel

    func makeNSView(context: Context) -> VideoSurfaceNSView {
        let v = VideoSurfaceNSView()
        v.model = model
        return v
    }

    func updateNSView(_ nsView: VideoSurfaceNSView, context: Context) {
        nsView.model = model
    }
}

final class VideoSurfaceNSView: NSView {

    weak var model: VideoSamplerModel? {
        didSet {
            startTimerIfNeeded()
        }
    }

    private var displayTimer: Timer?
    private let ciContext = CIContext()
    private var lastImage: CGImage?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    deinit {
        displayTimer?.invalidate()
    }

    private func startTimerIfNeeded() {
        guard displayTimer == nil else { return }

        displayTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(step),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func step() {
        guard
            let model,
            let output = model.videoOutput,
            let item = model.queuePlayer.currentItem
        else {
            return
        }

        let hostTime = CACurrentMediaTime()
        let itemTime = output.itemTime(forHostTime: hostTime)

        if output.hasNewPixelBuffer(forItemTime: itemTime),
           let pb = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {

            var ciImage = CIImage(cvPixelBuffer: pb)
            ciImage = ciImage.oriented(model.imageOrientation)

            let rect = ciImage.extent
            if let cg = ciContext.createCGImage(ciImage, from: rect) {
                lastImage = cg
                layer?.contentsGravity = .resizeAspectFill
                layer?.contents = cg
            }
        } else if let lastImage {
            // Keep last frame, don't go black
            layer?.contentsGravity = .resizeAspectFill
            layer?.contents = lastImage
        }
    }
}

