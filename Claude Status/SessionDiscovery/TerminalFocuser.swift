import AppKit
import ApplicationServices

/// Focuses the appropriate app for a Claude session based on its source.
struct SessionFocuser {

    /// Focuses the session's host app — iTerm2 for terminal sessions,
    /// or the IDE app for Xcode/VS Code/JetBrains/Zed sessions.
    func focus(session: ClaudeSession) {
        switch session.source {
        case .terminal(let app):
            focusTerminal(app: app, sessionId: session.iTermSessionId, tmuxPaneId: session.tmuxPaneId, tmuxSocket: session.tmuxSocket, workingDirectory: session.workingDirectory)
        case .xcode:
            activateApp(bundleId: "com.apple.dt.Xcode")
        case .vscode:
            activateApp(bundleId: "com.microsoft.VSCode")
        case .jetbrains:
            activateJetBrainsApp()
        
        case .zed:
            activateApp(bundleId: "dev.zed.Zed")
        case .claudeDesktop:
            // Bring Claude Desktop to the front. There's no public deep link to
            // select a specific code session, so when the user opts in (and has
            // granted Accessibility), try to click the matching session via AX.
            activateApp(bundleId: "com.anthropic.claudefordesktop")
            let axEnabled = UserDefaults(suiteName: "group.com.poisonpenllc.Claude-Status")?
                .bool(forKey: "axJumpEnabled") ?? false
            if axEnabled, let title = session.desktopTitle, !title.isEmpty {
                // AXPress doesn't require the app to be frontmost, so jump now.
                AXSessionJumper.jump(toTitle: title)
            }
        }
    }

    // MARK: - IDE Activation

