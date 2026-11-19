import Foundation
import os

/// Sensory OS's live feed: a Supabase Realtime socket (the Phoenix channel protocol)
/// listening for changes to the person's tasks and new notifications.
///
/// An event is only a nudge. Cue never stores what the socket says; it asks the API
/// (`/sync`, `/notifications`) for what changed, so everything kept comes one way. The
/// socket carries the person's own access token, so row-level security decides what it
/// hears — the same rows the dashboard's live updates would show them.
@MainActor
final class SOSRealtime {
    enum Table: String { case tasks, notifications }

    /// A change landed on one of the tables.
    var onChange: (Table) -> Void = { _ in }
    /// Whether the channel is joined, for Settings.
    private(set) var isLive = false

    private var socket: URLSessionWebSocketTask?
    private var heartbeat: Task<Void, Never>?
    private var reconnect: Task<Void, Never>?
    private var ref = 0
    private var topic = ""
    private var attempts = 0
    private var config: (url: URL, key: String, token: String, userID: String, agencies: [String])?
    private let log = Logger(subsystem: "com.stackrover.cue", category: "sensory-os")

    /// Connects (or reconnects with new settings). The URL is the Supabase project's.
    func start(supabaseURL: URL, key: String, token: String, userID: String, agencies: [String]) {
        let next = (url: supabaseURL, key: key, token: token, userID: userID, agencies: agencies)
        if let config, config.url == next.url, config.userID == next.userID, config.agencies == next.agencies, socket != nil {
            if config.token != token { updateToken(token) }
            return
        }
        stop()
        config = next
        open()
    }

    func stop() {
        heartbeat?.cancel()
        reconnect?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        isLive = false
        config = nil
    }

    /// A refreshed token, so the channel keeps authorizing as the person.
    func updateToken(_ token: String) {
        guard config != nil else { return }
        config?.token = token
        send(topic: topic, event: "access_token", payload: ["access_token": token])
    }

    private func open() {
        guard let config, var components = URLComponents(url: config.url, resolvingAgainstBaseURL: false) else { return }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = "/realtime/v1/websocket"
        components.queryItems = [URLQueryItem(name: "apikey", value: config.key), URLQueryItem(name: "vsn", value: "1.0.0")]
        guard let url = components.url else { return }
        let socket = URLSession.shared.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        listen(socket)

        topic = "realtime:cue-\(UUID().uuidString.lowercased())"
        var changes: [[String: Any]] = [["event": "INSERT", "schema": "public", "table": "notifications", "filter": "recipient_id=eq.\(config.userID)"]]
        for agency in config.agencies {
            changes.append(["event": "*", "schema": "public", "table": "tasks", "filter": "agency_id=eq.\(agency)"])
        }
        send(topic: topic, event: "phx_join", payload: [
            "config": ["broadcast": ["self": false], "presence": ["key": ""], "postgres_changes": changes, "private": false],
            "access_token": config.token,
        ])
        heartbeat?.cancel()
        heartbeat = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                self?.send(topic: "phoenix", event: "heartbeat", payload: [:])
            }
        }
    }

    private func listen(_ socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === socket else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.listen(socket)
                case .failure(let error):
                    self.log.info("Realtime closed: \(error.localizedDescription, privacy: .public)")
                    self.dropped()
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8), let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = message["event"] as? String else { return }
        let payload = message["payload"] as? [String: Any]
        switch event {
        case "phx_reply":
            if (message["topic"] as? String) == topic, (payload?["status"] as? String) == "ok", !isLive {
                isLive = true
                attempts = 0
                log.info("Realtime joined")
            } else if (payload?["status"] as? String) == "error" {
                log.error("Realtime join refused: \(String(describing: payload?["response"]), privacy: .public)")
            }
        case "postgres_changes":
            let table = (payload?["data"] as? [String: Any])?["table"] as? String
            if let table = table.flatMap(Table.init(rawValue:)) { onChange(table) }
        case "phx_error", "phx_close":
            if (message["topic"] as? String) == topic { dropped() }
        case "system":
            if (payload?["status"] as? String) == "error" {
                log.error("Realtime: \(String(describing: payload?["message"]), privacy: .public)")
            }
        default:
            break
        }
    }

    /// Back off and come back: 2, 4, 8 … seconds, at most a minute.
    private func dropped() {
        isLive = false
        heartbeat?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        guard config != nil else { return }
        attempts += 1
        let wait = min(60.0, pow(2.0, Double(min(attempts, 6))))
        reconnect?.cancel()
        reconnect = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, self.config != nil, self.socket == nil else { return }
            self.open()
        }
    }

    private func send(topic: String, event: String, payload: [String: Any]) {
        guard let socket else { return }
        ref += 1
        var message: [String: Any] = ["topic": topic, "event": event, "payload": payload, "ref": String(ref)]
        if event == "phx_join" { message["join_ref"] = String(ref) }
        guard let data = try? JSONSerialization.data(withJSONObject: message), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }
}
