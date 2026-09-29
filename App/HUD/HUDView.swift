import SwiftUI
import UtterCore

struct HUDView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.phase {
            case .recording:
                RecordingRow(model: model)
                if model.settings.showLiveText, !model.partialText.isEmpty {
                    Text(tail(of: model.partialText))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .processing:
                TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                    StatusRow(title: "Transcribing", progress: model.transcriptionProgress(), mode: model.activeMode)
                }
            case .cleaning:
                StatusRow(
                    title: "Cleaning up",
                    progress: model.cleanupProgress,
                    mode: model.activeMode,
                    hint: "⌥Space pastes it as is"
                )
            case .idle:
                EmptyView()
            }
            if let notice = model.notice {
                NoticeRow(notice: notice)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 380, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .animation(.snappy(duration: 0.2), value: model.phase)
        .animation(.snappy(duration: 0.2), value: model.notice)
    }

    private func tail(of text: String) -> String {
        text.count > 160 ? "…" + text.suffix(160) : text
    }
}

private struct RecordingRow: View {
    let model: AppModel
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
                .onAppear { pulse = true }
            if let start = model.recordingStartedAt {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .frame(width: 52, alignment: .leading)
            }
            LevelMeter(model: model)
                .frame(height: 22)
            VStack(alignment: .leading, spacing: 1) {
                ModeChip(mode: model.activeMode, automatic: model.activeModeIsAutomatic)
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    if let loading = model.modelLoadProgress(at: context.date) {
                        Text("Loading model \(Int(loading * 100))%")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if let progress = model.transcriptionProgress(), progress < 0.85 {
                        Text("Catching up \(Int(progress * 100))%")
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        Text(model.deviceName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            HUDButton(symbol: "stop.fill", help: "Stop and paste (⌥Space)") { model.stopFromHUD() }
            HUDButton(symbol: "xmark", help: "Cancel (Esc)") { model.cancelFromHUD() }
        }
    }
}

private struct StatusRow: View {
    let title: String
    let progress: Double?
    let mode: DictationMode
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(progress.map { "\(title) \(Int($0 * 100))%" } ?? "\(title)…")
                    .font(.callout)
                    .monospacedDigit()
                Spacer()
                ModeChip(mode: mode, automatic: false)
            }
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            }
            if let hint {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ModeChip: View {
    let mode: DictationMode
    let automatic: Bool

    var body: some View {
        Label(automatic ? "\(mode.name) · auto" : mode.name, systemImage: mode.symbol)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .help(automatic ? "Chosen automatically for this app" : mode.summary)
    }
}

private struct NoticeRow: View {
    let notice: AppModel.Notice

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(notice.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch notice.kind {
        case .success: "checkmark.circle.fill"
        case .info: "info.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch notice.kind {
        case .success: .green
        case .info: .secondary
        case .error: .orange
        }
    }
}

private struct HUDButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .background(.quaternary, in: Circle())
        .help(help)
    }
}

/// Rolling bar meter fed by the recorder's level.
private struct LevelMeter: View {
    let model: AppModel
    @State private var history = LevelHistory()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let levels = history.push(model.currentLevel)
            HStack(alignment: .center, spacing: 2) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule()
                        .fill(.primary.opacity(0.75))
                        .frame(width: 3, height: max(3, CGFloat(levels[index]) * 22))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

@MainActor
private final class LevelHistory {
    private var values = [Float](repeating: 0, count: 20)

    func push(_ level: Float) -> [Float] {
        values.removeFirst()
        // Ease toward the new level so the meter doesn't flicker.
        let previous = values.last ?? 0
        values.append(previous * 0.35 + level * 0.65)
        return values
    }
}
