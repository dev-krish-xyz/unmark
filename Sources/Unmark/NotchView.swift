import SwiftUI
import UnmarkCore

/// Fixed metrics for the island, relative to the physical notch.
struct IslandMetrics {
    let notch: CGSize
    /// Concave flare that blends the island into the top edge of the screen.
    static let ear: CGFloat = 6
    static let wing: CGFloat = 26
    static let toastRow: CGFloat = 34
    static let popupBody: CGFloat = 196

    var popupSize: CGSize { CGSize(width: max(notch.width + 300, 500), height: notch.height + Self.popupBody) }
    var toastSize: CGSize { CGSize(width: max(notch.width + 120, 300), height: notch.height + Self.toastRow) }
    /// Size of the panel that hosts every state: exactly the open popup.
    var canvas: CGSize { CGSize(width: popupSize.width + Self.ear * 2, height: popupSize.height) }

    func bodySize(for island: Island) -> CGSize {
        switch island {
        case .hidden: notch
        case .ready: CGSize(width: notch.width + Self.wing * 2, height: notch.height)
        case .popup: popupSize
        case .toast: toastSize
        }
    }

    func bottomRadius(for island: Island) -> CGFloat {
        switch island {
        case .hidden, .ready: 9
        case .toast: 16
        case .popup: 24
        }
    }
}

struct NotchView: View {
    let model: AppModel
    let metrics: IslandMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let island = model.island
        let size = metrics.bodySize(for: island)
        let shape = NotchShape(ear: IslandMetrics.ear, bottomRadius: metrics.bottomRadius(for: island))
        ZStack(alignment: .top) {
            Color.black
            // Content is laid out at its final size and revealed by the growing island, so text
            // never re-wraps mid-animation.
            content(for: island)
                .frame(width: size.width, height: size.height, alignment: .top)
                .animation(nil, value: island)
        }
        .frame(width: metrics.canvas.width, height: metrics.canvas.height, alignment: .top)
        .mask(alignment: .top) {
            shape.frame(width: size.width + IslandMetrics.ear * 2, height: size.height)
        }
        .opacity(island == .hidden ? 0 : 1)
        .animation(animation(for: island), value: island)
        .animation(.smooth(duration: 0.25), value: model.stage)
        .environment(\.colorScheme, .dark)
        .accessibilityHidden(island != .popup)
    }

    /// Opening settles with a slight bounce, like the Dynamic Island; closing is quicker and flat.
    private func animation(for island: Island) -> Animation {
        if reduceMotion { return .easeInOut(duration: 0.15) }
        switch island {
        case .popup: return .spring(duration: 0.5, bounce: 0.2)
        case .toast: return .spring(duration: 0.42, bounce: 0.18)
        case .ready, .hidden: return .spring(duration: 0.36, bounce: 0.04)
        }
    }

    /// Content fades in once the island has mostly opened and leaves quickly.
    private var contentTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                .animation(.easeOut(duration: 0.24).delay(0.12)),
            removal: .opacity.animation(.easeIn(duration: 0.1))
        )
    }

    @ViewBuilder
    private func content(for island: Island) -> some View {
        switch island {
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
            .transition(contentTransition)
        case .toast(let outcome):
            VStack(spacing: 0) {
                Spacer().frame(height: metrics.notch.height)
                HStack(spacing: 8) {
                    OutcomeIcon(outcome: outcome)
                    Text(outcome.message).foregroundStyle(.white).monospacedDigit()
                }
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .frame(height: IslandMetrics.toastRow - 4)
            }
            .transition(contentTransition)
        case .popup:
            PopupView(model: model, metrics: metrics, reduceMotion: reduceMotion)
                .transition(contentTransition)
        }
    }
}

