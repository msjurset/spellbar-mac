import AppKit
import Observation
import SwiftUI

public struct BatchFixSummary: Equatable {
    public let from: String
    public let to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

@MainActor
@Observable
public final class SpellBarState {
    public enum Mode: Equatable {
        case hidden
        case needsPermission
        case suggestions(WordAnalysis)
        case cleanWord(String)
        case batchResult(fixes: [BatchFixSummary], skippedCount: Int = 0)
    }

    public var mode: Mode = .hidden
    public var activeIndex: Int = 0
    public var onCommitSuggestion: ((String) -> Void)?
    public var onNextMisspelled: (() -> Void)?
    public var onDismiss: (() -> Void)?

    public init() {}

    public var currentSuggestions: [String] {
        if case .suggestions(let analysis) = mode {
            return analysis.suggestions
        }
        return []
    }

    public func advanceHighlight(forward: Bool = true) {
        let count = currentSuggestions.count
        guard count > 0 else { return }
        if forward {
            activeIndex = (activeIndex + 1) % count
        } else {
            activeIndex = (activeIndex - 1 + count) % count
        }
    }

    public func commitActive() {
        let list = currentSuggestions
        guard activeIndex >= 0 && activeIndex < list.count else {
            onDismiss?()
            return
        }
        onCommitSuggestion?(list[activeIndex])
    }

    public func commitIndex(_ idx: Int) {
        let list = currentSuggestions
        guard idx >= 0 && idx < list.count else { return }
        onCommitSuggestion?(list[idx])
    }
}

public struct SpellBarView: View {
    @Bindable public var state: SpellBarState

    public init(state: SpellBarState) {
        self.state = state
    }

    public var body: some View {
        Group {
            switch state.mode {
            case .hidden:
                EmptyView()

            case .needsPermission:
                permissionView

            case .suggestions(let analysis):
                suggestionsView(analysis: analysis)

            case .cleanWord(let word):
                cleanWordView(word: word)

            case .batchResult(let fixes, let skippedCount):
                batchResultView(fixes: fixes, skippedCount: skippedCount)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(red: 0.10, green: 0.11, blue: 0.15).opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.indigo.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.42), radius: 12, x: 0, y: 6)
        .environment(\.colorScheme, .dark)
    }

    private var permissionView: some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Grant Accessibility Permission")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                Text("SpellBar needs Accessibility access to select & replace typos in Chrome.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }

            Button {
                AccessibilityBridge.shared.openAccessibilitySettings()
                state.onDismiss?()
            } label: {
                Text("Open Settings")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.indigo)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
    }

    private func suggestionsView(analysis: WordAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header strip: original typo -> preview + keyboard hints
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red.opacity(0.9))
                        .frame(width: 6, height: 6)

                    Text(analysis.coreWord)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .strikethrough(true, color: Color.red.opacity(0.85))
                        .foregroundStyle(Color.red.opacity(0.9))

                    if state.activeIndex >= 0 && state.activeIndex < analysis.suggestions.count {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.45))

                        Text(analysis.suggestions[state.activeIndex])
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.green.opacity(0.95))
                    }
                }

                Spacer(minLength: 14)

                HStack(spacing: 8) {
                    keyHint(key: "⏎", label: "Fix")
                    keyHint(key: "Tab", label: "Cycle")
                    keyHint(key: "n", label: "Next")
                    keyHint(key: "Esc", label: "Dismiss")
                }
            }

            // Suggestion pills
            HStack(spacing: 6) {
                ForEach(Array(analysis.suggestions.enumerated()), id: \.offset) { idx, suggestion in
                    let isSelected = (idx == state.activeIndex)
                    Button {
                        state.commitIndex(idx)
                    } label: {
                        HStack(spacing: 5) {
                            Text("\(idx + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.white.opacity(0.4))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(isSelected ? Color.black.opacity(0.22) : Color.white.opacity(0.06))
                                )

                            Text(suggestion)
                                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.88))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.indigo : Color.white.opacity(0.08))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(isSelected ? Color.white.opacity(0.35) : Color.white.opacity(0.1), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
            }
        }
    }

    private func cleanWordView(word: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.green)

            Text(word.isEmpty ? "No misspelled word found" : "“\(word)” — no suggestions found")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))

            Button {
                state.onNextMisspelled?()
            } label: {
                Text("Next (n)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.indigo)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.indigo.opacity(0.18))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
        }
    }

    private func batchResultView(fixes: [BatchFixSummary], skippedCount: Int) -> some View {
        Group {
            if fixes.isEmpty {
                HStack(spacing: 10) {
                    if skippedCount > 0 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.orange)

                        Text("\(skippedCount) \(skippedCount == 1 ? "word needs" : "words need") manual review — press ⌘;")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.green)

                        Text("All clean — no misspellings detected")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
            } else {
                let displayed = Array(fixes.prefix(8))
                let rows: [[BatchFixSummary]] = stride(from: 0, to: displayed.count, by: 4).map {
                    Array(displayed[$0..<min($0 + 4, displayed.count)])
                }

                VStack(alignment: .leading, spacing: 8) {
                    // Header row: count + skipped notice + keyboard hints
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.indigo)

                        Text("Auto-fixed \(fixes.count) \(fixes.count == 1 ? "typo" : "typos")")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)

                        if skippedCount > 0 {
                            Text("• \(skippedCount) skipped (⌘; to review)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.orange.opacity(0.9))
                        }

                        Spacer(minLength: 12)

                        HStack(spacing: 8) {
                            keyHint(key: "⌘Z", label: "Undo")
                            keyHint(key: "Esc", label: "Dismiss")
                        }
                    }

                    // Rows of corrected word pills (up to 4 per row, max 8 shown)
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, rowFixes in
                        HStack(spacing: 6) {
                            ForEach(Array(rowFixes.enumerated()), id: \.offset) { _, fix in
                                HStack(spacing: 4) {
                                    Text(fix.from)
                                        .font(.system(size: 11, design: .monospaced))
                                        .strikethrough(true, color: Color.red.opacity(0.85))
                                        .foregroundStyle(Color.red.opacity(0.85))
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.45))
                                    Text(fix.to)
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.green.opacity(0.95))
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(Color.white.opacity(0.08))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5)
                                        .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                                )
                            }

                            if rowIdx == rows.count - 1 && fixes.count > displayed.count {
                                Text("+\(fixes.count - displayed.count) more")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.65))
                                    .padding(.leading, 4)
                            }
                        }
                    }
                }
            }
        }
    }

    private func keyHint(key: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.12))
                )
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}
