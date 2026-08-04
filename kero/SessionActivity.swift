//
//  SessionActivity.swift
//  kero
//

import AppKit
import Foundation

/// What a session's foreground agent is doing, as reported by an outside
/// process — a Claude Code hook appending to the session's state file, or
/// `kero +attention` from any other script.
///
/// Everything here is parsed from untrusted input: the state directory is
/// world-writable by this user, and a coding agent's tool name reaches the
/// sidebar as display text. Sanitizing is therefore part of decoding rather
/// than something the views are trusted to remember (`sanitized(_:)`).
nonisolated enum SessionActivity: Equatable, Sendable {
    case none
    /// `since` is when the *unbroken* working run began, not when the last
    /// tool call started, so the badge delay measures continuous work.
    case working(since: Date, text: String?)
    case done(at: Date, text: String?)
    case pending(at: Date, text: String?)

    /// When this state was last reported. Compared against a session's
    /// `lastViewedAt` to decide whether the user has already seen it.
    var timestamp: Date? {
        switch self {
        case .none: nil
        case .working(let since, _): since
        case .done(let at, _): at
        case .pending(let at, _): at
        }
    }

    var text: String? {
        switch self {
        case .none: nil
        case .working(_, let text), .done(_, let text), .pending(_, let text): text
        }
    }
}

/// The ranked states a project row can show, lowest to highest. A project
/// displays the highest-ranked state across every session in every tab —
/// the same bubbling `GitStatusModel.FileDecoration.directoryPriority` does
/// for a directory's changed children.
///
/// The order is the product decision: a project with one agent finished and
/// another blocked on a permission prompt reads as blocked, because that is
/// the one that cannot make progress without the user.
nonisolated enum SessionActivityKind: Int, Comparable, Sendable {
    case none = 0
    /// `kero +attention` from a script. Deliberately the weakest signal: it
    /// carries no claim about what the session is doing, so any state from
    /// the session's own state file outranks it.
    case attention = 1
    case working = 2
    case done = 3
    case pending = 4

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Whether looking at the session retires this state. `working` is live
    /// status rather than news, so it survives being seen — its job is to say
    /// that a project is still busy, which stays true while you watch it.
    var isClearedByViewing: Bool {
        switch self {
        case .none, .working: false
        case .attention, .done, .pending: true
        }
    }
}

/// A resolved state ready to draw: what the icon is, and what the row says.
nonisolated struct SessionActivityDisplay: Equatable, Sendable {
    var kind: SessionActivityKind = .none
    var text: String?
    /// Start of the current working run, for the elapsed suffix. Only set
    /// for `.working`, which is the one state that keeps ticking.
    var workingSince: Date?

    static let none = SessionActivityDisplay()

    var isNone: Bool { kind == .none }
}

extension SessionActivity {
    /// How long a session must work continuously before the row shows the
    /// gear. Short tool calls finish well inside this, so ordinary turns
    /// never flicker a badge onto the strip.
    static let workingBadgeDelay: TimeInterval = 30

    /// Collapses this state, an optional `kero +attention` ping, and what the
    /// user has already looked at into the one thing the row draws.
    ///
    /// `pending`, `done`, and `attention` are unseen *notifications*: once the
    /// user has focused the session they stop being news, and a state whose
    /// news has been read falls all the way back to `.none` rather than
    /// degrading to a lesser badge — a permission prompt you have already seen
    /// is not "working", it is still blocked, and the terminal itself is
    /// showing it.
    ///
    /// `working` is live *status*, not news. It is not cleared by viewing,
    /// because its job is to tell you that some other project is still busy.
    func display(
        lastViewedAt: Date,
        attentionAt: Date? = nil,
        attentionText: String? = nil,
        now: Date = Date()
    ) -> SessionActivityDisplay {
        switch self {
        case .pending(let at, let text) where at > lastViewedAt:
            return SessionActivityDisplay(kind: .pending, text: text)
        case .done(let at, let text) where at > lastViewedAt:
            return SessionActivityDisplay(kind: .done, text: text)
        case .working(let since, let text)
            where now.timeIntervalSince(since) >= Self.workingBadgeDelay:
            return SessionActivityDisplay(
                kind: .working, text: text, workingSince: since
            )
        default:
            break
        }

        // Attention only surfaces in the default state: the user asked for it
        // to be the weakest tier, so a session that has anything to say for
        // itself says that instead.
        if let attentionAt, attentionAt > lastViewedAt {
            return SessionActivityDisplay(kind: .attention, text: attentionText)
        }
        return .none
    }
}

// MARK: - Presentation

extension SessionActivityKind {
    /// The row's folder glyph. Every state differs in *shape* — badge or
    /// fill — so the strip never depends on color alone to say what is
    /// happening (PRODUCT.md).
    var symbolName: String {
        switch self {
        case .none: "folder"
        case .attention: "folder.fill"
        case .working: "folder.badge.gearshape"
        case .done: "folder.fill"
        case .pending: "folder.badge.questionmark"
        }
    }

