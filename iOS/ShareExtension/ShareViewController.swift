import CapdDesignSystem
import CapdMobile
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class ShareDraft {
    var capture: MobileCapture?
    var note = ""
    var saving = false
    var error: String?
}

@MainActor
final class ShareViewController: UIViewController {
    private let draft = ShareDraft()

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(
            rootView: ShareCaptureView(
                draft: draft,
                save: { [weak self] in
                    self?.save()
                },
                cancel: { [weak self] in
                    self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
                }))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        Task {
            do {
                let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
                let providers = items.flatMap { $0.attachments ?? [] }
                let source: String
                let isLink: Bool
                if let provider = providers.first(where: {
                    $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
                }) {
                    source = try await load(provider, type: UTType.url.identifier)
                    isLink = true
                } else if let provider = providers.first(where: {
                    $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
                }) {
                    source = try await load(provider, type: UTType.plainText.identifier)
                    isLink = false
                } else if let text = items.compactMap({ $0.attributedContentText?.string }).first {
                    source = text
                    isLink = false
                } else {
                    throw CaptureValidationError.emptyText
                }
                draft.capture = try CaptureInput.make(text: source, isLink: isLink)
            } catch { draft.error = error.localizedDescription }
        }
    }

    private func save() {
        guard var capture = draft.capture, !draft.saving else { return }
        draft.saving = true
        capture.note = draft.note
        do {
            _ = try MobileEnvironment.session(role: .shareExtension).save(capture)
            extensionContext?.completeRequest(returningItems: nil)
        } catch {
            draft.error = error.localizedDescription
            draft.saving = false
        }
    }

    private func load(_ provider: NSItemProvider, type: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url = item as? URL {
                    continuation.resume(returning: url.absoluteString)
                } else if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let data = item as? Data, let text = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: CaptureValidationError.emptyText)
                }
            }
        }
    }
}

struct ShareCaptureView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    private var palette: CapdPalette {
        CapdPalette(colorScheme: colorScheme, increasedContrast: contrast == .increased)
    }
    @Bindable var draft: ShareDraft
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    if let capture = draft.capture {
                        HStack(alignment: .top, spacing: CapdSpacing.control) {
                            CapdIconTile(
                                symbol: capture.kind == .link ? "link" : "text.alignleft",
                                tint: capture.kind == .link ? .blue : .orange)
                            Text(capture.url ?? capture.selection).foregroundStyle(palette.text)
                                .textSelection(.enabled)
                        }
                    } else if draft.error == nil {
                        ProgressView("Loading source")
                    }
                }
                Section("Your note") {
                    TextField("Add a note (optional)", text: $draft.note, axis: .vertical)
                        .lineLimit(2...5).accessibilityIdentifier("shareNoteInput")
                }
                if let error = draft.error { Text(error).foregroundStyle(.red) }
                Text("Saves to this device.").font(.footnote).foregroundStyle(
                    palette.textSecondary)
            }
            .capdCanvas()
            .navigationTitle("Save to capd").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(draft.capture == nil || draft.saving)
                }
            }
        }.capdCanvas()
    }
}
