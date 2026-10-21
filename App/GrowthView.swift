import ContextLensCore
import SwiftUI

/// How a recorded session's context grew: context size per model call, compactions, and the
/// calls where it grew most with what entered the context just before.
struct ContextGrowthSection: View {
    var growth: ContextGrowth
    @AppStorage("growthOpen") private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.ink3)
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 10)).foregroundStyle(Theme.ink3)
                    Text("Context growth").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink2)
                    Text(summary).font(Theme.small).foregroundStyle(Theme.ink3).monospacedDigit().lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                GrowthChart(growth: growth)
                    .frame(height: 40)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                ForEach(growth.topJumps(5)) { JumpRow(call: $0) }
                ForEach(Array(growth.compactions.prefix(3).enumerated()), id: \.offset) { _, c in
                    CompactionRow(compaction: c)
                }
                if growth.compactions.count > 3 {
                    Text("\(growth.compactions.count - 3) more compactions").font(Theme.small).foregroundStyle(Theme.ink3)
                        .padding(.horizontal, 12).frame(height: 20)
                }
            }
        }
        .padding(.bottom, open ? 5 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private var summary: String {
        var parts = ["\(growth.calls.count) calls", "\(Format.tokens(growth.firstCall ?? 0)) → peak \(Format.tokens(growth.peak))"]
        if !growth.compactions.isEmpty { parts.append("\(growth.compactions.count) compaction\(growth.compactions.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// Context size per call as a line, with compactions as vertical marks.
struct GrowthChart: View {
    var growth: ContextGrowth

    var body: some View {
        GeometryReader { geo in
            let points = points(in: geo.size)
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addLines(points)
                    p.addLine(to: CGPoint(x: points.last?.x ?? 0, y: geo.size.height))
                    p.addLine(to: CGPoint(x: 0, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(Theme.claude.opacity(0.12))
                Path { $0.addLines(points) }
                    .stroke(Theme.claude, lineWidth: 1.2)
                ForEach(Array(growth.compactions.enumerated()), id: \.offset) { _, c in
                    Rectangle().fill(Theme.changed)
                        .frame(width: 1.5, height: geo.size.height)
                        .offset(x: markX(c, in: geo.size))
                        .help("Compacted after call \(c.afterCall): \(Format.tokens(c.preTokens)) → \(Format.tokens(c.postTokens)) (\(c.trigger))")
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Context per call, from \(Format.tokens(growth.firstCall ?? 0)) to a peak of \(Format.tokens(growth.peak))")
    }

    private var top: CGFloat { CGFloat(max(growth.peak, growth.compactions.map(\.preTokens).max() ?? 0, 1)) }

    private func step(_ size: CGSize) -> CGFloat {
        growth.calls.count > 1 ? size.width / CGFloat(growth.calls.count - 1) : 0
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let step = step(size), top = top
        return growth.calls.enumerated().map { i, c in
            CGPoint(x: CGFloat(i) * step, y: size.height - size.height * CGFloat(c.tokens) / top)
        }
    }

    /// Between the last call before the compaction and the first after it.
    private func markX(_ c: ContextGrowth.Compaction, in size: CGSize) -> CGFloat {
        let step = step(size)
        return min(size.width - 1.5, max(0, CGFloat(max(c.afterCall - 1, 0)) * step + step / 2 - 0.75))
    }
}

/// One of the biggest jumps: the call, how much the context grew, and the likely cause.
struct JumpRow: View {
    var call: ContextGrowth.Call

    var body: some View {
        HStack(spacing: 7) {
            Text("+\(Format.tokens(call.delta))").font(Theme.monoSmall).monospacedDigit().foregroundStyle(Theme.ink)
                .frame(minWidth: 48, alignment: .trailing)
            if let cause = call.cause {
                Text(cause.label).lineLimit(1).truncationMode(.middle)
                Text("≈\(Format.tokens(cause.tokens))").font(Theme.small).monospacedDigit().foregroundStyle(Theme.ink3)
            }
            if unexplained {
                Text("mostly not in the transcript").font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("call \(call.index)").font(Theme.monoSmall).monospacedDigit().foregroundStyle(Theme.ink3)
            Text(Format.tokens(call.tokens)).font(Theme.monoSmall).monospacedDigit().foregroundStyle(Theme.ink3)
                .frame(minWidth: 44, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 22)
        .help(call.added.prefix(6).map { "\($0.label)  ≈\(Format.tokens($0.tokens))" }.joined(separator: "\n"))
    }

    /// The text the transcript shows explains less than a quarter of the jump.
    private var unexplained: Bool {
        call.added.reduce(0) { $0 + $1.tokens } * 4 < call.delta
    }
}

struct CompactionRow: View {
    var compaction: ContextGrowth.Compaction

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 9.5)).foregroundStyle(Theme.changed)
                .frame(minWidth: 48, alignment: .trailing)
            Text("Compacted \(Format.tokens(compaction.preTokens)) → \(Format.tokens(compaction.postTokens))")
            Text(compaction.trigger).font(Theme.small).foregroundStyle(Theme.ink3)
            Spacer(minLength: 6)
            Text("after call \(compaction.afterCall)").font(Theme.monoSmall).monospacedDigit().foregroundStyle(Theme.ink3)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 22)
    }
}

extension ContextGrowth {
    /// `cli` → Claude Code CLI, `claude-desktop…` → Claude Desktop.
    var harnessLabel: String {
        guard let e = entrypoint else { return "Claude Code" }
        if e == "cli" { return "Claude Code CLI" }
        if e.hasPrefix("claude-desktop") { return "Claude Desktop" }
        if e.hasPrefix("sdk") { return "Agent SDK" }
        return e
    }
}
