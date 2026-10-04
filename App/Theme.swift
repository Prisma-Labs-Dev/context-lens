import AppKit
import ContextLensCore
import SwiftUI

/// Neutral warm grays in the manner of Claude Code Desktop and code editors. Color is reserved
/// for meaning: the harness, the kind of context, stale paths (amber) and changes (violet).
enum Theme {
    static let sidebar = Color(light: 0xF0EEE6, dark: 0x1B1B1A)
    static let window = Color(light: 0xF8F7F3, dark: 0x232322)
    static let editor = Color(light: 0xFDFCFA, dark: 0x1F1F1E)
    static let raised = Color(light: 0xFFFFFF, dark: 0x2B2B29)
    static let hairline = Color(light: 0xE2DFD6, dark: 0x343432)
    static let selection = Color(light: 0xE5E2D8, dark: 0x333331)
    static let hover = Color(light: 0xECE9E1, dark: 0x2A2A28)
    static let ink = Color(light: 0x1F1E1C, dark: 0xE6E4DF)
    static let ink2 = Color(light: 0x6B6963, dark: 0xA3A19B)
    static let ink3 = Color(light: 0xA09D95, dark: 0x6F6D68)

    static let claude = Color(light: 0xC2603E, dark: 0xD97757)
    static let codex = Color(light: 0x3D6A99, dark: 0x86AED6)
    static let stale = Color(light: 0xA86B12, dark: 0xE2AA4E)
    static let changed = Color(light: 0x7556A3, dark: 0xAE90DB)
    static let added = Color(light: 0x3F7A4E, dark: 0x8CC49B)
    static let removed = Color(light: 0xA6433A, dark: 0xE58A80)
    /// Presets: what a launch will load, as opposed to what is on disk.
    static let preset = Color(light: 0x2C8577, dark: 0x6CC3B5)

    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    static let body = Font.system(size: 13)
    static let small = Font.system(size: 11)
}

extension Harness {
    var color: Color { self == .claude ? Theme.claude : Theme.codex }
}

extension ContextKind {
    var color: Color {
        switch self {
        case .systemPrompt: Color(light: 0x6E7682, dark: 0x9AA2AE)
        case .instructions: Color(light: 0xA9774F, dark: 0xD3A17A)
        case .imported: Color(light: 0xC29A72, dark: 0xE0BF9C)
        case .rule: Color(light: 0x7A8A52, dark: 0xAABB82)
        case .memory: Color(light: 0x4F8A84, dark: 0x82BDB6)
        case .skill: Color(light: 0xB8952F, dark: 0xDDBE62)
        case .agent: Color(light: 0x9C6773, dark: 0xCB97A3)
        case .command: Color(light: 0x857A6C, dark: 0xB2A796)
        case .mcp: Color(light: 0x627E9F, dark: 0x93AECD)
        case .hook: Color(light: 0x8D7FA0, dark: 0xB9ABCB)
        case .environment: Color(light: 0x8A867F, dark: 0xA9A59E)
        case .onDemand: Color(light: 0xA29C91, dark: 0x8A867F)
        case .inactive: Color(light: 0xB8B2A6, dark: 0x6F6D68)
        }
    }

    var symbol: String {
        switch self {
        case .systemPrompt: "cpu"
        case .instructions: "doc.text"
        case .imported: "arrow.turn.down.right"
        case .rule: "list.bullet.rectangle"
        case .memory: "brain"
        case .skill: "wand.and.stars"
        case .agent: "person.2"
        case .command: "terminal"
        case .mcp: "server.rack"
        case .hook: "link"
        case .environment: "gearshape"
        case .onDemand: "clock.arrow.circlepath"
        case .inactive: "eye.slash"
        }
    }
}

extension LoadMode {
    var short: String {
        switch self {
        case .always: "always"
        case .listing: "listed"
        case .onDemand: "on demand"
        case .inactive: "not loaded"
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Small gray sentence-case header, like the "Pinned" and "Today" headers in Claude Code Desktop.
struct SectionHeader: View {
    var title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let trailing { Text(trailing).monospacedDigit() }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Theme.ink3)
    }
}

/// Plain icon button used in toolbars.
struct IconButton: View {
    var systemImage: String
    var help: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5))
                .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Text button with an optional icon, styled like Claude Code Desktop's quiet controls.
struct QuietButton: View {
    var title: String
    var systemImage: String?
    var tint: Color = Theme.ink2
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11)) }
                Text(title)
            }
            .font(.system(size: 12))
            .foregroundStyle(hovering ? Theme.ink : tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Left-to-right wrapping layout for legends.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxX, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