    /// Nil means "keep the row's ordinary selected/unselected tint" — the
    /// default and attention states are not status colors, they are the
    /// sidebar's existing appearance.
    var tint: NSColor? {
        switch self {
        case .none, .attention: nil
        case .working: .systemCyan
        case .done: .systemGreen
        case .pending: .systemOrange
        }
    }

    /// Spoken state for assistive technology, so the badge is never the only
    /// way to learn what a project is doing.
    var accessibilityDescription: String? {
        switch self {
        case .none:
            nil
        case .attention:
            String(
                localized: "Needs attention",
                comment: "Accessibility label for a project whose script asked for attention."
            )
        case .working:
            String(
                localized: "Working",
                comment: "Accessibility label for a project whose agent is running."
            )
        case .done:
            String(
                localized: "Finished",
                comment: "Accessibility label for a project whose agent finished and has not been looked at."
            )
        case .pending:
            String(
                localized: "Waiting for you",
                comment: "Accessibility label for a project whose agent is blocked on the user."
            )
        }
    }
}

extension SessionActivityDisplay {
    /// The row subtitle. The state text comes from outside Kero, so it is
    /// shown only after `SessionActivity.sanitized(_:)` has bounded it; when
    /// a reporter sends nothing usable, fall back to naming the state
    /// ourselves rather than leaving the row blank.
    func subtitle(now: Date = Date()) -> String? {
        guard kind != .none else { return nil }
        let base = text ?? kind.accessibilityDescription
        guard let base else { return nil }
        guard let workingSince, kind == .working else { return base }

        let minutes = Int(now.timeIntervalSince(workingSince) / 60)
        guard minutes >= 1 else { return base }
        return String(
            localized: "\(base) · \(minutes)m",
            comment: """
                Project row subtitle: a state description followed by how many \
                whole minutes it has been running. Example: “Running Bash · 4m”.
                """
        )
    }
}

// MARK: - Untrusted text

extension SessionActivity {
    /// Longest state text the sidebar will show. The reporter is asked to
    /// send something already short; this is what stops it mattering when one
    /// does not.
    static let maximumTextLength = 64

    /// Makes an outside process's string safe to draw in a sidebar row:
    /// control characters and escape sequences removed, runs of whitespace
    /// collapsed to single spaces, and the result bounded. Returns nil when
    /// nothing usable survives, so callers fall back to a Kero-authored label.
    static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let scrubbed = raw.unicodeScalars
            .filter {
                !CharacterSet.controlCharacters.contains($0)
                    && !CharacterSet.illegalCharacters.contains($0)
            }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
        let collapsed = scrubbed
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maximumTextLength else { return collapsed }
        return collapsed.prefix(maximumTextLength - 1) + "…"
    }
}

// MARK: - Wire format

/// One appended line of a session's state file. Fields are optional and
/// unknown events are ignored, so a newer hook script cannot break an older
/// Kero — a mismatch degrades to "no signal", never to a broken strip.
nonisolated struct SessionStateEvent: Sendable {
    enum Kind: String, Sendable {
        case working
        case pending
        case done
        /// Session is over, or the reporter is retracting its state.
        case clear
    }

    var kind: Kind
    var timestamp: Date
    var text: String?

    private struct Line: Decodable {
        var event: String
        var ts: Double?
        var text: String?
    }

    /// Decodes one JSONL line. Returns nil for anything unrecognized rather
    /// than throwing: a single malformed append must not cost the session its
    /// whole state.
    static func decode(line: Data, now: Date = Date()) -> SessionStateEvent? {
        guard let decoded = try? JSONDecoder().decode(Line.self, from: line),
              let kind = Kind(rawValue: decoded.event)
        else { return nil }

        // A reporter with a broken clock must not park a state permanently in
        // the future, where it would outlive every `lastViewedAt` and never
        // clear. Anything ahead of now is pinned to now.
        let stamped = decoded.ts.map { Date(timeIntervalSince1970: $0) } ?? now
        return SessionStateEvent(
            kind: kind,
            timestamp: min(stamped, now),
            text: SessionActivity.sanitized(decoded.text)
        )
    }
}

extension SessionActivity {
    /// Folds a session's appended events into its current state. Later events
    /// replace earlier ones, except that a run of `working` keeps the first
    /// one's timestamp so the badge delay measures the whole run.
    static func folded(_ events: [SessionStateEvent]) -> SessionActivity {
        var state = SessionActivity.none
        for event in events {
            switch event.kind {
            case .clear:
                state = .none
            case .pending:
                state = .pending(at: event.timestamp, text: event.text)
            case .done:
                state = .done(at: event.timestamp, text: event.text)
            case .working:
                if case .working(let since, _) = state {
                    state = .working(since: since, text: event.text)
                } else {
                    state = .working(since: event.timestamp, text: event.text)
                }
            }
        }
        return state
    }
}
