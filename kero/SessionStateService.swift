//
//  SessionStateService.swift
//  kero
//

import AppKit
import Combine
import Foundation

/// Owns the directory where outside processes report what a session's agent
/// is doing, and folds those reports back into the sessions themselves.
///
/// The channel is a file per session rather than a notification because state
/// must be *level-triggered*: a hook that fires while Kero is launching, or a
/// notification that is dropped, would otherwise leave a project permanently
/// mislabeled. Re-reading the file always recovers the truth.
///
/// Session identity travels in the environment (`KERO_SESSION_ID`), so a hook
/// several processes below the pane's shell is attributed without walking the
/// process tree. This mirrors `KeroCLIService`, which already scopes the
/// bundled CLI to its owning app the same way — and carries the same caveat:
/// any process running as this user can write to these files, so everything
/// read here is treated as hostile input.
@MainActor
final class SessionStateService: ObservableObject {
    static let shared = SessionStateService()

    /// Bumped whenever anything a project row draws might have changed —
    /// including the plain passage of time while an agent works, which no
    /// session property reflects. The sidebar observes this the way other
    /// views observe `Theme.changes`.
    @Published private(set) var revision: Int = 0

    /// Re-reading a whole file on every append is fine because compaction
    /// keeps files small; this bound is what happens when a hostile writer
    /// ignores that. Only the tail matters — current state is the last line.
    private static let maximumReadBytes = 256 * 1024
    /// Above either bound the file is rewritten as a single folded line.
    private static let compactionByteThreshold = 64 * 1024
    private static let compactionLineThreshold = 512
    /// A single line longer than this is a writer doing something Kero has no
    /// use for, and is skipped rather than decoded.
    private static let maximumLineBytes = 8 * 1024

    /// How often the working state is re-evaluated. The gear appears on a
    /// delay and the subtitle counts whole minutes, so neither needs better
    /// resolution than this, and the timer only runs while work is in flight.
    private static let tickInterval: TimeInterval = 5

    private let directoryURL: URL
    private var stream: FSEventStreamRef?
    private var tickTimer: Timer?
    private var terminationObserver: NSObjectProtocol?

    /// Sessions are held weakly: this registry must never be what keeps a
    /// closed terminal alive.
    private var sessions: [UUID: WeakSession] = [:]

    private struct WeakSession {
        weak var session: TerminalSession?
    }

