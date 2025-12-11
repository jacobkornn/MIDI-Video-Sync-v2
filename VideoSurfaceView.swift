import SwiftUI
import AppKit
import AVFoundation

struct VideoSurfaceView: NSViewRepresentable {
    @ObservedObject var model: VideoSamplerModel

    func makeNSView(context: Context) -> VideoSurfaceNSView {
        let v = VideoSurfaceNSView()
        v.configure(with: model)
        return v
    }

    func updateNSView(_ nsView: VideoSurfaceNSView, context: Context) {
        nsView.update(model: model)
    }
}

final class VideoSurfaceNSView: NSView {

    private var playerLayer: AVPlayerLayer?
    private var imageLayer: CALayer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setupLayers()
    }

    private func setupLayers() {
        // Player layer (video playback)
        let p = AVPlayerLayer()
        p.videoGravity = .resizeAspectFill
        layer = CALayer()
        layer?.addSublayer(p)
        self.playerLayer = p

        // Image layer (cached burst frames)
        let img = CALayer()
        img.contentsGravity = .resizeAspectFill
        img.masksToBounds = true
        layer?.addSublayer(img)
        self.imageLayer = img
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = bounds
        imageLayer?.frame = bounds
    }

    // Called at creation time
    func configure(with model: VideoSamplerModel) {
        playerLayer?.player = model.player
        updatePreviewImage(using: model.currentFrameImage)
    }

    // Called whenever @Published values change
    func update(model: VideoSamplerModel) {
        playerLayer?.player = model.player
        updatePreviewImage(using: model.currentFrameImage)
    }

    private func updatePreviewImage(using cg: CGImage?) {
        if let cg {
            imageLayer?.contents = cg
        } else {
            imageLayer?.contents = nil
        }
    }
}
