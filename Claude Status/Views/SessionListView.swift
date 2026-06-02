import SwiftUI

/// The popover content showing all active Claude Code sessions.
struct SessionListView: View {
    let sessions: [ClaudeSession]
    let productivityData: ProductivityData
    /// Maps a session to its attention level (working / needsYou / hardBlock / dormant).
    var attentionLevel: (ClaudeSession) -> AttentionLevel = { _ in .dormant }
    /// Foreground vs background-agent. Background agents are folded away.
    var category: (ClaudeSession) -> SessionCategory = { _ in .foreground }
    var onSessionTap: ((ClaudeSession) -> Void)?
    /// Marks a session read (drops it to dormant). Used by the hover ✓ button.
    var onAcknowledge: ((ClaudeSession) -> Void)?
    /// Moves a session between foreground and the background-agent group.
    var onToggleCategory: ((ClaudeSession) -> Void)?
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    @AppStorage("iconStyle", store: UserDefaults(suiteName: "group.com.poisonpenllc.Claude-Status"))
    private var iconStyle: SessionIconStyle = .emoji

    @State private var isRefreshing = false
    @State private var showBackground = false

    private let menuFont = Font.system(size: 13)

    /// Display names shared by 2+ sessions (e.g. several sessions in the same
    /// project). Those rows get a `#pid` tag so they can be told apart.
    private func displayName(_ s: ClaudeSession) -> String {
        s.sessionName ?? s.desktopTitle ?? s.projectName
    }

    private var duplicateDisplayNames: Set<String> {
        var seen = Set<String>(), dups = Set<String>()
        for s in sessions {
            let name = displayName(s)
            if !seen.insert(name).inserted { dups.insert(name) }
        }
        return dups
    }

    private var sortedSessions: [ClaudeSession] {
        // Surface what needs you first: hardBlock > needsYou > working > dormant,
        // then most recently active first.
        sessions.sorted {
            let l = attentionLevel($0).priority
            let r = attentionLevel($1).priority
            if l != r { return l > r }
            return $0.lastActivityAt > $1.lastActivityAt
        }
    }

    private var foregroundSessions: [ClaudeSession] {
        sortedSessions.filter { category($0) == .foreground }
    }

    private var backgroundSessions: [ClaudeSession] {
        sortedSessions.filter { category($0) == .backgroundAgent }
    }

    /// Max height for session list: 80% of screen height minus chrome.
    private var maxSessionListHeight: CGFloat {
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 800
        let chromeHeight: CGFloat = 160 // header + settings + menu + dividers
        return screenHeight * 0.8 - chromeHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if foregroundSessions.isEmpty && backgroundSessions.isEmpty {
                emptyState
            } else {
                sessionList
            }

            if productivityData.today.totalSessionTime > 0 {
                Divider()
                    .padding(.vertical, 4)
                productivitySection
            }

            Divider()
                .padding(.vertical, 4)
            menuSection
        }
        .frame(width: 300)
        .background(.background)
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(alignment: .bottom) {
            Text("Claude Status")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Text("v\(Bundle.main.appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(action: {
                withAnimation(.linear(duration: 0.5)) {
                    isRefreshing = true
                }
                onRefresh?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    isRefreshing = false
                }
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isRefreshing ? 360 : 0))
                    .animation(.linear(duration: 0.5), value: isRefreshing)
            }
            .buttonStyle(.plain)
            .help("Refresh")

            Button(action: { onSettings?() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No active sessions")
                .font(menuFont)
                .foregroundStyle(.secondary)
            Text("Sessions appear when claude is running")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var sessionList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(foregroundSessions) { rowButton($0) }
                if !backgroundSessions.isEmpty {
                    backgroundDisclosure
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxHeight: maxSessionListHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func rowButton(_ session: ClaudeSession) -> some View {
        Button {
            onSessionTap?(session)
        } label: {
            SessionRowView(
                session: session,
                iconStyle: iconStyle,
                attentionLevel: attentionLevel(session),
                showPidTag: duplicateDisplayNames.contains(displayName(session)),
                onAcknowledge: onAcknowledge.map { ack in { ack(session) } }
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(category(session) == .foreground ? "Move to Background" : "Move to Foreground") {
                onToggleCategory?(session)
            }
        }
    }

    /// Collapsible "Background (N)" group for headless / agent sessions.
    private var backgroundDisclosure: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showBackground.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showBackground ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text("Background")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(backgroundSessions.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Headless / programmatically-spawned sessions (no window to focus)")

            if showBackground {
                ForEach(backgroundSessions) { rowButton($0) }
            }
        }
    }

    private var productivitySection: some View {
        let stats = productivityData.today
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Claude Usage (Today)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(stats.totalTimeFormatted) · Score \(stats.score)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            // Stacked horizontal bar — hover shows floating legend tooltip
            ProductivityBarView(stats: stats)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private var menuSection: some View {
        VStack(spacing: 0) {
            menuButton(action: { onQuit?() }) {
                Text("Quit")
            }
        }
        .padding(.bottom, 4)
    }

    private func menuButton<Content: View>(
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Content
    ) -> some View {
        MenuButtonView(action: action, label: label)
            .font(menuFont)
    }
}

/// A menu-style button with hover highlight, similar to Claude Code's menu items.
private struct MenuButtonView<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Content

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                        .padding(.horizontal, 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

}
