import SwiftUI

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

                    ForEach(
                        mapping.sorted(by: { $0.value < $1.value }),
                        id: \.key
                    ) { note, index in

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
