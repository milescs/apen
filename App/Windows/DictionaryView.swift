import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ApenCore

/// Personal dictionary: "When I say X, write Y", with a live preview.
struct DictionaryView: View {
    let model: AppModel
    @State private var selection: DictionaryEntry.ID?
    @State private var draft = DraftEntry()
    @State private var errorMessage: String?
    @State private var sample = "Please check the RLS policy before we merge the PR."

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Table(model.dictionary, selection: $selection) {
                    TableColumn("On") { entry in
                        Toggle("", isOn: Binding(
                            get: { entry.enabled },
                            set: { newValue in
                                var updated = entry
                                updated.enabled = newValue
                                try? model.saveDictionaryEntry(updated)
                            }
                        ))
                        .labelsHidden()
                    }
                    .width(32)
                    TableColumn("When I say", value: \.trigger)
                    TableColumn("Also heard as") { entry in
                        Text(entry.aliases.joined(separator: ", ")).foregroundStyle(.secondary)
                    }
                    TableColumn("Write") { entry in
                        Text(entry.isVocabularyOnly ? "(same spelling)" : entry.replacement)
                            .foregroundStyle(entry.isVocabularyOnly ? .secondary : .primary)
                            .lineLimit(1)
                    }
                }
                .onChange(of: selection) { _, id in
                    draft = DraftEntry(model.dictionary.first { $0.id == id })
                    errorMessage = nil
                }
                HStack {
                    Button {
                        selection = nil
                        draft = DraftEntry()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    Spacer()
                    Button("Import…", action: importEntries)
                    Button("Export…", action: exportEntries)
                        .disabled(model.dictionary.isEmpty)
                }
                .padding(10)
            }
            .frame(minWidth: 420)

            editor
                .frame(minWidth: 300, idealWidth: 340)
        }
    }

    private var editor: some View {
        Form {
            Section(draft.id == nil ? "New entry" : "Edit entry") {
                TextField("When I say", text: $draft.trigger, prompt: Text("RLS"))
                TextField("Also heard as", text: $draft.aliases, prompt: Text("our LS, R L S"))
                    .help("Comma-separated spellings the speech model sometimes produces instead")
                TextField("Write", text: $draft.replacement, prompt: Text("row-level security"), axis: .vertical)
                    .lineLimit(1...4)
                    .help("Leave empty to write the phrase exactly as spelled above (fixes spelling or capitalization)")
                Toggle("Match case exactly", isOn: $draft.caseSensitive)
                    .help("Turn on for triggers that are also common words, e.g. US vs us")
                Toggle("Help the speech model recognize it", isOn: Binding(
                    get: { draft.effectiveBoost },
                    set: { draft.boost = $0 }
                ))
                    .help("Vocabulary boosting. Best for names and jargon of four or more letters; short acronyms usually don't need it")
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.caption)
                }
                HStack {
                    if draft.id != nil {
                        Button("Delete", role: .destructive) {
                            if let entry = model.dictionary.first(where: { $0.id == draft.id }) {
                                model.deleteDictionaryEntry(entry)
                            }
                            selection = nil
                            draft = DraftEntry()
                        }
                    }
                    Spacer()
                    Button(draft.id == nil ? "Add Entry" : "Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.trigger.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("Try it") {
                TextField("Sample text", text: $sample, axis: .vertical)
                    .lineLimit(2...5)
                Text(model.matcher.expand(sample))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        do {
            try model.saveDictionaryEntry(draft.entry)
            errorMessage = nil
            if draft.id == nil { draft = DraftEntry() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importEntries() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let entries = try JSONDecoder().decode([DictionaryEntry].self, from: Data(contentsOf: url))
            try model.replaceDictionary(entries.map { entry in
                var copy = entry
                copy.id = nil
                return copy
            })
        } catch {
            errorMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func exportEntries() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Apen Dictionary.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(model.dictionary).write(to: url)
    }
}

/// Editable form state for one entry.
private struct DraftEntry {
    var id: Int64?
    var trigger = ""
    var aliases = ""
    var replacement = ""
    var caseSensitive = false
    /// Until the user flips it, new entries use the default (on for names/jargon of 4+ letters).
    var boost = false { didSet { boostTouched = true } }
    var enabled = true
    private var boostTouched = false

    init(_ entry: DictionaryEntry? = nil) {
        guard let entry else { return }
        id = entry.id
        trigger = entry.trigger
        aliases = entry.aliases.joined(separator: ", ")
        replacement = entry.replacement
        caseSensitive = entry.caseSensitive
        boost = entry.boost
        enabled = entry.enabled
        boostTouched = true
    }

    /// Until the user flips it, follows the default for the current trigger.
    var effectiveBoost: Bool {
        boostTouched ? boost : DictionaryEntry(trigger: trigger.trimmingCharacters(in: .whitespaces)).boost
    }

    var entry: DictionaryEntry {
        DictionaryEntry(
            id: id,
            trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines),
            aliases: aliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            replacement: replacement,
            caseSensitive: caseSensitive,
            boost: effectiveBoost,
            enabled: enabled
        )
    }
}
