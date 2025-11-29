import Foundation

final class OSCReceiver {
    private var sock: Int32 = -1
    private var source: DispatchSourceRead?

    /// note, i, o, vel
    var onNoteSlice: ((Int, Double, Double, Int) -> Void)?
    var onNoteOff: ((Int) -> Void)?

    init(port: UInt16 = 57120) {
        // 1) create UDP socket
        sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else {
            print("UDP: socket() failed")
            return
        }

        // 2) allow reuse
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))

        // 3) bind
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout.size(ofValue: addr))
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            print("UDP: bind() failed")
            close(sock)
            sock = -1
            return
        }

        // 4) set up dispatch source
        let q = DispatchQueue(label: "osc-receiver")
        source = DispatchSource.makeReadSource(fileDescriptor: sock, queue: q)

        source?.setEventHandler { [weak self] in
            self?.readPacket()
        }
        source?.setCancelHandler { [weak self] in
            if let fd = self?.sock, fd >= 0 {
                close(fd)
            }
        }
        source?.resume()
    }

    deinit {
        source?.cancel()
    }

    private func readPacket() {
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = recv(sock, &buf, buf.count, 0)
        guard n > 0 else { return }

        let data = Data(buf[0..<n])
        guard let s = String(data: data, encoding: .utf8) else { return }

        DispatchQueue.main.async {
            self.route(s)
        }
    }

    private func route(_ s: String) {
        // Debug: show every raw line
        print("RX:", s)

        if s.hasPrefix("/note_slice"),
           let j = jsonArg(s),
           let n = j["note"] as? Int,
           let i = j["i"] as? Double,
           let o = j["o"] as? Double,
           let v = j["vel"] as? Int {

            // 🔥 CALL THIS EVERY TIME – NO DEDUP
            self.onNoteSlice?(n, i, o, v)

        } else if s.hasPrefix("/note_off"),
                  let j = jsonArg(s),
                  let n = j["note"] as? Int {
            self.onNoteOff?(n)
        }
    }
}

private func jsonArg(_ s: String) -> [String:Any]? {
    guard let i = s.firstIndex(of: "{"), let j = s.lastIndex(of: "}") else { return nil }
    let sub = s[i...j]
    guard let d = sub.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String:Any]
}

