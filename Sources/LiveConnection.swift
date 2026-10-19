import Foundation

/// What WLED pushes over the websocket: the same shape as `/json`, minus the
/// effect and palette name lists.
struct WLEDPush: Decodable {
    var state: WLEDState?
    var info: WLEDInfo?
}

/// One persistent `ws://<host>/ws` connection per controller.
///
/// This is what keeps the menu honest: WLED broadcasts state to every connected
/// client whenever anything changes it — the phone app, a physical button, a
/// timer — so we stop guessing and stop polling. Broadcasts are rate-limited to
/// roughly one per second on the device side.
@MainActor
final class LiveConnection {

    let host: String
    var onPush: ((WLEDState) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reconnectDelay: UInt64 = 2
    private var reconnectTask: Task<Void, Never>?
    private var closed = false

    init(host: String) {
        self.host = host
    }

    func connect() {
        guard task == nil, !closed,
              let url = URL(string: "ws://\(host)/ws") else { return }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0   // a live socket is meant to idle
        let session = URLSession(configuration: config)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receive()
    }

    func disconnect() {
        closed = true
        reconnectTask?.cancel()
        reconnectTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receive() {
        guard let task else { return }

        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.closed else { return }

                switch result {
                case .success(let message):
                    self.reconnectDelay = 2       // a good frame resets backoff
                    self.handle(message)
                    self.receive()                // one-shot API: re-arm each time
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let raw):    data = raw        // only the opt-in live LED stream
        @unknown default:       data = nil
        }

        guard let data,
              let push = try? JSONDecoder().decode(WLEDPush.self, from: data),
              let state = push.state
        else { return }

        onPush?(state)
    }

    private func scheduleReconnect() {
        task = nil
        session?.invalidateAndCancel()
        session = nil
        guard !closed, reconnectTask == nil else { return }

        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }
}
