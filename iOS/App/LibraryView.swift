import CapdDesignSystem
import CapdMobile
import SwiftUI

struct LibraryView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var palette: CapdPalette {
        CapdPalette(colorScheme: colorScheme, increasedContrast: contrast == .increased)
    }
    @State private var model = LibraryModel()
    @State private var capturing = false
    @State private var showingSyncSettings = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                if model.syncState.phase == .attention || model.syncState.conflictCount > 0
                    || model.syncState.rejectedChanges > 0
                {
                    Section {
                        AttentionHintView(
                            state: model.syncState, openDetails: { showingSyncSettings = true })
                    }.listRowBackground(palette.background)
                        .listRowSeparatorTint(palette.border)
                } else if model.syncState.phase == .setupRequired, model.showSetupHint {
                    Section {
                        SetupHintView(
                            openDetails: { showingSyncSettings = true },
                            dismiss: { model.dismissSetupHint() })
                    }.listRowBackground(palette.background)
                        .listRowSeparatorTint(palette.border)
                }
                Section {
                    if model.captures.isEmpty {
                        ContentUnavailableView(
                            model.query.isEmpty ? "Keep something useful" : "No matching sources",
                            systemImage: model.query.isEmpty ? "bookmark" : "magnifyingglass",
                            description: Text(
                                model.query.isEmpty
                                    ? "Save a link or text, or share it to capd from another app."
                                    : "Search saved titles, links, source text, and notes."))
                    }
                    ForEach(model.captures) { capture in
                        NavigationLink {
                            CaptureDetailView(captureID: capture.id, model: model)
                        } label: {
                            CapdSourceRow(
                                title: capture.title,
                                metadata: sourceMetadata(capture),
                                snippet: capture.selection,
                                symbol: capture.kind == .link ? "link" : "text.alignleft",
                                tint: capture.kind == .link ? .blue : .orange,
                                tags: capture.manualTags,
                                status: capture.noteConflicts.isEmpty ? nil : "Notes to review")

                        }
                    }
                } header: {
                    CapdSectionHeader("Saved sources")
                }
                .listRowBackground(palette.background)
                .listRowSeparatorTint(palette.border)
            }
            .listStyle(.plain)
            .capdCanvas()
            .navigationTitle("capd").navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $model.query, placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search saved sources"
            )
            .onChange(of: model.query) { _, _ in model.reload() }
            .onChange(of: scenePhase) { _, phase in model.sceneChanged(active: phase == .active) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Device sync", systemImage: "gearshape") { showingSyncSettings = true }
                        .accessibilityIdentifier("deviceSyncSettings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Capture", systemImage: "plus") { capturing = true }
                        .accessibilityIdentifier("captureButton")
                }
            }
            .sheet(isPresented: $capturing) { CaptureForm(model: model) }
            .sheet(isPresented: $showingSyncSettings) {
                SyncSettingsView(
                    state: model.syncState, retry: { model.retrySync() },
                    connection: model.connection)
            }
            .alert(
                "Library message",
                isPresented: Binding(
                    get: { model.error != nil }, set: { if !$0 { model.error = nil } })
            ) {
                Button("OK") { model.error = nil }
            } message: {
                Text(model.error ?? "")
            }
        }.capdCanvas()
    }
}

struct CaptureForm: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var palette: CapdPalette {
        CapdPalette(colorScheme: colorScheme, increasedContrast: contrast == .increased)
    }
    let model: LibraryModel
    @State private var isLink = true
    @State private var text = ""
    @State private var title = ""
    @State private var note = ""
    @State private var validationMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker("Capture type", selection: $isLink) {
                    Text("Link").tag(true)
                    Text("Text").tag(false)
                }.pickerStyle(.segmented)
                Section(isLink ? "Source URL" : "Source text") {
                    TextField(
                        isLink ? "https://example.com" : "Text to keep", text: $text,
                        axis: .vertical
                    )
                    .lineLimit(3...10).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("sourceInput")
                    TextField("Title (optional)", text: $title).accessibilityIdentifier(
                        "titleInput")
                }
                Section("Your note") {
                    TextField("Why keep this? (optional)", text: $note, axis: .vertical).lineLimit(
                        2...6
                    )
                    .accessibilityIdentifier("noteInput")
                }
                Section {
                    Text(
                        "Links are saved as URLs. Text is kept exactly as entered, apart from surrounding whitespace. This app does not fetch webpages."
                    )
                    .font(.footnote).foregroundStyle(palette.textSecondary)
                }
                if let validationMessage { Text(validationMessage).foregroundStyle(.red) }
            }
            .capdCanvas()
            .navigationTitle("Capture").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if model.save(text: text, title: title, note: note, isLink: isLink) {
                            dismiss()
                        } else {
                            validationMessage = model.error
                            model.error = nil
                        }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.capdCanvas()
    }
}

