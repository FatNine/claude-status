import Foundation

/// Represents the current state of a Claude Code session.
enum SessionState: Comparable, Codable {
    case active
    case waiting
    case idle
    case compacting

    /// String key used in ProductivityStats.timeInState dictionaries.
    var key: String {
        switch self {
        case .active: "active"
        case .waiting: "waiting"
        case .idle: "idle"
        case .compacting: "compacting"
        }
    }

    var sfSymbol: String {
        switch self {
        case .active: "circle.fill"
        case .waiting: "circle.fill"
        case .idle: "circle"
        case .compacting: "arrow.triangle.2.circlepath"
        }
    }

    var colorName: String {
        switch self {
        case .active: "green"
        case .waiting: "yellow"
        case .idle: "gray"
        case .compacting: "blue"
        }
    }

    var emoji: String {
        switch self {
        case .active: "\u{26A1}"
        case .waiting: "\u{23F3}"
        case .idle: "\u{1F4A4}"
        case .compacting: "\u{1F9F9}"
        }
    }

    var label: String {
        switch self {
        case .active: "Active"
        case .waiting: "Waiting"
        case .idle: "Idle"
        case .compacting: "Compacting"
        }
    }

    /// Priority for aggregate status (higher = more urgent).
    var priority: Int {
        switch self {
        case .waiting: 3
        case .active: 2
        case .compacting: 1
        case .idle: 0
        }
    }

    /// Sort order for display (lower = appears first).
    /// Waiting (needs input) > Active (working) > Compacting > Idle.
    var sortOrder: Int {
        switch self {
        case .waiting: 0
        case .active: 1
        case .compacting: 2
        case .idle: 3
        }
    }
}

/// What the user should do, derived from the raw `SessionState` plus timing and
/// whether the user has already acknowledged the session.
///
/// This is the "attention router" layer: the menu-bar / row color is driven by
/// this, not by the raw state directly. The raw daemon state is reinterpreted
/// app-side, so no plugin (Rust) change is needed.
enum AttentionLevel: Equatable {
    /// Default minutes a finished turn stays "your turn" before fading to idle.
    /// Shared by the app and the widget so they agree.
    static let defaultGraceMinutes: Double = 60

    /// Claude is busy on its own (active or compacting) — you're free to step away.
    case working
    /// A turn just finished and it's your move (review / continue). Soft.
    case needsYou
    /// Claude is blocked awaiting you (permission / question / elicitation). Hard.
    case hardBlock
    /// Truly idle: acknowledged, or no recent activity. Nothing to do.
    case dormant

    /// Aggregate priority for the menu-bar dot (higher = surfaced first).
    /// hardBlock > needsYou > working > dormant — so a session that needs you
    /// is never hidden behind one that is merely working.
    var priority: Int {
        switch self {
        case .hardBlock: 3
        case .needsYou: 2
        case .working: 1
        case .dormant: 0
        }
    }

    /// Emoji used in the menu bar's "emoji" icon style.
    var emoji: String {
        switch self {
        case .working: "\u{26A1}"   // ⚡
        case .needsYou: "\u{1F440}" // 👀
        case .hardBlock: "\u{23F3}" // ⏳
        case .dormant: "\u{1F4A4}"  // 💤
        }
    }

    /// Short label shown in the popover row.
    var label: String {
        switch self {
        case .working: "Working"
        case .needsYou: "Your turn"
        case .hardBlock: "Needs input"
        case .dormant: "Idle"
        }
    }
}

/// Where a Claude session is running.
enum SessionSource: Codable, Equatable {
    case terminal(app: String)  // e.g. "iTerm2", "Terminal", "Ghostty"
    case xcode
    case vscode
    case jetbrains(ide: String)  // e.g. "PyCharm", "IntelliJ IDEA"
    case zed
    case claudeDesktop  // Claude Desktop's built-in code mode (embedded claude-code)

    var label: String {
        switch self {
        case .terminal(let app): app
        case .xcode: "Xcode"
        case .vscode: "VS Code"
        case .jetbrains(let ide): ide
        case .zed: "Zed"
        case .claudeDesktop: "Claude"
        }
    }

