import SwiftUI

// MARK: - Trim timeline (window editor)

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
                        let noteNumber =
                            slice.assignedNotes.sorted().first ?? 36

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

