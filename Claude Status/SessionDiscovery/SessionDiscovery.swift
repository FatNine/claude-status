import Darwin
import Foundation

/// Parsed contents of a `<session_id>.cstatus` file written by the hook script.
struct CStatusRecord {
    let sessionId: String
    let pid: pid_t
    let ppid: pid_t
    let state: SessionState
    let activity: String
    let timestamp: Date
    let cwd: String
    let event: String
    let sessionName: String?
    let fileURL: URL
    /// The encoded project directory name (parent of the .cstatus file).
    let projectDir: URL
}

/// Discovers Claude Code sessions by scanning `~/.claude/projects/` for `.cstatus` files
/// and validating that the referenced processes are still alive.
struct SessionDiscovery {

    /// Sessions confirmed dead — skip on subsequent scans until invalidated.
    /// Keyed by session ID (UUID string from the .cstatus filename).
    var deadSessions: Set<String> = []

    /// Claude Desktop session titles, keyed by `cliSessionId` (== our session ID).
    /// Refreshed (throttled) each discovery pass so rows can show the same title
    /// the user sees in Claude Desktop's session list.
    private var desktopTitles: [String: String] = [:]
    /// Same titles keyed by `cwd` — fallback for when a session was resumed and
    /// got a new cli UUID that no longer matches the stored cliSessionId, but the
    /// working directory is stable. Most-recently-active record wins per cwd.
    private var desktopTitlesByCwd: [String: String] = [:]
    private var lastTitleScan: Date = .distantPast