/// The large hover popup: one button, then a live view of the clean.
private struct PopupView: View {
    let model: AppModel
    let metrics: IslandMetrics
    let reduceMotion: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: metrics.notch.height)
            Group {
                switch model.stage {
                case .idle: idle
                default: activity
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if showsBar {
                ActivityBar(progress: model.progress, tint: barTint, animated: !reduceMotion)
                    .padding(.horizontal, 26)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
    }

    // Lives beside the camera housing, so it stays clear of the notch itself.
    private var header: some View {
        HStack {
            Text("Unmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: metrics.notch.width + 24)
            Text(statusLabel)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .monospacedDigit()
        }
        .padding(.horizontal, 22)
    }

    private var idle: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Button(action: model.pasteAndClean) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard.fill")
                    Text("Paste & Clean")
                }
            }
            .buttonStyle(PasteButtonStyle())
            .disabled(!model.clipboardHasText)
            .opacity(model.clipboardHasText ? 1 : 0.35)
            .accessibilityHint("Reads the copied text, removes hidden characters and puts the result back on the clipboard")
            Text(model.clipboardHasText
                 ? "Removes hidden characters from your copied text, then ⌘V pastes the clean version."
                 : "Copy some text first.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                statusIcon
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Spacer(minLength: 8)
                if case .done(let outcome) = model.stage, outcome.isSuccess {
                    Button("Undo", action: model.undo)
                        .buttonStyle(SmallButtonStyle())
                        .accessibilityHint("Puts the original copied text back on the clipboard")
                }
            }
            if let preview = previewText {
                Text(preview)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
                    .id(previewKey)
                    .transition(.opacity)
            } else {
                Spacer(minLength: 0)
            }
            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch model.stage {
        case .done(let outcome):
            OutcomeIcon(outcome: outcome)
        case .undone:
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        default:
            ProgressView().controlSize(.small).tint(.white)
        }
    }

    private var title: String {
        switch model.stage {
        case .idle: ""
        case .processing:
            model.originalPreview == nil ? "Reading clipboard…" : "Cleaning \(markCount) hidden \(markCount == 1 ? "mark" : "marks")…"
        case .done(let outcome): outcome.message
        case .undone: "Original restored"
        }
    }

    private var detail: String {
        switch model.stage {
        case .idle: ""
        case .processing: markCount > 0 ? "Highlighted:  •  hidden character    ␣  unusual space" : "Checking for hidden characters…"
        case .done(let outcome): outcome.detail
        case .undone: "Your clipboard holds the original text again."
        }
    }

    private var statusLabel: String {
        switch model.stage {
        case .idle: model.hasPendingText ? "Text ready" : ""
        case .processing: "\(Int(model.progress * 100))%"
        case .done(let outcome): outcome.isSuccess ? "⌘V to paste" : ""
        case .undone: ""
        }
    }

    private var showsBar: Bool {
        switch model.stage {
        case .processing: true
        case .done(let outcome): outcome.isSuccess
        default: false
        }
    }

    private var barTint: Color {
        if case .done = model.stage { return .green }
        return .white
    }

    private var previewKey: String {
        if case .done(let outcome) = model.stage, outcome.isSuccess { return "cleaned" }
        return "original"
    }

    private var markCount: Int {
        model.originalPreview.map { TextCleaner.edits(in: $0, options: Preferences.cleaningOptions).count } ?? 0
    }

    /// Before and during cleaning the hidden characters are drawn visibly; afterwards the
    /// cleaned text is shown as is.
    private var previewText: AttributedString? {
        if case .done(let outcome) = model.stage, outcome.isSuccess, let cleaned = model.cleanedPreview {
            var text = AttributedString(cleaned)
            text.foregroundColor = .white.opacity(0.88)
            return text
        }
        return model.originalPreview.map(Self.marked)
    }

    private static func marked(_ text: String) -> AttributedString {
        let source = text as NSString
        var result = AttributedString()
        var cursor = 0
        func plain(_ range: NSRange) {
            guard range.length > 0 else { return }
            var part = AttributedString(source.substring(with: range))
            part.foregroundColor = .white.opacity(0.88)
            result += part
        }
        for edit in TextCleaner.edits(in: text, options: Preferences.cleaningOptions) {
            plain(NSRange(location: cursor, length: edit.range.location - cursor))
            var token = AttributedString(edit.replacement.isEmpty ? "•" : "␣")
            token.foregroundColor = .orange
            token.font = .system(size: 12.5, weight: .bold)
            result += token
            cursor = NSMaxRange(edit.range)
        }
        plain(NSRange(location: cursor, length: source.length - cursor))
        return result
    }
}

/// Thin live-activity bar along the bottom of the island.
private struct ActivityBar: View {
    let progress: Double
    let tint: Color
    let animated: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(tint)
                    .frame(width: max(geometry.size.width * progress, 3))
            }
        }
        .frame(height: 3)
        .animation(animated ? .easeInOut(duration: 0.55) : nil, value: progress)
        .accessibilityElement()
        .accessibilityLabel("Cleaning progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

private struct OutcomeIcon: View {
    let outcome: CleanOutcome

    var body: some View {
        Image(systemName: outcome.isSuccess ? "checkmark.circle.fill"
              : outcome.isProblem ? "exclamationmark.circle.fill" : "checkmark.circle")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(outcome.isSuccess ? Color.green : outcome.isProblem ? .orange : .white.opacity(0.6))
    }
}

private struct PasteButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.black)
            .frame(width: 230, height: 46)
            .background(RoundedRectangle(cornerRadius: 19, style: .continuous).fill(.white))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .animation(.smooth(duration: 0.15), value: configuration.isPressed)
    }
}

private struct SmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.25 : 0.14)))
            .contentShape(Capsule())
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
