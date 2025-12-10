import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var model = VideoSamplerModel()
    @State private var osc: OSCReceiver?

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

            // ---------- CENTER: CONTROLS ----------
            VStack(alignment: .leading, spacing: 8) {

                HStack {
                    Button("Open Video…") { openVideo() }
                    Spacer()
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TrimTimelineView(
                    start: $model.winStart,
                    end: $model.winEnd,
                    slices: [],
                    duration: model.duration,
                    onTapGlobal: { _ in },
                    onSliceDragged: { _, _ in },
                    onSliceDelete: { _ in }
                )
                .frame(height: 40)

                Divider()

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

                if model.sliceMode == .auto {
                    Toggle("Continuous", isOn: $model.autoContinuous)
                        .toggleStyle(.switch)
                        .font(.caption)
                        .padding(.top, 4)
                        .padding(.leading, 4)
                }

                if model.sliceMode != .auto {
                    SliceTimelineView(model: model)
                        .frame(height: 44)
                        .padding(.top, 4)
                }

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

                // ---------- CHROM CONTROLS ----------
                if model.sliceMode == .chrom {
                    HStack {
                        let notes = model.chromaticNotes()
                        let lowNote = notes.first ?? 60
                        let highNote = notes.last ?? 83

                        Text("Chrom range: \(midiNoteName(lowNote)) – \(midiNoteName(highNote))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("−") { model.chromaticBaseOctave -= 1 }
                            .font(.caption2)

                        Button("+") { model.chromaticBaseOctave += 1 }
                            .font(.caption2)
                    }
                }

                // ---------- RANDOM CONTROLS ----------
                if model.sliceMode == .random {
                    HStack(spacing: 8) {
                        Text("Random range:")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

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

                // ---------- TIMING TOGGLE ----------
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showTimingSection.toggle()
                        }
                    } label: {
                        Image(systemName: showTimingSection ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }

                Divider()

                // ---------- WARP / RATE / LATENCY ----------
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
                                .foregroundStyle(
                                    model.warpMode == .rate ? .primary : .secondary
                                )

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
            .frame(width: videoWidth * 2)

            Spacer(minLength: 0)
        }
        .padding()
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
                //model?.stopIfNeeded(note: note)
            }
        }

        osc = r
    }
}