    private init() {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "kero-state-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            NSLog("kero: failed to prepare session state directory: \(error)")
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tearDown()
            }
        }
    }

    func configure() {
        startWatching()
    }

    /// Added to every Kero shell alongside `KeroCLIService`'s variables. A
    /// reporter needs both: the id says which session it is in, the directory
    /// says where to append.
    var terminalEnvironment: [String: String] {
        ["KERO_STATE_DIR": directoryURL.path]
    }

    func stateFileURL(for sessionID: UUID) -> URL {
        directoryURL.appendingPathComponent("\(sessionID.uuidString).jsonl")
    }

    // MARK: - Session registry

    func register(_ session: TerminalSession) {
        sessions[session.id] = WeakSession(session: session)
    }

    /// Called when a session tears down. The file is removed rather than left
    /// for the terminate handler so a long-lived window does not accumulate
    /// one per closed tab.
    func unregister(sessionID: UUID) {
        sessions[sessionID] = nil
        try? FileManager.default.removeItem(at: stateFileURL(for: sessionID))
        updateTickTimer()
    }

    /// A `kero +attention` ping. Attention is deliberately not written to the
    /// state file: it is a momentary nudge from a script that knows nothing
    /// about the agent, and it must never outrank a real reported state.
    func recordAttention(sessionID: UUID, text: String?) {
        guard let session = sessions[sessionID]?.session else { return }
        session.attentionAt = Date()
        session.attentionText = SessionActivity.sanitized(text)
        bumpRevision()
    }

    // MARK: - Watching

    private func startWatching() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // A C callback cannot capture, so the service arrives through `info`.
        // It is unretained: the stream is owned by, and torn down with, the
        // service itself.
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info, count > 0 else { return }
            let service = Unmanaged<SessionStateService>
                .fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated {
                service.handleChanges(paths: changed)
            }
        }

        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [directoryURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.1,
            UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
            )
        ) else {
            NSLog("kero: could not watch the session state directory")
            return
        }

        // Delivering on the main queue is what makes `assumeIsolated` in the
        // callback correct.
        FSEventStreamSetDispatchQueue(created, DispatchQueue.main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            NSLog("kero: could not start the session state watcher")
            return
        }
        stream = created
    }

    private func handleChanges(paths: [String]) {
        var touched = Set<UUID>()
        for path in paths {
            let name = (path as NSString).lastPathComponent
            guard name.hasSuffix(".jsonl") else { continue }
            let base = String(name.dropLast(".jsonl".count))
            guard let id = UUID(uuidString: base) else { continue }
            touched.insert(id)
        }
        guard !touched.isEmpty else { return }

        var changed = false
        for id in touched {
            // FSEvents also reports files for sessions this process has since
            // closed; those have no session to update and no state to keep.
            guard let session = sessions[id]?.session else { continue }
            let state = reload(sessionID: id)
            if session.activity != state {
                session.activity = state
                changed = true
            }
        }
        if changed {
            bumpRevision()
        }
        updateTickTimer()
    }

    /// Reads, folds, and — when it has grown — compacts one session's file.
    private func reload(sessionID: UUID) -> SessionActivity {
        let url = stateFileURL(for: sessionID)
        guard let (data, wasTruncated) = readTail(of: url) else { return .none }

        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        // A partial first line is the expected cost of reading only the tail.
        if wasTruncated, !lines.isEmpty {
            lines.removeFirst()
        }

        let events = lines.compactMap { line -> SessionStateEvent? in
            guard line.count <= Self.maximumLineBytes else { return nil }
            return SessionStateEvent.decode(line: Data(line))
        }
        let state = SessionActivity.folded(events)

        if wasTruncated
            || data.count > Self.compactionByteThreshold
            || lines.count > Self.compactionLineThreshold {
            compact(url: url, state: state)
        }
        return state
    }

    /// Returns the file's trailing bytes, and whether anything was skipped.
    private func readTail(of url: URL) -> (Data, Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd() else { return nil }
        let limit = UInt64(Self.maximumReadBytes)
        let truncated = end > limit
        if truncated {
            try? handle.seek(toOffset: end - limit)
        } else {
            try? handle.seek(toOffset: 0)
        }
        guard let data = try? handle.readToEnd() else { return (Data(), truncated) }
        return (data, truncated)
    }

    /// Replaces a grown file with the single line that means the same thing.
    ///
    /// This is not atomic with respect to *writers*: an append landing between
    /// the read and the replace is lost. That is acceptable and self-healing —
    /// the next hook event restores the correct state — and it is why the
    /// reporters append rather than read-modify-write.
    private func compact(url: URL, state: SessionActivity) {
        guard let line = encode(state) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try line.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            NSLog("kero: failed to compact session state: \(error)")
        }
    }

    private func encode(_ state: SessionActivity) -> Data? {
        let event: String
        switch state {
        case .none: return nil
        case .working: event = "working"
        case .done: event = "done"
        case .pending: event = "pending"
        }
        guard let timestamp = state.timestamp else { return nil }

        var object: [String: Any] = [
            "event": event,
            "ts": timestamp.timeIntervalSince1970,
        ]
        if let text = state.text {
            object["text"] = text
        }
        guard var data = try? JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys]
        ) else { return nil }
        data.append(UInt8(ascii: "\n"))
        return data
    }

    // MARK: - Elapsed time

    /// The gear appears on a delay and the subtitle counts minutes, so a row
    /// can go stale with no file change to prompt it. The timer exists only
    /// while some session is working, so an idle Kero does not wake for this.
    private func updateTickTimer() {
        let isWorking = sessions.values.contains { weak in
            if case .working = weak.session?.activity { return true }
            return false
        }
        if isWorking, tickTimer == nil {
            tickTimer = Timer.scheduledTimer(
                withTimeInterval: Self.tickInterval, repeats: true
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.bumpRevision()
                }
            }
        } else if !isWorking {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    /// Redraw the strip for a reason no session property carries — a state
    /// being retired by the user looking at it, or time passing.
    func invalidate() {
        bumpRevision()
    }

    private func bumpRevision() {
        revision &+= 1
    }

    // MARK: - Teardown

    private func tearDown() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        tickTimer?.invalidate()
        tickTimer = nil
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