    /// Whether this is a terminal session (not an IDE-embedded agent).
    var isTerminal: Bool {
        if case .terminal = self { return true }
        return false
    }

    /// Whether this is any JetBrains IDE.
    var isJetBrains: Bool {
        if case .jetbrains = self { return true }
        return false
    }
}

/// A discovered Claude Code session on the local machine.
struct ClaudeSession: Identifiable, Codable, Equatable {
    /// The session UUID from Claude Code (stable across refreshes).
    let sessionId: String
    let pid: pid_t
    let workingDirectory: String
    let projectName: String
    let state: SessionState
    let lastActivityAt: Date
    let iTermSessionId: String?
    /// tmux pane ID (e.g. "%5") when session runs inside tmux.
    let tmuxPaneId: String?
    /// tmux socket path for targeting the correct server.
    let tmuxSocket: String?
    let source: SessionSource
    /// Current activity description (e.g. tool name, "thinking", "subagent").
    /// Empty string when no specific activity is known.
    let activity: String
    /// Optional custom session name set by the user via /name-session.
    let sessionName: String?
    /// Title shown in Claude Desktop's session list (matched by cliSessionId).
    /// nil for terminal/CLI sessions or before a title is generated.
    /// `var` with a default so existing initializer call sites keep compiling.
    var desktopTitle: String? = nil

    /// Use sessionId as the SwiftUI identity (stable, unlike PIDs).
    var id: String { sessionId }

    /// Relative time since last activity, human-readable.
    var timeSinceActivity: String {
        let interval = Date().timeIntervalSince(lastActivityAt)
        if interval < 60 {
            return "just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins)m ago"
        } else {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        }
    }

    /// Deep link URL for focusing this session from the widget.
    var deepLinkURL: URL {
        var components = URLComponents()
        components.scheme = "claude-status"
        components.host = "session"
        components.path = "/\(id)"
        return components.url ?? URL(string: "claude-status://session/unknown")!
    }
}

extension ClaudeSession {
    /// Tool activities that block on user input — the daemon marks these
    /// `active`, but they actually mean "your turn".
    static let inputBlockingActivities: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Derives the attention level from the raw state, how long since the last
    /// activity, and whether the user has acknowledged this session.
    ///
    /// - `active` / `compacting` → `.working` (compacting folds into working).
    /// - `waiting` → `.hardBlock` (permission / question / elicitation).
    /// - `idle` → `.needsYou` if it just finished and you haven't acknowledged it;
    ///   `.dormant` once acknowledged or after `graceMinutes` with no new activity.
    ///
    /// - Parameters:
    ///   - acknowledgedAt: the `lastActivityAt` value captured when the user last
    ///     marked this session read. The session is dormant while this is at or
    ///     after the current `lastActivityAt` (i.e. nothing new since you looked).
    ///   - graceMinutes: how long a finished turn stays `.needsYou` before fading
    ///     to `.dormant` (assume you've stepped away or already handled it).
    func attentionLevel(now: Date = Date(), acknowledgedAt: Date?, graceMinutes: Double) -> AttentionLevel {
        switch state {
        case .active, .compacting:
            // Some "tools" actually block waiting for the user (AskUserQuestion,
            // plan approval). The daemon reports them as active since it just
            // sees a tool_use, but they need you — surface as a hard block.
            if Self.inputBlockingActivities.contains(activity) { return .hardBlock }
            return .working
        case .waiting:
            return .hardBlock
        case .idle:
            if let ack = acknowledgedAt, ack >= lastActivityAt {
                return .dormant
            }
            if now.timeIntervalSince(lastActivityAt) <= graceMinutes * 60 {
                return .needsYou
            }
            return .dormant
        }
    }
}

extension Array where Element == ClaudeSession {
    /// Sessions sorted by state (Waiting, Active, Compacting, Idle), then most recent first.
    var sortedByStateAndActivity: [ClaudeSession] {
        sorted {
            if $0.state.sortOrder != $1.state.sortOrder {
                return $0.state.sortOrder < $1.state.sortOrder
            }
            return $0.lastActivityAt > $1.lastActivityAt
        }
    }
}