struct CaptureDetailView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var palette: CapdPalette {
        CapdPalette(colorScheme: colorScheme, increasedContrast: contrast == .increased)
    }
    let captureID: UUID
    let model: LibraryModel
    @State private var editing = false
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let capture = model.capture(id: captureID) {
            List {
                Section {
                    Text(capture.title).font(CapdTypography.title).foregroundStyle(palette.text)
                        .textSelection(.enabled)
                    Label("Available on this iPhone", systemImage: "iphone")
                        .font(.subheadline).foregroundStyle(palette.textSecondary)
                    Text(capture.createdAt, style: .date).font(CapdTypography.metadata)
                        .foregroundStyle(palette.textSecondary)
                }
                if let metadata = capture.metadata {
                    Section("Capture details") {
                        if let updated = metadata.updatedAt {
                            LabeledContent("Last updated") { Text(updated, format: .dateTime) }
                                .accessibilityIdentifier("captureUpdatedAt")
                        }
                        if let seen = metadata.lastSeenAt {
                            LabeledContent("Last captured") { Text(seen, format: .dateTime) }
                                .accessibilityIdentifier("captureLastSeenAt")
                        }
                        if let reminder = metadata.reminderAt {
                            LabeledContent("Reminder") { Text(reminder, format: .dateTime) }
                                .accessibilityIdentifier("captureReminderAt")
                        }
                        if let application = metadata.sourceAppBundleID {
                            LabeledContent("Captured from", value: application)
                                .accessibilityIdentifier("captureSourceApp")
                        }
                    }
                }
                Section("Source") {
                    if let raw = capture.url, let url = URL(string: raw) {
                        Link(raw, destination: url)
                        Text("URL capture. No webpage body has been fetched.").font(.footnote)
                            .foregroundStyle(palette.textSecondary)
                    }
                    if !capture.selection.isEmpty {
                        Text(capture.selection).textSelection(.enabled)
                    }
                }
                if !capture.note.isEmpty {
                    Section("Your note") { Text(capture.note).textSelection(.enabled) }
                }
                if !capture.manualTags.isEmpty {
                    Section("Your tags") {
                        Text(capture.manualTags.joined(separator: ", ")).font(
                            CapdTypography.metadata)
                    }
                }
                if !capture.noteConflicts.isEmpty {
                    Section("Notes to resolve") {
                        ForEach(capture.noteConflicts, id: \.operationID) { variant in
                            Text(variant.value ?? "Cleared note").textSelection(.enabled)
                        }
                    }.accessibilityIdentifier("noteConflicts")
                }
                if let body = capture.body {
                    Section("Saved page text") { Text(body).textSelection(.enabled) }
                }
                if !capture.generatedTags.isEmpty {
                    Section("Generated tags") {
                        Text(capture.generatedTags.joined(separator: ", "))
                    }
                }
            }
            .capdCanvas()
            .navigationTitle("Saved capture").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Edit", systemImage: "square.and.pencil") { editing = true }
                        .accessibilityIdentifier("editCapture")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Delete source", role: .destructive) { deleting = true }
                        .tint(.red)
                        .accessibilityIdentifier("deleteCapture")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if capture.kind != .image {
                        if let raw = capture.url, let url = URL(string: raw) {
                            ShareLink(item: url).accessibilityIdentifier("shareCapture")
                        } else {
                            ShareLink(item: capture.selection).accessibilityIdentifier(
                                "shareCapture")
                        }
                    }
                }
            }
            .sheet(isPresented: $editing) { AnnotationForm(capture: capture, model: model) }
            .confirmationDialog(
                "Delete this saved source?", isPresented: $deleting, titleVisibility: .visible
            ) {
                Button("Delete source", role: .destructive) {
                    if model.delete(id: capture.id) { dismiss() }
                }.accessibilityIdentifier("confirmDelete")
            }
        } else {
            ContentUnavailableView("Source deleted", systemImage: "trash")
        }
    }
}

struct AnnotationForm: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var palette: CapdPalette {
        CapdPalette(colorScheme: colorScheme, increasedContrast: contrast == .increased)
    }
    private enum Field: Hashable { case note, tags }
    @State private var capture: MobileCapture
    let model: LibraryModel
    @State private var note: String
    @State private var tags: String
    @State private var resolve = false
    @FocusState private var focusedField: Field?
    @Environment(\.dismiss) private var dismiss

    init(capture: MobileCapture, model: LibraryModel) {
        _capture = State(initialValue: capture)
        self.model = model
        _note = State(initialValue: capture.note)
        _tags = State(initialValue: capture.manualTags.joined(separator: " "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Your note") {
                    TextField("Note", text: $note, axis: .vertical).lineLimit(3...10)
                        .focused($focusedField, equals: .note)
                        .accessibilityIdentifier("editNoteInput")
                }
                Section("Your tags") {
                    TextField("Separate tags with spaces", text: $tags)
                        .focused($focusedField, equals: .tags)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("editTagsInput")
                }
                if !capture.noteConflicts.isEmpty {
                    Section("Notes to resolve") {
                        ForEach(capture.noteConflicts, id: \.operationID) { variant in
                            Text(variant.value ?? "Cleared note")
                        }
                        Toggle("Use this note to resolve all variants", isOn: $resolve)
                            .accessibilityIdentifier("resolveNoteVariants")
                    }
                }
            }
            .capdCanvas()
            .navigationTitle("Annotation").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                        .accessibilityIdentifier("dismissAnnotationKeyboard")
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save changes") {
                        let tokens = Array(
                            Set(tags.split(whereSeparator: \.isWhitespace).map { $0.lowercased() })
                        ).sorted()
                        if model.update(
                            capture: capture, note: note, tags: tokens,
                            resolving: resolve ? capture.noteConflicts.map(\.operationID) : [])
                        {
                            dismiss()
                        }
                    }.accessibilityIdentifier("saveAnnotation")
                }
            }
        }
    }
}

private func sourceMetadata(_ capture: MobileCapture) -> String {
    if let raw = capture.url, let url = URLComponents(string: raw), let host = url.host {
        return host + (url.path == "/" ? "" : url.path)
    }
    return "text · \(capture.selection.count.formatted()) chars"
}
