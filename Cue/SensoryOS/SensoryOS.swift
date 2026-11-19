import AppKit
import Foundation
import Observation
import os
import UserNotifications

/// Cue connected to Sensory OS: the person's Sensory OS tasks kept in Cue's task list,
/// under an organization of their own ("Sensory OS", one project per board), tasks made
/// there sent to the website, and their Sensory OS notifications shown on the island
/// and as macOS notifications.
///
/// Only the organization's tasks ever leave the Mac; local projects stay local. The
/// website's side is `/api/desktop/v1/*` (docs/integrations/cue-desktop.md in Sensory OS).
///
/// One loop does all the talking — take what changed there, then send what changed
/// here — and never runs twice at once, so a task Cue just made cannot come back from
/// the website as a second copy before Cue has heard its id.
@Observable
@MainActor
final class SensoryOS {
    enum Phase: Equatable { case disconnected, connecting, connected }

    private(set) var phase: Phase = .disconnected
    private(set) var me: SOSMe?
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var busy = false
    /// The live feed is joined (changes arrive at once, not on the next minute).
    private(set) var isLive = false
    /// The sign-in page while a sign-in waits, so Settings can open it again.
    private(set) var signInURL: URL?

    // MARK: Settings

    /// The site to connect to; production unless changed (a staging or local server).
    var serverText: String {
        didSet { defaults.set(serverText, forKey: Keys.server) }
    }
    /// `mine`: tasks the person holds or made. `all`: every board they can see.
    var scope: String {
        didSet {
            guard scope != oldValue else { return }
            defaults.set(scope, forKey: Keys.scope)
            resetCursors()
            requestRun()
        }
    }
    var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notifications) }
    }

    /// A Sensory OS notification arrived: for the island. The URL opens it.
    @ObservationIgnored var onNotification: (SOSNotification, URL?) -> Void = { _, _ in }
    /// Opens one of Cue's own tasks (a notification about a task Cue has).
    @ObservationIgnored var openTask: (UUID) -> Void = { _ in }

    // MARK: State

    @ObservationIgnored private let store: TaskStore
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var tokens: SOSTokens?
    @ObservationIgnored private var refreshing: Task<SOSTokens, Error>?
    @ObservationIgnored private var signIn: SOSSignIn?
    @ObservationIgnored private let realtime = SOSRealtime()
    @ObservationIgnored private let notifier = SOSNotifier()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var runAgain = false
    @ObservationIgnored private var pushSoon: Task<Void, Never>?
    @ObservationIgnored private var boards: [String: [SOSBoard]] = [:]
    @ObservationIgnored private var meFetched: Date?
    @ObservationIgnored private var notificationsChecked: Date?
    @ObservationIgnored private let log = Logger(subsystem: "com.stackrover.cue", category: "sensory-os")
    /// What this run sent and posted, for the debug report.
    @ObservationIgnored private(set) var journal: [String] = []

    private enum Keys {
        static let server = "sensoryos.server"
        static let scope = "sensoryos.scope"
        static let notifications = "sensoryos.notifications"
        static let notificationsSince = "sensoryos.notifications.since"
        static let notificationsSeen = "sensoryos.notifications.seen"
        static let announced = "sensoryos.announced"
        static let dismissed = "sensoryos.dismissed"
        static let lastSync = "sensoryos.lastSync"
        static func cursor(_ scope: String, _ agency: String) -> String { "sensoryos.cursor.\(scope).\(agency)" }
    }

    init(store: TaskStore) {
        self.store = store
        serverText = defaults.string(forKey: Keys.server) ?? SOSServer.production.absoluteString
        scope = defaults.string(forKey: Keys.scope) ?? "mine"
        notificationsEnabled = defaults.object(forKey: Keys.notifications) as? Bool ?? true
        lastSync = defaults.object(forKey: Keys.lastSync) as? Date

        store.onLocalChange = { [weak self] in self?.scheduleRun() }
        store.onOrgDeleted = { [weak self] _, remote in
            guard let self, let id = remote.taskID else { return }
            self.dismiss(id)
        }
        realtime.onChange = { [weak self] table in
            guard let self else { return }
            switch table {
            case .tasks: self.requestRun()
            case .notifications: Task { await self.checkNotifications() }
            }
        }
        notifier.onOpen = { [weak self] id, url, taskEntity in self?.open(notificationID: id, url: url, taskEntity: taskEntity) }

        if let saved = SOSKeychain.load() {
            tokens = saved
            phase = .connected
            Task { await start() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 15
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestRun() }
        }
    }

    var server: SOSServer? { SOSServer.origin(from: serverText).map(SOSServer.init) }
    var agencies: [SOSAgency] { me?.agencies ?? [] }

    /// Tasks made or changed here that the website has not taken yet.
    var unsent: Int {
        store.tasks.filter { task in
            guard let remote = task.remote ?? (store.orgProject(task.projectID) != nil ? RemoteLink(source: SOSMap.source, agencyID: "", boardID: "") : nil) else { return false }
            guard remote.taskID != nil, let base = remote.base else { return true }
            return SOSMap.changes(SOSMap.values(of: task), from: base) != nil
        }.count
    }

    // MARK: - Connecting

    enum SignInMode { case sheet, browser, manual((URL) -> Void) }

    /// Signs in with Google and starts keeping in step. `sheet`: the system sign-in window.
    /// `browser`: the default browser (its answer comes back through Cue's URL handler).
    func connect(mode: SignInMode = .sheet) async {
        guard phase != .connecting else { return }
        guard let server else {
            lastError = "Enter the Sensory OS address, starting with https://"
            return
        }
        phase = .connecting
        lastError = nil
        do {
            let config = try await SOSAuth.config(server)
            guard config.offersGoogle else { throw SOSAuthError.server("This Sensory OS doesn't offer Google sign-in. Use your email and password.") }
            let attempt = SOSSignIn(server: server, config: config)
            signIn = attempt
            signInURL = attempt.url
            // Supabase keeps a sign-in's PKCE request for a limited time; one left open longer can't finish.
            let deadline = Task { @MainActor [weak attempt] in
                try? await Task.sleep(for: .seconds(600))
                guard !Task.isCancelled else { return }
                attempt?.expire()
            }
            defer {
                deadline.cancel()
                signInURL = nil
            }
            let callback: URL
            switch mode {
            case .sheet:
                callback = try await attempt.answer(sheet: true)
            case .browser:
                NSWorkspace.shared.open(attempt.url)
                callback = try await attempt.answer(sheet: false)
            case .manual(let show):
                show(attempt.url)
                callback = try await attempt.answer(sheet: false)
            }
            let fresh = try await attempt.tokens(from: callback)
            signIn = nil
            use(fresh)
            phase = .connected
            await start()
        } catch {
            signIn = nil
            phase = tokens == nil ? .disconnected : .connected
            if (error as? SOSAuthError) != .cancelled { lastError = error.localizedDescription }
            log.error("Sensory OS sign-in failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Signs in with the email and password the person uses on the website, and starts
    /// keeping in step. The password goes to Sensory OS's sign-in server and nowhere else;
    /// Cue keeps only the tokens it answers with.
    func connect(email: String, password: String) async {
        guard phase != .connecting else { return }
        guard let server else {
            lastError = "Enter the Sensory OS address, starting with https://"
            return
        }
        guard !email.trimmingCharacters(in: .whitespaces).isEmpty, !password.isEmpty else {
            lastError = "Enter your email and password."
            return
        }
        phase = .connecting
        lastError = nil
        do {
            let config = try await SOSAuth.config(server)
            guard config.offersEmail else { throw SOSAuthError.server("This Sensory OS doesn't offer email sign-in. Use Google.") }
            let fresh = try await SOSAuth.password(email: email, password: password, config: config, server: server)
            use(fresh)
            phase = .connected
            await start()
        } catch {
            phase = tokens == nil ? .disconnected : .connected
            lastError = error.localizedDescription
            log.error("Sensory OS sign-in failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A `cue://oauth/sensory-os?…` URL: the answer to the sign-in under way.
    func handle(_ url: URL) -> Bool {
        guard let signIn, signIn.matches(url) else {
            return url.scheme == SOSServer.callbackScheme && url.host == SOSServer.callbackHost && url.path == SOSServer.callbackPath
        }
        signIn.receive(url)
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func cancelSignIn() { signIn?.cancel() }

    /// Opens the waiting sign-in in the browser (the window was closed, or never showed).
    /// The answer comes back through Cue's URL handler.
    func openSignInPage() {
        guard let signInURL else { return }
        NSWorkspace.shared.open(signInURL)
    }

    /// Signs out and removes the organization's copy from Cue (the website keeps it all).
    func disconnect() {
        signIn?.cancel()
        realtime.stop()
        isLive = false
        tokens = nil
        SOSKeychain.save(nil)
        me = nil
        boards = [:]
        resetCursors()
        defaults.removeObject(forKey: Keys.notificationsSince)
        defaults.removeObject(forKey: Keys.notificationsSeen)
        defaults.removeObject(forKey: Keys.dismissed)
        defaults.removeObject(forKey: Keys.announced)
        store.removeOrg(source: SOSMap.source)
        phase = .disconnected
        lastError = nil
        note("disconnected")
    }

    private func use(_ fresh: SOSTokens) {
        tokens = fresh
        SOSKeychain.save(fresh)
        realtime.updateToken(fresh.accessToken)
    }

    /// After signing in, and on launch when signed in: who, where, then everything.
    private func start() async {
        do {
            try await loadMe()
            notifier.requestPermission()
            await run()
            await checkNotifications()
        } catch {
            report(error)
        }
    }

    private func loadMe() async throws {
        let me: SOSMe = try await call("GET", "/api/desktop/v1/me")
        self.me = me
        meFetched = .now
        startRealtime()
    }

    private func startRealtime() {
        guard let me, let tokens, let url = me.realtime?.url.flatMap(URL.init(string:)), let key = me.realtime?.key, !key.isEmpty else { return }
        realtime.start(supabaseURL: url, key: key, token: tokens.accessToken, userID: me.user.id, agencies: me.agencies.map(\.id))
        Task { @MainActor [weak self] in
            // the join answers within a moment; Settings shows whether it took
            try? await Task.sleep(for: .seconds(3))
            self?.isLive = self?.realtime.isLive ?? false
        }
    }

    // MARK: - The loop

    private func tick() {
        guard phase == .connected else { return }
        isLive = realtime.isLive
        // the agencies (and the live feed's filter) now and then; tasks every minute
        if let meFetched, Date.now.timeIntervalSince(meFetched) > 15 * 60 { Task { try? await loadMe() } }
        requestRun()
        let every: TimeInterval = isLive ? 5 * 60 : 60
        if notificationsChecked.map({ Date.now.timeIntervalSince($0) >= every - 5 }) ?? true {
            Task { await checkNotifications() }
        }
    }

    /// A change was saved here: send it shortly, unless more come first.
    private func scheduleRun() {
        guard phase == .connected else { return }
        pushSoon?.cancel()
        pushSoon = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.requestRun()
        }
    }

    func requestRun() {
        guard phase == .connected else { return }
        Task { await run() }
    }

    /// Take what changed on the website, then send what changed here. A request while
    /// it runs makes it go round once more instead of running alongside.
    func run() async {
        guard phase == .connected else { return }
        if busy {
            runAgain = true
            return
        }
        busy = true
        defer { busy = false }
        repeat {
            runAgain = false
            do {
                if me == nil { try await loadMe() }
                try await pull()
                try await push()
                lastSync = .now
                defaults.set(lastSync, forKey: Keys.lastSync)
                lastError = nil
            } catch {
                report(error)
                return
            }
        } while runAgain
    }

    private func report(_ error: Error) {
        if (error as? SOSAuthError) == .signedOut {
            disconnect()
            lastError = SOSAuthError.signedOut.localizedDescription
        } else {
            lastError = error.localizedDescription
        }
        log.error("Sensory OS: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: - Taking

    private func pull() async throws {
        guard let me else { return }
        var fetched: [(agency: SOSAgency, boards: [SOSBoard], tasks: [SOSTask], ids: Set<String>?, cursor: String?, caughtUp: Bool)] = []
        for agency in me.agencies {
            var since = defaults.string(forKey: Keys.cursor(scope, agency.id))
            // A first look at an agency brings in everything there already is: none of it is news.
            let caughtUp = since != nil
            var tasks: [SOSTask] = []
            var page: SOSSync
            var rounds = 0
            repeat {
                var query = [URLQueryItem(name: "agencyId", value: agency.id), URLQueryItem(name: "scope", value: scope)]
                if let since { query.append(URLQueryItem(name: "since", value: since)) }
                page = try await call("GET", "/api/desktop/v1/sync", query: query)
                tasks += page.tasks
                since = page.cursor ?? since
                rounds += 1
            } while page.more && rounds < 40
            fetched.append((agency, page.boards, tasks, page.taskIdsComplete ? Set(page.taskIds) : nil, since, caughtUp))
        }

        // the projects first: a task needs its board to be there
        var projects: [TaskProject] = []
        let existing = Dictionary(uniqueKeysWithValues: store.projects.map { ($0.id, $0) })
        func made(_ id: UUID, _ name: String, parent: UUID?, _ link: OrgLink) -> TaskProject {
            var project = TaskProject(id: id, name: name, parentID: parent, createdAt: existing[id]?.createdAt ?? .now)
            project.org = link
            return project
        }
        let single = me.agencies.count == 1
        projects.append(made(SOSMap.rootID, "Sensory OS", parent: nil,
                             OrgLink(source: SOSMap.source, agencyID: single ? me.agencies[0].id : "", boardID: nil)))
        for entry in fetched {
            boards[entry.agency.id] = entry.boards
            var parent = SOSMap.rootID
            if !single {
                parent = SOSMap.agencyID(entry.agency.id)
                projects.append(made(parent, entry.agency.name, parent: SOSMap.rootID, OrgLink(source: SOSMap.source, agencyID: entry.agency.id, boardID: nil)))
            }
            for board in entry.boards {
                projects.append(made(SOSMap.boardID(board.id), Self.name(of: board, among: entry.boards), parent: parent,
                                     OrgLink(source: SOSMap.source, agencyID: entry.agency.id, boardID: board.id, webProjectID: board.projectId)))
            }
        }
        store.replaceOrgProjects(projects, source: SOSMap.source)

        // then the tasks
        var dismissed = dismissedTasks
        let local = Dictionary(store.tasks.compactMap { task in task.remote?.taskID.map { ($0, task) } }, uniquingKeysWith: { first, _ in first })
        var changed: [TaskItem] = []
        var remove = Set<UUID>()
        var news: [SOSNotification] = []
        for entry in fetched {
            for wire in entry.tasks {
                if let hidden = dismissed[wire.id] {
                    if wire.updatedAt <= hidden { continue }
                    dismissed[wire.id] = nil // changed on the website since: it shows again
                }
                let board = SOSMap.boardID(wire.boardId)
                let theirs = SOSMap.values(of: wire)
                if var task = local[wire.id] {
                    let mine = SOSMap.values(of: task)
                    let edited = task.remote?.base.map { SOSMap.changes(mine, from: $0) != nil } ?? false
                    // both changed: the later change wins
                    if edited, task.updatedAt > wire.updatedAt { continue }
                    if !edited, task.remote?.serverUpdatedAt == wire.updatedAt, task.projectID == board { continue }
                    SOSMap.apply(theirs, to: &task)
                    task.projectID = board
                    task.updatedAt = wire.updatedAt
                    task.remote = link(wire, agency: entry.agency.id, base: theirs)
                    changed.append(task)
                } else {
                    var task = TaskItem(id: SOSMap.taskID(wire.id), text: "", projectID: board, status: .pending, priority: .medium,
                                        createdAt: wire.createdAt, updatedAt: wire.updatedAt)
                    SOSMap.apply(theirs, to: &task)
                    task.remote = link(wire, agency: entry.agency.id, base: theirs)
                    changed.append(task)
                    if entry.caughtUp, let item = announcement(for: wire, agency: entry.agency.id, boards: entry.boards) { news.append(item) }
                }
            }
            // what left the scope (finished long ago, deleted, handed on, its board archived)
            if let ids = entry.ids {
                for task in store.tasks {
                    guard let remote = task.remote, remote.source == SOSMap.source, remote.agencyID == entry.agency.id,
                          let id = remote.taskID, !ids.contains(id) else { continue }
                    let edited = remote.base.map { SOSMap.changes(SOSMap.values(of: task), from: $0) != nil } ?? false
                    if !edited { remove.insert(task.id) }
                }
            }
        }
        dismissedTasks = dismissed
        store.applyOrgTasks(changed, remove: remove)
        for entry in fetched {
            if let cursor = entry.cursor { defaults.set(cursor, forKey: Keys.cursor(scope, entry.agency.id)) }
        }
        if !changed.isEmpty || !remove.isEmpty { note("took \(changed.count), removed \(remove.count)") }
        if notificationsEnabled {
            for item in news.suffix(5) { deliver(item) }
        }
    }

    /// A task that just appeared on the website and is the person's to do: news for the
    /// island, though the website only notifies someone assigned by somebody else. Nil
    /// when it isn't theirs, is done, is old, or they have already been told about it.
    private func announcement(for wire: SOSTask, agency: String, boards: [SOSBoard]) -> SOSNotification? {
        guard wire.assignedToMe == true, wire.status != "done", wire.createdAt.timeIntervalSinceNow > -3600,
              markAnnounced(wire.id) else { return nil }
        let board = boards.first { $0.id == wire.boardId }.map { Self.name(of: $0, among: boards) }
        return SOSNotification(id: "cue.task.\(wire.id)", agencyId: agency, createdAt: wire.createdAt, type: "task.assigned",
                               title: "New task: \(wire.title)", body: board.map { "Assigned to you · \($0)" } ?? "Assigned to you",
                               entityType: "task", entityId: wire.id, readAt: nil, href: wire.href)
    }

    /// Records that the person has been told about a task (by Cue, or by the website's
    /// own "assigned" notification), so the other one stays quiet. False if they were.
    private func markAnnounced(_ taskID: String) -> Bool {
        var announced = defaults.stringArray(forKey: Keys.announced) ?? []
        guard !announced.contains(taskID) else { return false }
        announced.append(taskID)
        defaults.set(Array(announced.suffix(300)), forKey: Keys.announced)
        return true
    }

    /// A board's name in the sidebar: its project's name (a project has one board), the
    /// board's own name when it is an agency board or one of several.
    private static func name(of board: SOSBoard, among all: [SOSBoard]) -> String {
        guard let project = board.projectName, !project.isEmpty else { return board.name }
        let siblings = all.filter { $0.projectId == board.projectId }.count
        let plain = ["board", "tasks", project.lowercased()].contains(board.name.lowercased())
        return siblings > 1 && !plain ? "\(project) · \(board.name)" : project
    }

    private func link(_ wire: SOSTask, agency: String, base: RemoteValues) -> RemoteLink {
        RemoteLink(source: SOSMap.source, agencyID: agency, taskID: wire.id, boardID: wire.boardId, href: wire.href,
                   serverUpdatedAt: wire.updatedAt, base: base, error: nil, clientRef: nil)
    }

    // MARK: - Sending

    private func push() async throws {
        guard let me else { return }
        for snapshot in store.tasks where store.isOrgTask(snapshot) {
            // re-read: an earlier send in this loop may have changed it
            guard let task = store.tasks.first(where: { $0.id == snapshot.id }) else { continue }
            // refused, and not changed since: asking again would be refused again
            if let refused = task.remote?.refusedAt, task.updatedAt <= refused, store.orgProject(task.projectID) != nil { continue }
            guard let org = store.orgProject(task.projectID)?.org else {
                // moved out of the organization: it is a local task now
                if let id = task.remote?.taskID { dismiss(id) }
                var local = task
                local.remote = nil
                store.applyOrgTasks([local])
                note("detached \(task.title)")
                continue
            }
            if task.remote?.taskID == nil {
                try await create(task, in: org, me: me)
            } else if let remote = task.remote, let boardID = org.boardID, boardID != remote.boardID {
                // moving between boards happens on the website; it goes back to its own
                var back = task
                back.projectID = SOSMap.boardID(remote.boardID)
                store.applyOrgTasks([back])
            } else {
                try await update(task)
            }
        }
    }

    private func create(_ task: TaskItem, in org: OrgLink, me: SOSMe) async throws {
        let agency = me.agencies.first { $0.id == org.agencyID } ?? me.agencies.first { $0.canEdit }
        guard let agency else { return }
        guard agency.canEdit else { return mark(task, error: "You can view this organization's tasks but not add them.") }
        guard let boardID = org.boardID ?? defaultBoard(for: agency.id) else {
            return mark(task, error: "There is no board on the website to put it on.")
        }
        // the create's own id is kept before it is sent, so a retry is the same create
        var pending = task
        let ref = task.remote?.clientRef ?? task.id
        if task.remote == nil {
            pending.remote = RemoteLink(source: SOSMap.source, agencyID: agency.id, taskID: nil, boardID: boardID, clientRef: ref)
            store.applyOrgTasks([pending])
        }
        let values = SOSMap.values(of: task)
        var body: [String: Any] = ["agencyId": agency.id, "boardId": boardID, "title": values.title, "description": values.description,
                                   "priority": task.priority.rawValue, "clientRef": ref.uuidString.lowercased()]
        if task.status != .pending { body["status"] = SOSMap.wire(task.status) }
        do {
            let answer: SOSTaskAnswer = try await call("POST", "/api/desktop/v1/tasks", body: body)
            guard var current = store.tasks.first(where: { $0.id == task.id }) else { return }
            current.remote = link(answer.task, agency: agency.id, base: SOSMap.values(of: answer.task))
            current.projectID = SOSMap.boardID(answer.task.boardId)
            store.applyOrgTasks([current])
            note("created \(answer.task.title) → \(answer.task.id)\(answer.replayed == true ? " (replayed)" : "")")
        } catch let error as SOSHTTPError where error.isRefusal {
            mark(task, error: error.message)
        }
    }

    private func update(_ task: TaskItem) async throws {
        guard let remote = task.remote, let id = remote.taskID, let base = remote.base else { return }
        let mine = SOSMap.values(of: task)
        guard SOSMap.changes(mine, from: base) != nil else { return }
        var body: [String: Any] = ["agencyId": remote.agencyID]
        if mine.title != base.title { body["title"] = mine.title }
        if mine.description.trimmingCharacters(in: .whitespacesAndNewlines) != base.description.trimmingCharacters(in: .whitespacesAndNewlines) {
            body["description"] = mine.description
        }
        if mine.status != base.status { body["status"] = SOSMap.wire(mine.status) }
        let priorityChanged = base.priority == nil ? mine.priority != .medium : mine.priority != base.priority
        if priorityChanged { body["priority"] = mine.priority?.rawValue }
        do {
            let answer: SOSTaskAnswer = try await call("PATCH", "/api/desktop/v1/tasks/\(id)", body: body)
            guard var current = store.tasks.first(where: { $0.id == task.id }) else { return }
            current.remote = link(answer.task, agency: remote.agencyID, base: SOSMap.values(of: answer.task))
            store.applyOrgTasks([current])
            note("updated \(answer.task.title): \(body.keys.filter { $0 != "agencyId" }.sorted().joined(separator: ", "))")
        } catch let error as SOSHTTPError where error.status == 404 {
            // gone from the website, or out of reach: gone from here
            store.applyOrgTasks([], remove: [task.id])
            note("gone \(task.title)")
        } catch let error as SOSHTTPError where error.status == 409 {
            // the website refused the status (blocked by another task): put it back and say why
            guard var current = store.tasks.first(where: { $0.id == task.id }) else { return }
            current.status = base.status
            current.remote?.error = error.message
            store.applyOrgTasks([current])
            note("refused \(task.title): \(error.message)")
        } catch let error as SOSHTTPError where error.isRefusal {
            mark(task, error: error.message)
        }
    }

    /// Keeps why a send failed on the task (shown until one works); it is tried again on
    /// the next round only once the task changes, so a refusal does not repeat every minute.
    private func mark(_ task: TaskItem, error message: String) {
        guard var current = store.tasks.first(where: { $0.id == task.id }) else { return }
        if current.remote == nil { current.remote = RemoteLink(source: SOSMap.source, agencyID: "", boardID: "", clientRef: current.id) }
        current.remote?.error = message
        current.remote?.refusedAt = .now
        store.applyOrgTasks([current])
        note("refused \(task.title): \(message)")
    }

    /// Where a task made in the organization's root goes: the agency's own board (the one
    /// not tied to a project), else the first board.
    private func defaultBoard(for agency: String) -> String? {
        let all = boards[agency] ?? []
        return (all.first { $0.projectId == nil } ?? all.first)?.id
    }

    // MARK: - Hidden tasks

    /// Tasks deleted here (they stay on the website), with when: one changed there since
    /// shows again.
    private var dismissedTasks: [String: Date] {
        get { (defaults.dictionary(forKey: Keys.dismissed) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) } }
        set { defaults.set(newValue.mapValues(\.timeIntervalSince1970), forKey: Keys.dismissed) }
    }

    private func dismiss(_ taskID: String) {
        var all = dismissedTasks
        all[taskID] = .now
        dismissedTasks = all
    }

    private func resetCursors() {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("sensoryos.cursor.") {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Notifications

    func checkNotifications() async {
        guard phase == .connected else { return }
        notificationsChecked = .now
        let since = defaults.string(forKey: Keys.notificationsSince)
        do {
            var query: [URLQueryItem] = []
            if let since { query.append(URLQueryItem(name: "since", value: since)) }
            let answer: SOSNotifications = try await call("GET", "/api/desktop/v1/notifications", query: query)
            var seen = Set(defaults.stringArray(forKey: Keys.notificationsSeen) ?? [])
            let fresh = answer.notifications.filter { !seen.contains($0.id) }.sorted { $0.createdAt < $1.createdAt }
            // the first look only sets the mark: what was already in the bell is not news
            if since != nil, notificationsEnabled {
                for item in fresh.suffix(5) {
                    // the website's "you were assigned" for a task Cue has already announced
                    if item.type == "task.assigned", item.entityType == "task", let task = item.entityId, !markAnnounced(task) { continue }
                    deliver(item)
                }
            }
            seen.formUnion(answer.notifications.map(\.id))
            defaults.set(Array(seen.suffix(300)), forKey: Keys.notificationsSeen)
            let newest = answer.notifications.map(\.createdAt).max()
            let mark = newest.map(SOSDates.string) ?? since ?? answer.serverTime.map(SOSDates.string) ?? SOSDates.string(.now)
            defaults.set(mark, forKey: Keys.notificationsSince)
        } catch {
            if (error as? SOSAuthError) == .signedOut { report(error) }
        }
    }

    private func deliver(_ item: SOSNotification) {
        let url = webURL(item.href)
        notifier.post(item, url: url)
        onNotification(item, url)
        note("notified \(item.title)")
    }

    /// A notification was clicked (in Notification Center or on the island).
    func open(notificationID: String, url: URL?, taskEntity: String?) {
        if let entity = taskEntity, let task = store.tasks.first(where: { $0.remote?.taskID == entity }) {
            openTask(task.id)
        } else if let url {
            NSWorkspace.shared.open(url)
        }
        // Cue's own "new task" has no row on the website to mark
        guard !notificationID.hasPrefix("cue.") else { return }
        Task { _ = try? await call("POST", "/api/desktop/v1/notifications/read", body: ["ids": [notificationID]]) as SOSOK }
    }

    func webURL(_ href: String?) -> URL? {
        guard let href, href.hasPrefix("/"), let origin = tokens?.origin ?? server?.origin else { return nil }
        return URL(string: origin.absoluteString + href)
    }

    // MARK: - HTTP

    private func validToken() async throws -> SOSTokens {
        guard let tokens else { throw SOSAuthError.notConnected }
        if tokens.isFresh { return tokens }
        return try await refreshTokens()
    }

    private func refreshTokens() async throws -> SOSTokens {
        if let refreshing { return try await refreshing.value }
        guard let current = tokens else { throw SOSAuthError.notConnected }
        let task = Task { try await SOSAuth.refresh(current) }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        use(fresh)
        return fresh
    }

    private func call<T: Decodable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil, retried: Bool = false) async throws -> T {
        let tokens = try await validToken()
        var components = URLComponents(url: tokens.origin.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Cue/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, !retried {
            _ = try await refreshTokens()
            return try await call(method, path, query: query, body: body, retried: true)
        }
        if status == 401 { throw SOSAuthError.signedOut }
        guard (200..<300).contains(status) else {
            let message = (try? SOSDates.decoder.decode(SOSError.self, from: data))?.error
                ?? (status == 404 && path == "/api/desktop/v1/me" ? "This Sensory OS server does not have the Cue API yet." : "Sensory OS answered \(status).")
            throw SOSHTTPError(status: status, message: message)
        }
        do {
            return try SOSDates.decoder.decode(T.self, from: data)
        } catch {
            log.error("Sensory OS \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw SOSHTTPError(status: status, message: "Sensory OS answered with something Cue can't read.")
        }
    }

    private func note(_ line: String) {
        journal.append("\(SOSDates.string(.now)) \(line)")
        if journal.count > 200 { journal.removeFirst(journal.count - 200) }
        log.info("Sensory OS: \(line, privacy: .public)")
    }

    // MARK: - Debug

    #if DEBUG
    /// Signed in with tokens from a file instead of the sign-in window, for a test against
    /// a local server (cue://debug/sensoryos?action=token).
    func debugUse(_ tokens: SOSTokens) async {
        use(tokens)
        phase = .connected
        await start()
    }

    func debugReport() -> String {
        var lines = ["phase: \(phase)", "server: \(serverText)", "scope: \(scope)", "live: \(realtime.isLive)",
                     "user: \(me?.user.email ?? "-")", "agencies: \(agencies.map(\.name).joined(separator: ", "))",
                     "lastSync: \(lastSync.map(SOSDates.string) ?? "-")", "lastError: \(lastError ?? "-")", "unsent: \(unsent)", "", "projects:"]
        for project in store.projects where project.isOrg {
            lines.append("  \(project.name) [board \(project.org?.boardID ?? "-")] parent=\(store.project(project.parentID)?.name ?? "-")")
        }
        lines.append("tasks:")
        for task in store.tasks where store.isOrgTask(task) {
            let remote = task.remote
            lines.append("  \(task.title) | \(task.status.rawValue) | \(task.priority.rawValue) | in \(store.project(task.projectID)?.name ?? "-") | web \(remote?.taskID ?? "unsent")\(remote?.error.map { " | error: \($0)" } ?? "")")
        }
        lines.append("")
        lines.append("journal:")
        lines += journal.suffix(60).map { "  \($0)" }
        return lines.joined(separator: "\n")
    }
    #endif
}

private nonisolated struct SOSOK: Decodable {}

nonisolated struct SOSHTTPError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
    /// The website said no to this one change (not "try again later").
    var isRefusal: Bool { (400..<500).contains(status) && status != 401 && status != 429 }
}

/// Dates as Sensory OS writes them: ISO 8601, from Postgres with up to six decimals.
nonisolated enum SOSDates {
    static func date(_ text: String) -> Date? {
        // keep three decimals: the parser takes no more
        let trimmed = text.replacing(#/(\.\d{3})\d+/#) { $0.1 }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    static func string(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = date(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
            }
            return date
        }
        return decoder
    }()
}

/// Sensory OS notifications as macOS notifications; a click opens what they are about.
@MainActor
final class SOSNotifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: (String, URL?, String?) -> Void = { _, _, _ in }
    private var asked = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(_ item: SOSNotification, url: URL?) {
        let content = UNMutableNotificationContent()
        content.title = item.title
        if let body = item.body, !body.isEmpty { content.body = body }
        content.subtitle = "Sensory OS"
        content.sound = .default
        content.threadIdentifier = "sensory-os"
        var info: [String: String] = ["id": item.id]
        if let url { info["url"] = url.absoluteString }
        if item.entityType == "task", let entity = item.entityId { info["task"] = entity }
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sensory-os.\(item.id)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let id = info["id"] as? String ?? ""
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        let task = info["task"] as? String
        await MainActor.run { self.onOpen(id, url, task) }
    }
}
