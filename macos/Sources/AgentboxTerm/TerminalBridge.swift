import Foundation

final class TerminalBridge {
    var onData: ((Data) -> Void)?
    var onStatus: ((String) -> Void)?

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
        socket?.send(.data(data)) { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.onStatus?("send failed: \(error.localizedDescription)")
                }
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
                DispatchQueue.main.async {
                    self.onStatus?("closed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func ping() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, !self.closed else { return }
            self.socket?.sendPing { [weak self] error in
                guard let self else { return }
                if let error {
                    DispatchQueue.main.async {
                        self.onStatus?("ping failed: \(error.localizedDescription)")
                    }
                } else {
                    self.ping()
                }
            }
        }
    }
}
