import CryptoKit
import os
import Foundation
import Observation

/// Keeps the tasks in step with a remote server, and tells webhooks about changes.
///
/// Sync is one POST to the server URL (Settings › Tasks) with every project and
/// task and the ids deleted since the last sync; the server may answer with
/// projects and tasks to take (newer `updatedAt` wins) and ids to delete. It runs
/// two seconds after a change, on the interval, and on "Sync now".
///
/// Webhooks get a POST per change — `task.created`, `task.updated`,
/// `task.status`, `task.deleted` — with the task as JSON, an `X-Cue-Event`
/// header, and, when a secret is set, `X-Cue-Signature: sha256=<HMAC of the body>`.
@Observable
@MainActor
final class TaskSync {
    private let store: TaskStore
    private let preferences: AppPreferences

    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var syncing = false
    /// How many tasks the last sync took from the server.
    private(set) var lastTaken = 0
    private(set) var lastWebhook: String?

    @ObservationIgnored private var pushTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    private static let lastSyncKey = "tasks.sync.last"

    init(store: TaskStore, preferences: AppPreferences) {
        self.store = store
        self.preferences = preferences
        lastSync = UserDefaults.standard.object(forKey: Self.lastSyncKey) as? Date
        store.onChanged = { [weak self] in self?.scheduleSync() }
        store.onEvent = { [weak self] event in self?.send(event) }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A once-a-minute check, not a clock: the system may fold it in with others.
        timer?.tolerance = 15
    }

    // MARK: - Sync

    /// The sync URL, when one is set and is http(s).
    var serverURL: URL? { Self.url(preferences.tasksServerURL) }
    var webhookURL: URL? { Self.url(preferences.tasksWebhookURL) }

    private static func url(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host != nil else { return nil }
        return url
    }

    /// A change was saved: a sync follows shortly, unless more changes come first.
    private func scheduleSync() {
        guard preferences.tasksSyncEnabled, serverURL != nil else { return }
        pushTask?.cancel()
        pushTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    /// Every minute: a sync when the interval has passed.
    private func tick() {
        guard preferences.tasksSyncEnabled, serverURL != nil, preferences.tasksSyncInterval > 0 else { return }
        if let lastSync, Date.now.timeIntervalSince(lastSync) < Double(preferences.tasksSyncInterval * 60) { return }
        Task { await sync() }
    }

    /// Sends everything, takes what comes back.
    func sync() async {
        guard let url = serverURL else { lastError = TaskSyncError.noURL.localizedDescription; return }
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        let request = TaskSyncRequest(sentAt: .now, since: lastSync, projects: store.projects.map(RemoteProject.init),
                                      tasks: store.tasks.map(RemoteTask.init), deleted: store.deletedIDs)
        do {
            let data = try await post(request, to: url, token: preferences.tasksServerToken, headers: [:])
            var taken = 0
            if !data.isEmpty, let response = try? TaskWire.decoder.decode(TaskSyncResponse.self, from: data) {
                taken = store.applyRemote(tasks: (response.tasks ?? []).map(\.item), projects: (response.projects ?? []).map(\.project), deleted: response.deleted ?? [])
            }
            store.clearDeleted(request.deleted)
            lastTaken = taken
            lastSync = .now
            lastError = nil
            UserDefaults.standard.set(lastSync, forKey: Self.lastSyncKey)
            Log.app.info("Tasks sync: sent \(request.tasks.count) tasks, took \(taken)")
        } catch {
            lastError = error.localizedDescription
            Log.app.error("Tasks sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A ping to the server URL; the answer's status is what counts.
    func check() async throws -> String {
        guard let url = serverURL else { throw TaskSyncError.noURL }
        struct Ping: Encodable { var client = "cue"; var version = 1; var ping = true; var sentAt = Date.now }
        let start = Date.now
        _ = try await post(Ping(), to: url, token: preferences.tasksServerToken, headers: [:])
        return "Connected · \(Int(Date.now.timeIntervalSince(start) * 1000)) ms"
    }

    // MARK: - Webhooks

    /// A change: sent to the webhook when it is on and wants this kind of event.
    private func send(_ event: TaskEvent) {
        guard preferences.tasksWebhookEnabled, let url = webhookURL, preferences.tasksWebhookEvents.contains(event.kind) else { return }
        let payload = TaskWebhookEvent(event: event.name, sentAt: .now, task: RemoteTask(event.task), project: store.project(event.task.projectID).map(RemoteProject.init))
        let secret = preferences.tasksWebhookSecret
        Task { @MainActor in
            do {
                _ = try await post(payload, to: url, token: nil, headers: ["X-Cue-Event": event.name], secret: secret)
                lastWebhook = "\(event.name) · \(Date.now.formatted(date: .omitted, time: .shortened))"
            } catch {
                lastWebhook = "\(event.name) failed: \(error.localizedDescription)"
                Log.app.error("Webhook \(event.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// A `ping` event, to see the webhook receive something.
    func sendTest() async throws {
        guard let url = webhookURL else { throw TaskSyncError.noURL }
        let payload = TaskWebhookEvent(event: "ping", sentAt: .now, task: store.tasks.first.map(RemoteTask.init), project: nil)
        _ = try await post(payload, to: url, token: nil, headers: ["X-Cue-Event": "ping"], secret: preferences.tasksWebhookSecret)
        lastWebhook = "ping · \(Date.now.formatted(date: .omitted, time: .shortened))"
    }

    // MARK: - HTTP

    /// POSTs JSON; a 2xx answer's body comes back, anything else throws.
    private func post(_ payload: some Encodable, to url: URL, token: String?, headers: [String: String], secret: String = "") async throws -> Data {
        let body = try TaskWire.encoder.encode(payload)
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Cue/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if !secret.isEmpty { request.setValue(TaskWire.signature(of: body, secret: secret), forHTTPHeaderField: "X-Cue-Signature") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TaskSyncError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw TaskSyncError.status(http.statusCode, String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}
