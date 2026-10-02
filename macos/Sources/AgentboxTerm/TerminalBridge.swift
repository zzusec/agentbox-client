import Foundation

final class TerminalBridge {
    var onData: ((Data) -> Void)?
    var onStatus: ((String) -> Void)?
    /// The connection ended: the server's close code (0 when the link just
    /// dropped without a close frame — a network change, a server restart)
    /// and its reason. Delivered once, on the main queue.
    var onClosed: ((Int, String) -> Void)?
    private var reportedSendFailure = false
    private var reportedClose = false

    private let url: URL
    private var socket: URLSessionWebSocketTask?
    private var closed = false

    init(url: URL) {
        self.url = url
    }

    func connect() {
        closed = false
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        onStatus?("connecting")
        receive()
        ping()
    }

    func send(data: Data) {
        guard !data.isEmpty else { return }
        let task = socket
        task?.send(.data(data)) { [weak self] error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                // Every keystroke on a dead socket fails the same way; one
                // report is enough. A failed send means the link is gone, so
                // it ends the connection instead of waiting for a receive
                // error that a half-open socket may never deliver.
                guard let self, task === self.socket, !self.reportedSendFailure else { return }
                self.reportedSendFailure = true
                self.onStatus?("send failed")
                self.linkLost()
            }
        }
    }

    func send(text: String) {
        send(data: Data(text.utf8))
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let payload = ["type": "resize", "cols": cols, "rows": rows] as [String: Any]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return
        }
        socket?.send(.string(text)) { _ in }
    }

    func close() {
        closed = true
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self, !self.closed else { return }
            switch result {
            case let .success(message):
                DispatchQueue.main.async {
                    switch message {
                    case let .data(data):
                        self.onData?(data)
                    case let .string(text):
                        self.onData?(Data(text.utf8))
                    @unknown default:
                        break
                    }
                }
                self.receive()
            case let .failure(error):
                let code = self.socket?.closeCode.rawValue ?? 0
                let reason = self.socket?.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                DispatchQueue.main.async {
                    self.onStatus?("closed: \(error.localizedDescription)")
                    self.reportClose(code: code, reason: reason)
                }
            }
        }
    }

    /// Delivers the close report once, on the main queue.
    private func reportClose(code: Int, reason: String) {
        guard !closed, !reportedClose else { return }
        reportedClose = true
        onClosed?(code, reason)
    }

    /// The link died without a close frame (send/ping failed or the server
    /// stopped answering): drop the socket and report it like a network drop,
    /// which the terminal answers with an automatic reconnect.
    private func linkLost() {
        guard !closed, !reportedClose else { return }
        let task = socket
        socket = nil
        task?.cancel(with: .goingAway, reason: nil)
        reportClose(code: 0, reason: "")
    }

    /// Pings every 15 s. A ping that fails, or gets no pong within 10 s,
    /// means the connection is dead even if the OS has not noticed yet
    /// (sleep/wake, Wi-Fi change, a proxy dropping an idle stream).
    private func ping() {
        let task = socket
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.closed, let task, task === self.socket else { return }
            let pong = PongFlag()
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, !pong.answered, task === self.socket else { return }
                self.onStatus?("ping timed out")
                self.linkLost()
            }
            task.sendPing { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, task === self.socket else { return }
                    pong.answered = true
                    if let error {
                        self.onStatus?("ping failed: \(error.localizedDescription)")
                        self.linkLost()
                    } else {
                        self.ping()
                    }
                }
            }
        }
    }
}

/// Whether a ping got its answer; only touched on the main queue.
private final class PongFlag {
    var answered = false
}
