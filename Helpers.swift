import Foundation

// MARK: - Helpers

func midiNoteName(_ note: Int) -> String {
    let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    let idx = ((note % 12) + 12) % 12
    let octave = note / 12 - 2      // 36 -> C1
    return "\(names[idx])\(octave)"
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite && !seconds.isNaN else { return "--:--" }
    let totalMs = Int((seconds * 1000).rounded())
    let ms = totalMs % 1000
    let totalSeconds = totalMs / 1000
    let s = totalSeconds % 60
    let m = totalSeconds / 60
    return String(format: "%d:%02d.%03d", m, s, ms)
}

func parseMidiNoteName(_ text: String) -> Int? {
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

    guard !name.isEmpty,
          !octavePart.isEmpty,
          let octave = Int(octavePart),
          let idx = names.firstIndex(of: name) else {
        return nil
    }

    let note = (octave + 2) * 12 + idx
    return note
}