    private static let claudeProjectsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }()

    /// Where Claude Desktop stores per-session metadata (title, cliSessionId, …).
    private static let claudeDesktopSessionsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }()

    // MARK: - Discovery

    /// Result of a discovery pass: sessions plus their .cstatus file locations.
    struct DiscoveryResult {
        let sessions: [ClaudeSession]
        let cstatusFiles: [String: URL]  // sessionId → .cstatus URL
    }

    /// Full scan: find all .cstatus files, validate PIDs, classify sources.
    /// Returns assembled sessions and updates `deadSessions` for any that are gone.
    mutating func discoverAll() -> DiscoveryResult {
        refreshDesktopTitlesIfStale()
        let records = scanCStatusFiles()
        var alive: [CStatusRecord] = []
        var cstatusFiles: [String: URL] = [:]

        for record in records {
            if deadSessions.contains(record.sessionId) {
                continue
            }
            guard isProcessAlive(record.pid) else {
                deadSessions.insert(record.sessionId)
                continue
            }
            cstatusFiles[record.sessionId] = record.fileURL
            alive.append(record)
        }
        return DiscoveryResult(sessions: collapseAndAssemble(alive), cstatusFiles: cstatusFiles)
    }

    /// Fast refresh: re-read only .cstatus files (no directory enumeration needed
    /// if we already have cached paths). Falls back to full scan.
    mutating func refreshFromCache(_ cache: [String: URL]) -> DiscoveryResult {
        refreshDesktopTitlesIfStale()
        var alive: [CStatusRecord] = []
        var cstatusFiles: [String: URL] = [:]

        for (sessionId, url) in cache {
            if deadSessions.contains(sessionId) {
                continue
            }
            guard let record = parseCStatusFile(at: url) else {
                deadSessions.insert(sessionId)
                continue
            }
            guard isProcessAlive(record.pid) else {
                deadSessions.insert(record.sessionId)
                continue
            }
            cstatusFiles[record.sessionId] = record.fileURL
            alive.append(record)
        }
        return DiscoveryResult(sessions: collapseAndAssemble(alive), cstatusFiles: cstatusFiles)
    }

    /// Clears the dead session list (e.g. after a Darwin notification
    /// signals that a session may have come alive).
    mutating func clearDeadSessions() {
        deadSessions.removeAll()
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    // MARK: - File Scanning

    /// Enumerates all `.cstatus` files under `~/.claude/projects/*/`.
    private func scanCStatusFiles() -> [CStatusRecord] {
        let fm = FileManager.default
        let projectsDir = Self.claudeProjectsDir

        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }

        var records: [CStatusRecord] = []
        for dir in projectDirs {
            guard let isDir = try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory,
                  isDir else {
                continue
            }
            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ) else {
                continue
            }
            for file in files where file.pathExtension == "cstatus" {
                if let record = parseCStatusFile(at: file) {
                    records.append(record)
                }
            }
        }
        return records
    }

    /// Parses a single `.cstatus` JSON file.
    private func parseCStatusFile(at url: URL) -> CStatusRecord? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = json["session_id"] as? String,
              let pidValue = json["pid"] as? Int,
              let stateString = json["state"] as? String,
              let timestampString = json["timestamp"] as? String else {
            return nil
        }

        let ppidValue = json["ppid"] as? Int ?? 0

        let state: SessionState
        switch stateString {
        case "active": state = .active
        case "waiting": state = .waiting
        case "compacting": state = .compacting
        default: state = .idle
        }

        let activity = json["activity"] as? String ?? ""

        let timestamp = Self.iso8601Formatter.date(from: timestampString) ?? Date()

        let cwd = json["cwd"] as? String ?? ""
        let event = json["event"] as? String ?? ""
        let sessionName = json["session_name"] as? String

        return CStatusRecord(
            sessionId: sessionId,
            pid: pid_t(pidValue),
            ppid: pid_t(ppidValue),
            state: state,
            activity: activity,
            timestamp: timestamp,
            cwd: cwd,
            event: event,
            sessionName: sessionName,
            fileURL: url,
            projectDir: url.deletingLastPathComponent()
        )
    }

    // MARK: - Claude Desktop Titles

    /// Rescans Claude Desktop's session metadata (throttled to once every few
    /// seconds) to build a `cliSessionId → title` map. Cheap: ~dozens of small
    /// JSON files. Failures are non-fatal — titles are best-effort.
    private mutating func refreshDesktopTitlesIfStale() {
        guard Date().timeIntervalSince(lastTitleScan) > 4 else { return }
        lastTitleScan = Date()

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Self.claudeDesktopSessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        var byCli: [String: String] = [:]
        var byCwd: [String: String] = [:]
        var cwdRecency: [String: Double] = [:]
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("local_"), url.pathExtension == "json" else { continue }
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = obj["title"] as? String,
                  !title.isEmpty else { continue }
            if let cli = obj["cliSessionId"] as? String, !cli.isEmpty {
                byCli[cli] = title
            }
            if let cwd = (obj["cwd"] as? String) ?? (obj["worktreePath"] as? String), !cwd.isEmpty {
                let ts = (obj["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0
                if ts >= (cwdRecency[cwd] ?? -1) {
                    byCwd[cwd] = title
                    cwdRecency[cwd] = ts
                }
            }
        }
        desktopTitles = byCli
        desktopTitlesByCwd = byCwd
    }

    // MARK: - Session Assembly

    /// Derives a readable project name from a working directory.
    ///
    /// Normally this is just the last path component. But sessions run inside a
    /// git worktree have a cwd like `…/<repo>/.claude/worktrees/<codename>`, whose
    /// last component is a meaningless auto-generated codename (e.g.
    /// `hardcore-maxwell-facf05`). In that case use the repo name as the primary
    /// label and append the worktree codename for disambiguation, e.g.
    /// `claude-status · hardcore-maxwell-facf05`.
    static func deriveProjectName(from cwd: String) -> String {
        let marker = "/.claude/worktrees/"
        if let range = cwd.range(of: marker) {
            let repo = (String(cwd[..<range.lowerBound]) as NSString).lastPathComponent
            let codename = cwd[range.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            if !repo.isEmpty {
                return codename.isEmpty ? repo : "\(repo) \u{00B7} \(codename)"
            }
        }
        return (cwd as NSString).lastPathComponent
    }

    /// Builds a `ClaudeSession` from a validated `CStatusRecord`.
    private func assembleSession(from record: CStatusRecord) -> ClaudeSession {
        let source = classifySource(pid: record.pid, ppid: record.ppid)
        let projectName = Self.deriveProjectName(from: record.cwd)

        let iTermSessionId: String?
        let tmuxPaneId: String?
        let tmuxSocket: String?
        if source.isTerminal {
            iTermSessionId = readEnvironmentVariable(for: record.pid, name: "ITERM_SESSION_ID")
            tmuxPaneId = readEnvironmentVariable(for: record.pid, name: "TMUX_PANE")
            if let tmuxEnv = readEnvironmentVariable(for: record.pid, name: "TMUX") {
                // TMUX env var format: /socket/path,pid,session
                // Use suffix-based parsing to handle commas in socket paths
                let parts = tmuxEnv.components(separatedBy: ",")
                if parts.count >= 3 {
                    // Last two components are pid and session number;
                    // everything before is the socket path (may contain commas).
                    let suffixLen = parts[parts.count - 1].count + parts[parts.count - 2].count + 2
                    tmuxSocket = String(tmuxEnv.dropLast(suffixLen))
                } else {
                    tmuxSocket = parts.first
                }
            } else {
                tmuxSocket = nil
            }
        } else {
            iTermSessionId = nil
            tmuxPaneId = nil
            tmuxSocket = nil
        }
        let tty: String? = source.isTerminal ? controllingTTY(for: record.pid) : nil

        return ClaudeSession(
            sessionId: record.sessionId,
            pid: record.pid,
            workingDirectory: record.cwd,
            projectName: projectName,
            state: record.state,
            lastActivityAt: record.timestamp,
            iTermSessionId: iTermSessionId,
            tty: tty,
            tmuxPaneId: tmuxPaneId,
            tmuxSocket: tmuxSocket,
            source: source,
            activity: record.activity,
            sessionName: record.sessionName,
            desktopTitle: desktopTitles[record.sessionId] ?? desktopTitlesByCwd[record.cwd]
        )
    }

    // MARK: - Process Validation

    /// Assembles sessions, dropping Claude Code's internal `--bg-spare` pool
    /// workers entirely. They are pre-forked plumbing, never the user's session;
    /// the real interactive session is tracked separately (the UserPromptSubmit
    /// hook), so unlike before we no longer need to keep a spare as a stand-in.
    private func collapseAndAssemble(_ records: [CStatusRecord]) -> [ClaudeSession] {
        records.compactMap { record in
            if isBackgroundSpare(pid: record.pid) { return nil }
            return assembleSession(from: record)
        }
    }

    /// True if the process is a Claude Code background spare-pool worker.
    private func isBackgroundSpare(pid: pid_t) -> Bool {
        processArguments(for: pid).contains("--bg-spare")
    }

    /// Reads a process's argv (not env) from sysctl KERN_PROCARGS2.
    private func processArguments(for pid: pid_t) -> [String] {
        var argmax: Int32 = 0
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return [] }

        var procargs = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = Int(argmax)
        guard sysctl(&mib, 3, &procargs, &size, nil, 0) == 0, size > 0 else { return [] }

        var offset = MemoryLayout<Int32>.size
        // Skip the executable path and trailing padding nulls.
        while offset < size && procargs[offset] != 0 { offset += 1 }
        while offset < size && procargs[offset] == 0 { offset += 1 }

        // Collect exactly argc argument strings (stop before the environment).
        let argc = procargs.withUnsafeBytes { $0.load(as: Int32.self) }
        var args: [String] = []
        for _ in 0..<argc {
            let start = offset
            while offset < size && procargs[offset] != 0 { offset += 1 }
            if start < offset, let s = String(bytes: procargs[start..<offset], encoding: .utf8) {
                args.append(s)
            }
            offset += 1
        }
        return args
    }

    /// Checks if a process is still alive and is a Claude-related process.
    /// Uses kill(pid, 0) for liveness, then verifies the executable path
    /// to guard against PID recycling by unrelated processes.
    private func isProcessAlive(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        // Verify the process is actually Claude (guards against PID recycling)
        guard let path = executablePath(for: pid) else { return true }
        return path.contains("claude") || path.contains("Claude") || path.hasSuffix("/node")
    }

    // MARK: - Source Classification

    /// Determines where a Claude session is running by examining the process tree.
    /// Starts from ppid (the process that launched Claude) and walks up.
    private func classifySource(pid: pid_t, ppid: pid_t) -> SessionSource {
        // Check the Claude process's own executable path for IDE-bundled binaries
        if let path = executablePath(for: pid) {
            // Claude Desktop runs an embedded claude-code runtime under
            // ~/Library/Application Support/Claude/claude-code/<ver>/claude.app
            if path.contains("/Application Support/Claude/claude-code/") {
                return .claudeDesktop
            }
            if path.contains("/Developer/Xcode/CodingAssistant/") {
                return .xcode
            }
            if path.contains(".vscode/extensions/anthropic.claude-code") {
                return .vscode
            }
        }

        // Check environment variables on the Claude process
        if let termEmulator = readEnvironmentVariable(for: pid, name: "TERMINAL_EMULATOR"),
           termEmulator.hasPrefix("JetBrains") {
            let ideName = jetbrainsIDEName(for: pid)
            return .jetbrains(ide: ideName)
        }

        if let termProgram = readEnvironmentVariable(for: pid, name: "TERM_PROGRAM"),
           termProgram == "Zed" {
            return .zed
        }

        // Walk the ancestor chain starting from ppid
        var current = ppid
        for _ in 0..<8 {
            guard current > 1 else { break }

            if let path = executablePath(for: current) {
                // IDEs
                if path.contains("/Zed.app/") || path.contains("/zed-editor") {
                    return .zed
                }
                if path.contains("/Visual Studio Code.app/") || path.contains("/Code.app/") {
                    return .vscode
                }

                // Terminals
                if path.contains("/iTerm2.app/") || path.contains("/iTerm.app/") {
                    return .terminal(app: "iTerm2")
                }
                if path.contains("/Terminal.app/") {
                    return .terminal(app: "Terminal")
                }
                if path.contains("/Warp.app/") {
                    return .terminal(app: "Warp")
                }
                if path.contains("/Alacritty.app/") {
                    return .terminal(app: "Alacritty")
                }
                if path.contains("/kitty.app/") || path.contains("/Kitty.app/") {
                    return .terminal(app: "Kitty")
                }
                if path.contains("/WezTerm.app/") || path.contains("/wezterm") {
                    return .terminal(app: "WezTerm")
                }
                if path.contains("/Ghostty.app/") {
                    return .terminal(app: "Ghostty")
                }
            }

            if let name = processName(for: current), name == "zed" {
                return .zed
            }

            guard let nextPid = parentPid(for: current) else { break }
            current = nextPid
        }

        // If inside tmux, the tmux server is reparented to pid 1 so the
        // ancestor walk above won't reach the terminal. Check for IDE env
        // vars that survive into tmux sessions.
        if readEnvironmentVariable(for: pid, name: "TMUX") != nil {
            if readEnvironmentVariable(for: pid, name: "VSCODE_GIT_IPC_HANDLE") != nil {
                return .vscode
            }
            if let termProgram = readEnvironmentVariable(for: pid, name: "TERM_PROGRAM"),
               termProgram == "Zed" {
                return .zed
            }
            return .terminal(app: resolveTerminalFromTmux(pid: pid))
        }

        // Fallback: check TERM_PROGRAM env var
        if let termProgram = readEnvironmentVariable(for: pid, name: "TERM_PROGRAM") {
            let app: String
            switch termProgram {
            case "iTerm.app": app = "iTerm2"
            case "Apple_Terminal": app = "Terminal"
            case "WarpTerminal": app = "Warp"
            case "ghostty": app = "Ghostty"
            default: app = termProgram.isEmpty ? "Terminal" : termProgram
            }
            return .terminal(app: app)
        }

        // No focusable host found anywhere in the process tree (and not tmux,
        // not a known terminal env) — this is a headless / programmatically
        // spawned session (e.g. an Erlang/erlexec harness). Mark it as an agent.
        return .agent
    }

    /// Identifies the real terminal app when running inside tmux.
    /// TERM_PROGRAM is "tmux" inside tmux, so we check terminal-specific
    /// env vars that survive into tmux sessions (LC_TERMINAL, ITERM_SESSION_ID,
    /// GHOSTTY_RESOURCES_DIR, KITTY_PID, etc.).
    private func resolveTerminalFromTmux(pid: pid_t) -> String {
        // LC_TERMINAL is set by iTerm2 and survives into tmux
        if let lcTerminal = readEnvironmentVariable(for: pid, name: "LC_TERMINAL") {
            if lcTerminal.contains("iTerm") { return "iTerm2" }
            return lcTerminal
        }
        // iTerm2 session ID (also survives tmux)
        if readEnvironmentVariable(for: pid, name: "ITERM_SESSION_ID") != nil {
            return "iTerm2"
        }
        // Ghostty
        if readEnvironmentVariable(for: pid, name: "GHOSTTY_RESOURCES_DIR") != nil {
            return "Ghostty"
        }
        // Kitty
        if readEnvironmentVariable(for: pid, name: "KITTY_PID") != nil {
            return "Kitty"
        }
        // WezTerm
        if readEnvironmentVariable(for: pid, name: "WEZTERM_PANE") != nil {
            return "WezTerm"
        }
        // Alacritty sets ALACRITTY_LOG or ALACRITTY_SOCKET
        if readEnvironmentVariable(for: pid, name: "ALACRITTY_SOCKET") != nil {
            return "Alacritty"
        }
        // Fall back to TERM_PROGRAM if it's not "tmux"
        if let termProgram = readEnvironmentVariable(for: pid, name: "TERM_PROGRAM"),
           termProgram != "tmux" {
            switch termProgram {
            case "iTerm.app": return "iTerm2"
            case "Apple_Terminal": return "Terminal"
            case "WarpTerminal": return "Warp"
            case "ghostty": return "Ghostty"
            default: return termProgram.isEmpty ? "Terminal" : termProgram
            }
        }
        return "Terminal"
    }

    /// Resolves the human-readable JetBrains IDE name from __CFBundleIdentifier.
    private func jetbrainsIDEName(for pid: pid_t) -> String {
        guard let bundleId = readEnvironmentVariable(for: pid, name: "__CFBundleIdentifier") else {
            return "JetBrains"
        }
        let lastPart = bundleId.split(separator: ".").last.map(String.init) ?? ""
        switch lastPart.lowercased() {
        case "pycharm": return "PyCharm"
        case "intellij", "idea": return "IntelliJ IDEA"
        case "webstorm": return "WebStorm"
        case "goland": return "GoLand"
        case "clion": return "CLion"
        case "rubymine": return "RubyMine"
        case "rider": return "Rider"
        case "phpstorm": return "PhpStorm"
        case "datagrip": return "DataGrip"
        case "dataspell": return "DataSpell"
        default: return lastPart.isEmpty ? "JetBrains" : lastPart
        }
    }

    // MARK: - Process Info Helpers

    private func executablePath(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    private func processName(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let result = proc_name(pid, &buffer, UInt32(buffer.count))
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    private func parentPid(for pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else { return nil }
        let ppid = pid_t(info.pbi_ppid)
        return ppid > 1 ? ppid : nil
    }

    /// The controlling terminal name (e.g. "ttys008") for a process, walking up
    /// the ancestor chain since the Claude process itself may have no tty while
    /// the shell that owns the Terminal tab does.
    private func controllingTTY(for pid: pid_t) -> String? {
        var current = pid
        for _ in 0..<8 {
            if let tty = ttyName(of: current) { return tty }
            guard let pp = parentPid(for: current), pp > 1 else { break }
            current = pp
        }
        return nil
    }

    private func ttyName(of pid: pid_t) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let dev = info.e_tdev
        guard dev != 0, dev != UInt32.max else { return nil } // no controlling tty
        guard let cstr = devname(dev_t(bitPattern: dev), mode_t(S_IFCHR)) else { return nil }
        let name = String(cString: cstr)
        return (name.isEmpty || name == "??") ? nil : name
    }

    /// Reads an environment variable from a running process via sysctl KERN_PROCARGS2.
    func readEnvironmentVariable(for pid: pid_t, name: String) -> String? {
        var argmax: Int32 = 0
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var size = MemoryLayout<Int32>.size

        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else {
            return nil
        }

        var procargs = [UInt8](repeating: 0, count: Int(argmax))
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        size = Int(argmax)

        guard sysctl(&mib, 3, &procargs, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        var offset = MemoryLayout<Int32>.size

        // Skip executable path and padding nulls
        while offset < size && procargs[offset] != 0 {
            offset += 1
        }
        while offset < size && procargs[offset] == 0 {
            offset += 1
        }

        // Skip argv strings
        let argc = procargs.withUnsafeBytes { $0.load(as: Int32.self) }
        for _ in 0..<argc {
            while offset < size && procargs[offset] != 0 {
                offset += 1
            }
            offset += 1
        }

        // Scan environment variables
        let searchKey = name + "="
        while offset < size {
            let start = offset
            while offset < size && procargs[offset] != 0 {
                offset += 1
            }

            if offset > start {
                let envString = String(
                    bytes: procargs[start..<offset],
                    encoding: .utf8
                ) ?? ""

                if envString.hasPrefix(searchKey) {
                    let value = String(envString.dropFirst(searchKey.count))
                    return value.isEmpty ? nil : value
                }
            }
            offset += 1
        }

        return nil
    }
}
