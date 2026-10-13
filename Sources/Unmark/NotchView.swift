import SwiftUI
import UnmarkCore

/// Fixed metrics for the island, relative to the physical notch.
struct IslandMetrics {
    let notch: CGSize
    /// Concave flare that blends the island into the top edge of the screen.
    static let ear: CGFloat = 6
    static let wing: CGFloat = 26
    static let expandedRow: CGFloat = 34
    static let minimumExpandedWidth: CGFloat = 300

    var expandedWidth: CGFloat { max(notch.width + 120, Self.minimumExpandedWidth) }
    /// Size of the transparent panel that hosts every state.
    var canvas: CGSize { CGSize(width: expandedWidth + Self.ear * 2, height: notch.height + Self.expandedRow) }

    func bodySize(for phase: IslandPhase) -> CGSize {
        switch phase {
        case .hidden: notch
        case .ready: CGSize(width: notch.width + Self.wing * 2, height: notch.height)
        case .dwelling, .processing, .result: CGSize(width: expandedWidth, height: notch.height + Self.expandedRow)
        }
    }

    func bottomRadius(for phase: IslandPhase) -> CGFloat {
        switch phase {
        case .hidden, .ready: 9
        default: 16
        }
    }
}

struct NotchView: View {
    let model: AppModel
    let metrics: IslandMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let phase = model.phase
        let size = metrics.bodySize(for: phase)
        ZStack(alignment: .top) {
            NotchShape(ear: IslandMetrics.ear, bottomRadius: metrics.bottomRadius(for: phase))
                .fill(.black)
                .frame(width: size.width + IslandMetrics.ear * 2, height: size.height)
            content(for: phase)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipped()
        }
        .opacity(phase == .hidden ? 0 : 1)
        .frame(width: metrics.canvas.width, height: metrics.canvas.height, alignment: .top)
        .animation(reduceMotion ? .easeInOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.84), value: phase)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(for phase: IslandPhase) -> some View {
        switch phase {
        case .hidden:
            Color.clear
        case .ready:
            HStack(spacing: 0) {
                Image(systemName: "doc.on.clipboard")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Spacer(minLength: 0)
                Circle()
                    .fill(.white.opacity(0.85))
                    .frame(width: 6, height: 6)
            }
            .padding(.horizontal, 9)
            .frame(height: metrics.notch.height)
            .transition(.opacity)
        case .dwelling:
            expandedRow {
                DwellRing(start: model.dwellStart, duration: AppModel.dwell, animated: !reduceMotion)
                Text("Cleaning clipboard")
                    .foregroundStyle(.white.opacity(0.75))
            }
        case .processing:
            expandedRow {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Cleaning…")
                    .foregroundStyle(.white.opacity(0.75))
            }
        case .result(let outcome):
            expandedRow {
                Image(systemName: symbol(for: outcome))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint(for: outcome))
                Text(outcome.message)
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
        }
    }

    private func expandedRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: metrics.notch.height)
            HStack(spacing: 8) { content() }
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .frame(height: IslandMetrics.expandedRow - 4, alignment: .center)
        }
        .transition(.opacity)
    }

    private func symbol(for outcome: CleanOutcome) -> String {
        if outcome.isSuccess { return "checkmark.circle.fill" }
        if outcome.isProblem { return "exclamationmark.circle.fill" }
        return "checkmark.circle"
    }

    private func tint(for outcome: CleanOutcome) -> Color {
        if outcome.isSuccess { return .green }
        if outcome.isProblem { return .orange }
        return .white.opacity(0.6)
    }
}

/// Circular indicator that fills while the cursor rests on the notch.
private struct DwellRing: View {
    let start: ContinuousClock.Instant
    let duration: Duration
    let animated: Bool

    var body: some View {
        TimelineView(.animation(paused: !animated)) { _ in
            ZStack {
                Circle().stroke(.white.opacity(0.2), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: animated ? progress : 1)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 13, height: 13)
    }

    private var progress: CGFloat {
        CGFloat(min(max((ContinuousClock.now - start) / duration, 0), 1))
    }
}

/// Black island flush with the top screen edge: concave ears at the top, rounded bottom corners.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let r = min(bottomRadius, h / 2, (w - ear * 2) / 2)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: ear, y: ear), control: CGPoint(x: ear, y: 0))
        path.addLine(to: CGPoint(x: ear, y: h - r))
        path.addQuadCurve(to: CGPoint(x: ear + r, y: h), control: CGPoint(x: ear, y: h))
        path.addLine(to: CGPoint(x: w - ear - r, y: h))
        path.addQuadCurve(to: CGPoint(x: w - ear, y: h - r), control: CGPoint(x: w - ear, y: h))
        path.addLine(to: CGPoint(x: w - ear, y: ear))
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - ear, y: 0))
        path.closeSubpath()
        return path
    }
}
