import SwiftUI
import ApenCore

/// Searchable list of saved transcriptions with a detail pane.
struct HistoryView: View {
    let model: AppModel
    @State private var viewModel: HistoryViewModel

    init(model: AppModel) {
        self.model = model
        _viewModel = State(initialValue: HistoryViewModel(store: model.history))
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $viewModel.selectedID) {
                ForEach(viewModel.sections, id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.records) { record in
                            HistoryRow(record: record)
                                .tag(record.id)
                        }
                    }
                }
            }
            .overlay {
                if viewModel.records.isEmpty {
                    ContentUnavailableView(
                        viewModel.query.isEmpty ? "No transcriptions yet" : "No matches",
                        systemImage: viewModel.query.isEmpty ? "waveform" : "magnifyingglass",
                        description: Text(viewModel.query.isEmpty ? "Press ⌥Space and start talking." : "Try another search.")
                    )
                }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            if let record = viewModel.selected {
                HistoryDetail(record: record, model: model, onDelete: { viewModel.delete(record) })
            } else {
                ContentUnavailableView("Select a transcription", systemImage: "text.alignleft")
            }
        }
        .searchable(text: $viewModel.query, placement: .sidebar, prompt: "Search transcriptions")
        .task { await viewModel.observe() }
        .onChange(of: viewModel.query) { viewModel.refresh() }
    }
}

@MainActor
@Observable
final class HistoryViewModel {
    struct DaySection {
        let title: String
        let records: [TranscriptRecord]
    }

    var query = ""
    var selectedID: Int64?
    private(set) var records: [TranscriptRecord] = []
    @ObservationIgnored private let store: HistoryStore?

    init(store: HistoryStore?) {
        self.store = store
    }

    var selected: TranscriptRecord? {
        records.first { $0.id == selectedID }
    }

    var sections: [DaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) {
                title = "Today"
            } else if calendar.isDateInYesterday(day) {
                title = "Yesterday"
            } else {
                title = day.formatted(date: .complete, time: .omitted)
            }
            return DaySection(title: title, records: grouped[day] ?? [])
        }
    }

    /// Re-runs the search whenever the history changes.
    func observe() async {
        guard let store else { return }
        for await _ in store.observeRecent(limit: 1) {
            refresh()
        }
    }

    func refresh() {
        guard let store else { return }
        records = (try? store.search(query, limit: 500, offset: 0)) ?? []
        if selectedID == nil || !records.contains(where: { $0.id == selectedID }) {
            selectedID = records.first?.id
        }
    }

    func delete(_ record: TranscriptRecord) {
        guard let id = record.id else { return }
        try? store?.delete(id: id)
        if let path = record.audioPath { try? FileManager.default.removeItem(atPath: path) }
        refresh()
    }
}

private struct HistoryRow: View {
    let record: TranscriptRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.status == .failed ? "Transcription failed" : record.finalText)
                .lineLimit(2)
                .foregroundStyle(record.status == .failed ? .orange : .primary)
            HStack(spacing: 6) {
                Image(systemName: record.kind == .file ? "doc" : "mic")
                Text(record.createdAt, format: .dateTime.hour().minute())
                if let source = record.sourceName { Text("· \(source)").lineLimit(1) }
                Text("· \(Duration.seconds(record.durationSeconds).formatted(.time(pattern: .minuteSecond)))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct HistoryDetail: View {
    let record: TranscriptRecord
    let model: AppModel
    let onDelete: () -> Void
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Button {
                    model.copy(record.finalText)
                    flash("final")
                } label: {
                    Label(copied == "final" ? "Copied" : "Copy", systemImage: copied == "final" ? "checkmark" : "doc.on.doc")
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(record.finalText.isEmpty)
                if record.rawText != record.finalText, !record.rawText.isEmpty {
                    Button {
                        model.copy(record.rawText)
                        flash("raw")
                    } label: {
                        Label(copied == "raw" ? "Copied" : "Copy Original", systemImage: copied == "raw" ? "checkmark" : "text.quote")
                    }
                    .help("The transcript before dictionary replacements and cleanup")
                }
                if record.status == .failed, record.audioPath != nil {
                    Button("Retry") { model.retry(record) }
                }
                if let path = record.audioPath, FileManager.default.fileExists(atPath: path) {
                    Button("Show Audio") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
            }
            ScrollView {
                Text(record.status == .failed ? (record.error ?? "Transcription failed.") : record.finalText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            metadata
        }
        .padding(20)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.createdAt.formatted(date: .abbreviated, time: .standard))
            Text(details)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var details: String {
        var parts = [record.kind == .file ? "File" : "Dictation"]
        if let source = record.sourceName { parts.append(source) }
        parts.append("\(Duration.seconds(record.durationSeconds).formatted(.time(pattern: .minuteSecond))) of audio")
        parts.append(record.asrModel)
        if let cleanup = record.cleanupModel { parts.append("cleaned by \(cleanup)") }
        if record.pasted { parts.append("pasted") }
        return parts.joined(separator: " · ")
    }

    private func flash(_ which: String) {
        copied = which
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == which { copied = nil }
        }
    }
}
