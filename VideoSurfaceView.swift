import SwiftUI
import AppKit

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

class VideoSurfaceNSView: NSView {
    weak var model: VideoSamplerModel? {
        didSet { startTimerIfNeeded() }
    }

    private var displayTimer: Timer?

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        displayTimer?.invalidate()

        guard window != nil, model != nil else {
            displayTimer = nil
            return
        }

        displayTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(step),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func step() {
        guard let model else { return }

        model.advanceFrame(deltaTime: 1.0 / 60.0)

        if let cg = model.currentFrameImage {
            layer?.contentsGravity = .resizeAspectFill
            layer?.contents = cg
        } else {
            layer?.contents = nil
        }
    }
}

