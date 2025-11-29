import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Helpers

fileprivate func midiNoteName(_ note: Int) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let idx = ((note % 12) + 12) % 12
    let octave = note / 12 - 2      // 36 -> C1
    return "\(names[idx])\(octave)"
}

fileprivate func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite && !seconds.isNaN else { return "--:--" }
    let totalMs = Int((seconds * 1000).rounded())
    let ms = totalMs % 1000
    let totalSeconds = totalMs / 1000
    let s = totalSeconds % 60
    let m = totalSeconds / 60
    return String(format: "%d:%02d.%03d", m, s, ms)
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var model = VideoSamplerModel()
    @State private var osc: OSCReceiver?

    // Collapsible timing section (warp / rate / latency)
    @State private var showTimingSection: Bool = false

    private let videoWidth: CGFloat = 360
    private let videoHeight: CGFloat = 640

    var body: some View {
        VStack(spacing: 12) {

            // ---- VIDEO FRAME ----
            ZStack {
                Rectangle()
                    .fill(Color.black)
                    .frame(width: videoWidth, height: videoHeight)
                    .cornerRadius(8)
                    .shadow(radius: 6)

                VideoSurfaceView(model: model)
                    .frame(width: videoWidth, height: videoHeight)
                    .clipped()
                    .cornerRadius(8)

                if model.currentFrameImage == nil {
                    Text("Open a video to begin")
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.5))
                        )
                }
            }

            // ---- CONTROL PANEL ----
            VStack(alignment: .leading, spacing: 8) {

                // File / status
                HStack {
                    Button("Open Video…") { openVideo() }

                    Spacer()

                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // ----------------------------------
                // 1) SLICE MODE + VIDEO WINDOW
                // ----------------------------------
                HStack {
                    Text("Slice Mode")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Picker("", selection: $model.sliceMode) {
                        Text("Auto").tag(VideoSamplerModel.SliceMode.auto)
                        Text("Manual").tag(VideoSamplerModel.SliceMode.manual)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }

                VStack(alignment: .leading,
                       spacing: model.sliceMode == .manual ? 12 : 4) {
                    HStack {
                        Text("Video Window")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if model.duration > 0 {
                            let span = max(0.0, model.winEnd - model.winStart)
                            let startSec = model.winStart * model.duration
                            let endSec = (model.winStart + span) * model.duration
                            Text("\(formatTime(startSec)) – \(formatTime(endSec))")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }

                    TrimTimelineView(
                        start: $model.winStart,
                        end: $model.winEnd,
                        slices: (model.sliceMode == .manual ? model.slices : []),
                        duration: model.duration,
                        onTapGlobal: { globalN in
                            // Double-tap inside yellow window strip → create slice
                            guard model.sliceMode == .manual else { return }
                            guard model.duration > 0 else { return }

                            let s = model.winStart
                            let e = model.winEnd
                            let span = max(0.0, e - s)
                            guard span > 0 else { return }

                            // Map global position into window-relative
                            let centerWindowN = (globalN - s) / span
                            guard centerWindowN >= 0, centerWindowN <= 1 else { return }

                            model.addSliceAtWindowPosition(centerN: centerWindowN)

                            // Auto-assign MIDI note starting at C1 (36)
                            guard let slice = model.slices.last else { return }
                            let idx = model.slices.count - 1
                            let noteNumber = 36 + idx
                            model.assign(note: noteNumber, to: slice.id)
                        },
                        onSliceDragged: { id, newCenterN in
                            model.updateSliceCenter(sliceID: id, newCenterN: newCenterN)
                        },
                        onSliceDelete: { id in
                            // Double-tap on marker label → delete that slice
                            guard model.sliceMode == .manual else { return }
                            model.slices.removeAll { $0.id == id }
                        }
                    )
                    .frame(height: 40)   // fixed; bar thickness is locked inside
                }

                // Clear button only (still tied to manual mode)
                if model.sliceMode == .manual {
                    HStack {
                        Spacer()
                        Button("Clear") {
                            model.slices.removeAll()
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .disabled(model.slices.isEmpty)
                    }
                }

                // ----------------------------------
                // Arrow to collapse/expand timing section
                // (centered under Video Window, both modes)
                // ----------------------------------
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showTimingSection.toggle()
                        }
                    }) {
                        Image(systemName: showTimingSection ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }

                Divider()

                // ----------------------------------
                // 2) WARP / RATE / LATENCY (collapsible)
                // ----------------------------------
                if showTimingSection {
                    VStack(alignment: .leading, spacing: 6) {
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
                            .frame(width: 180)
                        }

                        HStack {
                            Text("Rate")
                                .font(.caption)
                                .foregroundStyle(model.warpMode == .rate ? .primary : .secondary)

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
                                .foregroundStyle(model.warpMode == .rate ? .primary : .secondary)
                        }

                        HStack {
                            Text("Latency")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Slider(
                                value: $model.latencyOffsetSec,
                                in: -0.05...0.05,
                                step: 0.001
                            )

                            Text(String(format: "%+.3fs", model.latencyOffsetSec))
                                .font(.caption)
                                .monospacedDigit()
                                .frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: videoWidth + 40)
        .onAppear { setupOSC() }
    }

    // MARK: - File open

    private func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.movie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.openVideo(url: url)
        }
    }

    // MARK: - OSC wiring

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

// MARK: - Video surface

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

// MARK: - Trim timeline (window + markers)

struct TrimTimelineView: View {
    @Binding var start: Double   // global 0–1
    @Binding var end: Double     // global 0–1

    let slices: [VideoSamplerModel.Slice]   // window-relative
    let duration: Double

    /// Called on *double-tap* inside the yellow window strip (global 0–1)
    let onTapGlobal: (Double) -> Void

    /// Drag slice center inside window (0–1 window space)
    let onSliceDragged: (UUID, Double) -> Void

    /// Double-tap on a marker label to delete that slice.
    let onSliceDelete: (UUID) -> Void

    private let minSpan: Double = 0.02

    @State private var lastTapDate: Date?
    private let doubleTapThreshold: TimeInterval = 0.30

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)

            // Fixed bar thickness
            let barHeight: CGFloat = 14
            let barCenterY = height * 0.65
            let labelY = height * 0.15
            let handleWidth: CGFloat = 4

            let s = max(0.0, min(start, 1.0 - minSpan))
            let e = max(s + minSpan, min(end, 1.0))
            let span = max(0.0, e - s)

            let startX = CGFloat(s) * width
            let endX = CGFloat(e) * width

            ZStack(alignment: .leading) {
                // Background bar
                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(Color.gray.opacity(0.25))
                    .frame(height: barHeight)
                    .position(x: width / 2, y: barCenterY)

                // Selected window region (yellow-ish) – double-tap area for creating slices
                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(endX - startX, handleWidth), height: barHeight)
                    .position(x: (startX + endX) / 2, y: barCenterY)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                let now = Date()
                                if let last = lastTapDate,
                                   now.timeIntervalSince(last) <= doubleTapThreshold {
                                    // Double tap detected
                                    let x = max(0, min(width, value.location.x))
                                    let clampedX = max(startX, min(endX, x))
                                    let globalN = Double(clampedX / width)
                                    onTapGlobal(globalN)
                                    lastTapDate = nil
                                } else {
                                    // First tap
                                    lastTapDate = now
                                }
                            }
                    )

                // Start handle
                Rectangle()
                    .fill(Color.white)
                    .frame(width: handleWidth, height: barHeight + 4)
                    .shadow(radius: 1)
                    .position(x: startX, y: barCenterY)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let x = max(0, min(width, value.location.x))
                                let n = Double(x / width)
                                let clamped = max(0.0, min(n, e - minSpan))
                                start = clamped
                            }
                    )

                // End handle
                Rectangle()
                    .fill(Color.white)
                    .frame(width: handleWidth, height: barHeight + 4)
                    .shadow(radius: 1)
                    .position(x: endX, y: barCenterY)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let x = max(0, min(width, value.location.x))
                                let n = Double(x / width)
                                let clamped = min(1.0, max(n, s + minSpan))
                                end = clamped
                            }
                    )

                // Markers (window-relative) above bar
                ForEach(slices) { slice in
                    let centerWindowN = slice.centerN
                    let centerGlobalN = s + centerWindowN * span
                    let x = CGFloat(centerGlobalN) * width
                    let centerSec = centerGlobalN * duration

                    VStack(spacing: 0) {
                        let noteNumber = slice.assignedNotes.sorted().first ?? 36
                        Text(midiNoteName(noteNumber))
                            .font(.caption2)
                            .monospaced()
                        Text(formatTime(centerSec))
                            .font(.caption2)
                            .monospacedDigit()
                    }
                    .position(x: x, y: labelY)
                    // Drag to move slice horizontally within window
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let locX = max(0, min(width, value.location.x))
                                let newGlobal = Double(locX / width)
                                let newCenterWindow: Double
                                if span > 0 {
                                    newCenterWindow = (newGlobal - s) / span
                                } else {
                                    newCenterWindow = 0.5
                                }
                                onSliceDragged(slice.id, newCenterWindow)
                            }
                    )
                    // Double-tap on the label to delete this slice
                    .onTapGesture(count: 2) {
                        onSliceDelete(slice.id)
                    }

                    Path { path in
                        path.move(to: CGPoint(x: x, y: labelY + 6))
                        path.addLine(to: CGPoint(x: x, y: barCenterY - barHeight / 2 - 2))
                    }
                    .stroke(Color.primary.opacity(0.7), lineWidth: 1)
                }
            }
        }
    }
}