    /// Activates an app by bundle identifier.
    private func activateApp(bundleId: String) {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleId
        ).first else {
            return
        }
        app.activate()
    }

    /// Activates the frontmost JetBrains IDE. Multiple JetBrains IDEs may be
    /// running (IntelliJ, PyCharm, WebStorm, etc.), so we find any that match
    /// the JetBrains bundle ID pattern.
    private func activateJetBrainsApp() {
        let jetbrainsApp = NSWorkspace.shared.runningApplications.first { app in
            guard let bundleId = app.bundleIdentifier else { return false }
            return bundleId.hasPrefix("com.jetbrains.")
        }
        jetbrainsApp?.activate()
    }

    // MARK: - Terminal

    /// Known bundle identifiers for terminal applications.
    private static let terminalBundleIds: [String: String] = [
        "iTerm2": "com.googlecode.iterm2",
        "Terminal": "com.apple.Terminal",
        "Warp": "dev.warp.Warp-Stable",
        "Alacritty": "org.alacritty",
        "Kitty": "net.kovidgoyal.kitty",
        "WezTerm": "com.github.wez.wezterm",
        "Ghostty": "com.mitchellh.ghostty",
    ]

    private func focusTerminal(app: String, sessionId: String?, tmuxPaneId: String?, tmuxSocket: String?, workingDirectory: String) {
        // tmux sessions: select the pane/window then activate the terminal
        if let paneId = tmuxPaneId {
            focusTmuxPane(paneId: paneId, socket: tmuxSocket)
            // iTerm2: use AppleScript to focus the tab hosting tmux
            if app == "iTerm2", let sessionId {
                focusBySessionId(sessionId)
            } else {
                activateTerminalApp(name: app)
            }
            return
        }

        // iTerm2 supports focusing a specific session via AppleScript
        if app == "iTerm2" {
            if let sessionId {
                focusBySessionId(sessionId)
                return
            }
            openITermTab(at: workingDirectory)
            return
        }

        // Ghostty supports focusing a specific terminal via AppleScript
        if app == "Ghostty" {
            focusGhosttyTerminal(workingDirectory: workingDirectory)
            return
        }

        // For other terminals, just activate the app
        activateTerminalApp(name: app)
    }

    /// Activates a terminal app by bundle ID, falling back to name matching.
    private func activateTerminalApp(name: String) {
        if let bundleId = Self.terminalBundleIds[name] {
            activateApp(bundleId: bundleId)
        } else {
            let match = NSWorkspace.shared.runningApplications.first { runningApp in
                runningApp.localizedName?.contains(name) == true
            }
            match?.activate()
        }
    }

    /// Selects the target tmux pane and its window so it's visible when
    /// the terminal app comes to front. Unzooms first if another pane is zoomed.
    /// Resolves the tmux binary path, checking common Homebrew and MacPorts
    /// locations before falling back to PATH lookup via /usr/bin/env.
    private static let tmuxPath: String = {
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "/usr/bin/env"
    }()

    private func focusTmuxPane(paneId: String, socket: String?) {
        var baseArgs = [String]()
        if let socket {
            baseArgs += ["-S", socket]
        }
        let tmuxBin = Self.tmuxPath
        let usesEnv = tmuxBin == "/usr/bin/env"

        // Select the window containing the target pane
        let selectWindow = Process()
        selectWindow.executableURL = URL(fileURLWithPath: tmuxBin)
        selectWindow.arguments = (usesEnv ? ["tmux"] : []) + baseArgs + ["select-window", "-t", paneId]
        try? selectWindow.run()
        selectWindow.waitUntilExit()

        // Unzoom the current window if zoomed (resize-pane -Z toggles zoom;
        // check window_zoomed_flag first to avoid accidentally zooming in)
        let checkZoom = Process()
        let pipe = Pipe()
        checkZoom.executableURL = URL(fileURLWithPath: tmuxBin)
        checkZoom.arguments = (usesEnv ? ["tmux"] : []) + baseArgs + [
            "display-message", "-p", "#{window_zoomed_flag}"
        ]
        checkZoom.standardOutput = pipe
        try? checkZoom.run()
        checkZoom.waitUntilExit()
        let zoomFlag = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        if zoomFlag == "1" {
            let unzoom = Process()
            unzoom.executableURL = URL(fileURLWithPath: tmuxBin)
            unzoom.arguments = (usesEnv ? ["tmux"] : []) + baseArgs + ["resize-pane", "-Z"]
            try? unzoom.run()
            unzoom.waitUntilExit()
        }

        // Select the target pane
        let selectPane = Process()
        selectPane.executableURL = URL(fileURLWithPath: tmuxBin)
        selectPane.arguments = (usesEnv ? ["tmux"] : []) + baseArgs + ["select-pane", "-t", paneId]
        try? selectPane.run()
        selectPane.waitUntilExit()
    }

    /// Validates that a string contains only alphanumeric characters and hyphens (safe for AppleScript interpolation).
    private static let safeIdPattern = try! NSRegularExpression(pattern: #"^[A-Za-z0-9\-]+$"#)

    private func focusBySessionId(_ sessionId: String) {
        // ITERM_SESSION_ID format is "w0t0p0:UUID" — extract the UUID portion
        // which matches iTerm2's AppleScript `unique ID` property.
        let uniqueId: String
        if let colonIndex = sessionId.firstIndex(of: ":") {
            uniqueId = String(sessionId[sessionId.index(after: colonIndex)...])
        } else {
            uniqueId = sessionId
        }
        // Validate to prevent AppleScript injection
        let range = NSRange(uniqueId.startIndex..., in: uniqueId)
        guard Self.safeIdPattern.firstMatch(in: uniqueId, range: range) != nil else {
            return
        }

        // Select the correct tab/window BEFORE activating so iTerm raises
        // the right window to front (not whichever was last active).
        // Note: `select aTab` works at top scope but window selection requires
        // a `tell aWindow` block to properly raise the window.
        let script = """
        tell application "iTerm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if unique ID of aSession is "\(uniqueId)" then
                            select aTab
                            tell aWindow
                                select
                            end tell
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
        runAppleScript(script)
    }

    /// Escapes a string for safe interpolation into AppleScript string literals.
    private func appleScriptEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Ghostty

    /// Finds a Ghostty terminal whose working directory matches the session's
    /// and focuses it, bringing the containing window to front.
    ///
    /// Both paths are normalized via alias resolution before comparison so that
    /// symlink paths (e.g. ~/Source/…) and mount paths (e.g. /Volumes/…) that
    /// refer to the same directory still match correctly.
    private func focusGhosttyTerminal(workingDirectory: String) {
        let escapedDir = appleScriptEscape(workingDirectory)
        let script = """
        tell application "Ghostty"
            set targetDir to "\(escapedDir)"
            try
                set normalTarget to POSIX path of ((POSIX file targetDir) as alias)
            on error
                set normalTarget to targetDir
            end try
            repeat with aWindow in windows
                repeat with t in every terminal of aWindow
                    set tDir to working directory of t
                    try
                        set normalTDir to POSIX path of ((POSIX file tDir) as alias)
                    on error
                        set normalTDir to tDir
                    end try
                    if normalTDir is normalTarget then
                        focus t
                        set index of aWindow to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
            activate
        end tell
        """
        runAppleScript(script)
    }

    private func openITermTab(at directory: String) {
        let escapedDir = appleScriptEscape(directory)
        let script = """
        tell application "iTerm2"
            activate
            tell current window
                create tab with default profile
                tell current session
                    write text "cd \\\"\(escapedDir)\\\""
                end tell
            end tell
        end tell
        """
        runAppleScript(script)
    }

    private func runAppleScript(_ source: String) {
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
    }
}

// MARK: - Accessibility-based session jump (opt-in)

/// Uses the Accessibility API to click the Claude Desktop session whose title
/// matches `desktopTitle`. Requires the user to grant Accessibility permission
/// to Claude Status and to enable the feature in Settings.
///
/// Best-effort and intentionally narrow: it only inspects Claude Desktop's own
/// element tree and only performs an AXPress on a title-matching element.
/// Writes a debug trace to `/tmp/claude-status-ax.log` to aid tuning.
enum AXSessionJumper {
    static let desktopBundleId = "com.anthropic.claudefordesktop"
    private static let logPath = "/tmp/claude-status-ax.log"

    /// Triggers the standard macOS "control this computer" prompt and registers
    /// the app with TCC. Call when the user opts in — far more reliable than
    /// manually adding the app in System Settings.
    static func ensureTrusted() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(opts)
        log("ensureTrusted() -> AXIsProcessTrusted=\(trusted)")
    }

    static func jump(toTitle title: String) {
        guard !normalize(title).isEmpty else { return }
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: desktopBundleId).first else {
            log("Claude Desktop not running (trusted=\(AXIsProcessTrusted()))")
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // Electron/Chromium only exposes its web-content AX tree (the session
        // list) once a client sets these. Native menus are visible without it.
        AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        let target = normalize(title)
        if findAndPress(axApp, target: target, depth: 0) {
            log("PRESSED \"\(title)\"")
            return
        }
        // The web tree builds asynchronously after enabling AX — retry once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if findAndPress(axApp, target: target, depth: 0) {
                log("PRESSED \"\(title)\" (retry)")
            } else {
                logDiagnostics(axApp, title: title)
            }
        }
    }

    /// Depth-first search that presses the first title-matching, pressable
    /// element and stops — avoids walking the (huge) rest of the tree. Skips
    /// the menu-bar subtree (native menus, never the session list).
    private static func findAndPress(_ el: AXUIElement, target: String, depth: Int) -> Bool {
        if depth > 60 { return false }
        if let role = copy(el, kAXRoleAttribute) as? String, role == "AXMenuBar" { return false }
        if let t = text(of: el), isMatch(normalize(t), target), press(el) {
            return true
        }
        for child in children(of: el) where findAndPress(child, target: target, depth: depth + 1) {
            return true
        }
        return false
    }

    private static func isMatch(_ n: String, _ target: String) -> Bool {
        guard !n.isEmpty else { return false }
        if n == target { return true }
        return n.count > 6 && target.count > 6 && (n.contains(target) || target.contains(n))
    }

    /// Full tree walk that samples text — only on failure, to aid debugging.
    private static func logDiagnostics(_ axApp: AXUIElement, title: String) {
        var sample: [String] = []
        func walk(_ el: AXUIElement, _ depth: Int) {
            if depth > 60 || sample.count >= 150 { return }
            if let t = text(of: el), !t.isEmpty { sample.append(t) }
            for child in children(of: el) { walk(child, depth + 1) }
        }
        walk(axApp, 0)
        log("NO MATCH for \"\(title)\" (trusted=\(AXIsProcessTrusted())). \(sample.count) texts sampled:\n"
            + sample.prefix(120).map { "  - \($0)" }.joined(separator: "\n"))
    }

    // MARK: Tree walking

    private static func children(of el: AXUIElement) -> [AXUIElement] {
        copy(el, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func parent(of el: AXUIElement) -> AXUIElement? {
        guard let p = copy(el, kAXParentAttribute), CFGetTypeID(p) == AXUIElementGetTypeID() else { return nil }
        return (p as! AXUIElement)
    }

    private static func text(of el: AXUIElement) -> String? {
        for attr in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let v = copy(el, attr) as? String, !v.isEmpty { return v }
        }
        return nil
    }

    private static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &value) == .success else { return nil }
        return value
    }

    private static func press(_ el: AXUIElement) -> Bool {
        var node: AXUIElement? = el
        var hops = 0
        while let n = node, hops < 6 {
            var names: CFArray?
            if AXUIElementCopyActionNames(n, &names) == .success,
               let actions = names as? [String], actions.contains(kAXPressAction as String),
               AXUIElementPerformAction(n, kAXPressAction as CFString) == .success {
                return true
            }
            node = parent(of: n)
            hops += 1
        }
        return false
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func log(_ msg: String) {
        let line = "[\(Date())] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: logPath) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? line.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }
}
