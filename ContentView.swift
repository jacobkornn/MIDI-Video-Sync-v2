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

// Helper to parse strings like "C3", "G#4" into MIDI note numbers.
fileprivate func parseMidiNoteName(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !trimmed.isEmpty else { return nil }

    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    var name = ""
    var octavePart = ""

    for ch in trimmed {
        if ch == "#" || (ch >= "A" && ch <= "Z") {
            name.append(ch)
        } else if ch.isNumber || ch == "-" {
            octavePart.append(ch)
        }
    }

    guard !name.isEmpty, !octavePart.isEmpty,
          let octave = Int(octavePart),
          let idx = names.firstIndex(of: name) else {
        return nil
    }

    // Inverse of midiNoteName mapping
    let note = (octave + 2) * 12 + idx
    return note
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
        HStack(alignment: .top, spacing: 24) {

            // ---------- LEFT: VIDEO ----------
            VStack {
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
                        VStack(spacing: 8) {
                            Image(systemName: "plus")
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("Add Video")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: videoWidth, height: videoHeight)
                .contentShape(Rectangle())
                .onTapGesture {
                    if model.currentFrameImage == nil {
                        openVideo()
                    }
                }
            }

            // ---------- CENTER: CONTROLS + TIMELINES ----------
            VStack(alignment: .leading, spacing: 8) {

                // File / status
                HStack {
                    Button("Open Video…") { openVideo() }

                    Spacer()

                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Bounds timeline (no label, no stamps)
                TrimTimelineView(
                    start: $model.winStart,
                    end: $model.winEnd,
                    slices: [],                      // no markers here
                    duration: model.duration,
                    onTapGlobal: { _ in },            // disable double-tap creation
                    onSliceDragged: { _, _ in },      // not used
                    onSliceDelete: { _ in }           // not used
                )
                .frame(height: 40)

                Divider()

                // Slice mode tabs (no label, centered)
                HStack {
                    Spacer()
                    Picker("", selection: $model.sliceMode) {
                        Text("Auto").tag(VideoSamplerModel.SliceMode.auto)
                        Text("Manual").tag(VideoSamplerModel.SliceMode.manual)
                        Text("Chrom").tag(VideoSamplerModel.SliceMode.chrom)
                        Text("Random").tag(VideoSamplerModel.SliceMode.random)
                    }
                    .pickerStyle(.segmented)
                    Spacer()
                }

                // Auto-only Continuous toggle
                if model.sliceMode == .auto {
                    Toggle("Continuous", isOn: $model.autoContinuous)
                        .toggleStyle(.switch)
                        .font(.caption)
                        .padding(.top, 4)
                        .padding(.leading, 4)
                }

                // Stamp timeline (Manual / Chrom / Random)
                if model.sliceMode != .auto {
                    SliceTimelineView(model: model)
                        .frame(height: 44)        // a bit taller for breathing room
                        .padding(.top, 4)         // space above bar
                }

                // Clear button only (manual mode)
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

                // Chromatic range controls
                if model.sliceMode == .chrom {
                    HStack {
                        let notes = model.chromaticNotes()
                        let lowNote = notes.first ?? 60
                        let highNote = notes.last ?? 83
                        Text("Chrom range: \(midiNoteName(lowNote)) – \(midiNoteName(highNote))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("−") {
                            model.chromaticBaseOctave = max(-2, model.chromaticBaseOctave - 1)
                        }
                        .font(.caption2)
                        Button("+") {
                            model.chromaticBaseOctave = min(8, model.chromaticBaseOctave + 1)
                        }
                        .font(.caption2)
                    }
                }

                // Random range + shuffle controls
                if model.sliceMode == .random {
                    HStack(spacing: 8) {
                        Text("Random range:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        // Low note
                        Button("−") {
                            model.randomRangeLow = max(0, model.randomRangeLow - 1)
                            if model.randomRangeLow > model.randomRangeHigh {
                                model.randomRangeHigh = model.randomRangeLow
                            }
                        }
                        .font(.caption2)

                        Text(midiNoteName(model.randomRangeLow))
                            .font(.caption2)
                            .monospaced()

                        Button("+") {
                            model.randomRangeLow += 1
                            if model.randomRangeLow > model.randomRangeHigh {
                                model.randomRangeHigh = model.randomRangeLow
                            }
                        }
                        .font(.caption2)

                        Text("–")
                            .font(.caption2)

                        // High note
                        Button("−") {
                            model.randomRangeHigh = max(0, model.randomRangeHigh - 1)
                            if model.randomRangeHigh < model.randomRangeLow {
                                model.randomRangeLow = model.randomRangeHigh
                            }
                        }
                        .font(.caption2)

                        Text(midiNoteName(model.randomRangeHigh))
                            .font(.caption2)
                            .monospaced()

                        Button("+") {
                            model.randomRangeHigh += 1
                            if model.randomRangeHigh < model.randomRangeLow {
                                model.randomRangeLow = model.randomRangeHigh
                            }
                        }
                        .font(.caption2)

                        Spacer()

                        Button("Shuffle") {
                            model.shuffleRandomSlices()
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                    }
                }

                // Arrow to collapse/expand timing section
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

                // WARP / RATE / LATENCY (collapsible)
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
            // Make control column ~2x video width so timelines are wide
            .frame(width: videoWidth * 2)

            // ---------- RIGHT: EMPTY SPACE FOR FUTURE ----------
            Spacer(minLength: 0)
        }
        .padding()
        .onAppear { setupOSC() }
        .onChange(of: model.sliceMode) { newMode in
            // Initialize random mapping on first enter, so stamps appear immediately
            if newMode == .random && model.randomMapping.isEmpty {
                model.shuffleRandomSlices()
            }
        }
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

// MARK: - Trim timeline (window editor)

struct TrimTimelineView: View {
    @Binding var start: Double   // global 0–1
    @Binding var end: Double     // global 1–1

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

                // Selected window region (yellow-ish)
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
                                    let x = max(0, min(width, value.location.x))
                                    let clampedX = max(startX, min(endX, x))
                                    let globalN = Double(clampedX / width)
                                    onTapGlobal(globalN)
                                    lastTapDate = nil
                                } else {
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

                // Markers (unused now; slices = [])
                ForEach(slices) { slice in
                    let centerWindowN = slice.centerN
                    let centerGlobalN = span > 0
                        ? (s + centerWindowN * span)
                        : s
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

// MARK: - Slice timeline (stamps only, independent of bounds visuals)

struct SliceTimelineView: View {
    @ObservedObject var model: VideoSamplerModel

    @State private var lastTapDate: Date?
    private let doubleTapThreshold: TimeInterval = 0.30

    @State private var editingSliceID: UUID?
    @State private var editingNoteText: String = ""
    @State private var hoveredSliceID: UUID?

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let height = max(geo.size.height, 1)

            let barHeight: CGFloat = 14
            let barCenterY = height * 0.65
            let labelY = height * 0.10

            let s = model.winStart
            let e = model.winEnd
            let span = max(0.0, e - s)

            ZStack(alignment: .leading) {

                // ---------- BACKGROUND BAR (visual only) ----------
                RoundedRectangle(cornerRadius: barHeight / 2)
                    .fill(Color.gray.opacity(0.25))
                    .frame(height: barHeight)
                    .position(x: width / 2, y: barCenterY)
                    .allowsHitTesting(false)

                // ---------- INTERACTION LAYER (double-tap to create) ----------
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: barHeight + 12)
                    .position(x: width / 2, y: barCenterY)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                guard model.sliceMode == .manual else { return }
                                guard model.duration > 0 else { return }

                                let now = Date()
                                if let last = lastTapDate,
                                   now.timeIntervalSince(last) <= doubleTapThreshold {

                                    let x = max(0, min(width, value.location.x))
                                    let centerN = Double(x / width)

                                    model.addSliceAtWindowPosition(centerN: centerN)

                                    if let slice = model.slices.last {
                                        let idx = model.slices.count - 1
                                        let note = 36 + idx
                                        model.assign(note: note, to: slice.id)
                                    }

                                    lastTapDate = nil
                                } else {
                                    lastTapDate = now
                                }
                            }
                    )

                // ---------- MANUAL MODE ----------
                if model.sliceMode == .manual {
                    ForEach(Array(model.slices.enumerated()), id: \.element.id) { idx, slice in
                        let centerN = slice.centerN
                        let x = CGFloat(centerN) * width

                        let centerGlobalN = span > 0
                            ? (s + centerN * span)
                            : s

                        let primaryNote =
                            slice.assignedNotes.sorted().first ?? (36 + idx)

                        ZStack(alignment: .topTrailing) {
                            VStack(spacing: 0) {
                                if editingSliceID == slice.id {
                                    TextField(
                                        "",
                                        text: $editingNoteText,
                                        onCommit: {
                                            if let newNote = parseMidiNoteName(editingNoteText) {
                                                model.setPrimaryNote(newNote, for: slice.id)
                                            }
                                            editingSliceID = nil
                                            editingNoteText = ""
                                        }
                                    )
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 52)
                                } else {
                                    Text(midiNoteName(primaryNote))
                                        .font(.caption2)
                                        .monospaced()
                                        .onHover { isHover in
                                            hoveredSliceID = isHover ? slice.id : nil
                                        }
                                        .onTapGesture(count: 2) {
                                            editingSliceID = slice.id
                                            editingNoteText = midiNoteName(primaryNote)
                                        }
                                }
                            }

                            // X only appears when hovering label
                            Button {
                                model.slices.removeAll { $0.id == slice.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                            .opacity(hoveredSliceID == slice.id ? 1.0 : 0.0)
                        }
                        .position(x: x, y: labelY)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let locX = max(0, min(width, value.location.x))
                                    let newCenterN = Double(locX / width)
                                    model.updateSliceCenter(
                                        sliceID: slice.id,
                                        newCenterN: newCenterN
                                    )
                                }
                        )

                        Path { path in
                            path.move(to: CGPoint(x: x, y: labelY + 6))
                            path.addLine(
                                to: CGPoint(
                                    x: x,
                                    y: barCenterY - barHeight / 2 - 2
                                )
                            )
                        }
                        .stroke(Color.primary.opacity(0.7), lineWidth: 1)
                    }
                }

                // ---------- CHROM MODE ----------
                if model.sliceMode == .chrom {
                    let notes = model.chromaticNotes()
                    let count = max(notes.count, 1)

                    ForEach(0..<count, id: \.self) { idx in
                        let centerN = (Double(idx) + 0.5) / Double(count)
                        let x = CGFloat(centerN) * width

                        VStack {
                            Text(midiNoteName(notes[idx]))
                                .font(.caption2)
                                .monospaced()
                        }
                        .position(x: x, y: labelY)

                        Path { path in
                            path.move(to: CGPoint(x: x, y: labelY + 6))
                            path.addLine(
                                to: CGPoint(
                                    x: x,
                                    y: barCenterY - barHeight / 2 - 2
                                )
                            )
                        }
                        .stroke(Color.primary.opacity(0.7), lineWidth: 1)
                    }
                }

                // ---------- RANDOM MODE ----------
                if model.sliceMode == .random {
                    let mapping = model.randomMapping
                    let count = max(mapping.count, 1)

                    ForEach(mapping.sorted(by: { $0.value < $1.value }),
                            id: \.key) { note, index in

                        let centerN = (Double(index) + 0.5) / Double(count)
                        let x = CGFloat(centerN) * width

                        VStack {
                            Text(midiNoteName(note))
                                .font(.caption2)
                                .monospaced()
                        }
                        .position(x: x, y: labelY)

                        Path { path in
                            path.move(to: CGPoint(x: x, y: labelY + 6))
                            path.addLine(
                                to: CGPoint(
                                    x: x,
                                    y: barCenterY - barHeight / 2 - 2
                                )
                            )
                        }
                        .stroke(Color.primary.opacity(0.7), lineWidth: 1)
                    }
                }
            }
        }
    }
}

