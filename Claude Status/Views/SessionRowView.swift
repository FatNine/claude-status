import SwiftUI

/// Icon display style for session rows.
enum SessionIconStyle: String, CaseIterable {
    case emoji
    case dots

    var label: String {
        switch self {
        case .emoji: "Emoji"
        case .dots: "Dots"
        }
    }
}

/// A single row in the session list showing status, project name, and time.
struct SessionRowView: View {
    let session: ClaudeSession
    var iconStyle: SessionIconStyle = .emoji
    /// The attention level driving this row's color, icon, and label.
    var attentionLevel: AttentionLevel = .dormant
    /// When several sessions share this display name, show `#pid` to tell them apart.
    var showPidTag: Bool = false
    /// Marks this session read. When non-nil and the level is `.needsYou`,
    /// a ✓ button appears on hover.
    var onAcknowledge: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            statusIndicator
                .frame(width: 16, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if displayName != session.projectName {
                        Text(session.projectName)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("\u{2022}")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    Text(session.source.label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if showPidTag {
                        Text("\u{2022}")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text("#\(session.pid)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if !session.activity.isEmpty {
                        Text("\u{2022}")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                        Text(session.activity)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Hover ✓ to mark a "your turn" session read (→ idle). Shown only on
            // hover and only for needsYou, as its own hit target — so a normal row
            // click still focuses the session and you can't dismiss by mistake.
            if isHovered, attentionLevel == .needsYou, let onAcknowledge {
                Button(action: onAcknowledge) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Mark read (set to idle)")
            }

            VStack(alignment: .trailing, spacing: 1) {
                Text(attentionLevel.label)
                    .font(.system(size: 11))
                    .foregroundStyle(attentionLevel == .hardBlock ? Color.red : Color.primary)
                Text(session.timeSinceActivity)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 14)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
                .padding(.horizontal, 6)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(session.workingDirectory)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch iconStyle {
        case .emoji:
            Text(attentionLevel.emoji)
                .font(.system(size: 14))
        case .dots:
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
        }
    }

    /// Primary label: manual /name-session, else the Claude Desktop title,
    /// else the (worktree-aware) project name.
    private var displayName: String {
        session.sessionName ?? session.desktopTitle ?? session.projectName
    }

    private var dotColor: Color {
        switch attentionLevel {
        case .working: .green
        case .needsYou: .orange
        case .hardBlock: .red    // solid red — clearly distinct from needsYou orange
        case .dormant: .gray
        }
    }
}
