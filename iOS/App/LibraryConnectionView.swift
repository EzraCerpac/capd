import CapdMobile
import CapdSync
import Security
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryConnectionView: View {
    let connection: PhoneLibraryConnection
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var serviceID = ""
    @State private var libraryID = ""
    @State private var credential = ""
    @State private var reviewHash = ""
    @State private var receiptHash = ""
    @State private var reviewed = false
    @State private var authorized = false
    @State private var archiveOriginal = false
    @State private var importing = false
    @State private var importingReview = true
    @State private var exporting = false
    @State private var credentialGenerationError: String?

    var body: some View {
        NavigationStack {
            Form {
                if connection.busy { ProgressView("Checking library connection") }
                if let status = connection.status {
                    Text(status).accessibilityIdentifier("connectionStatus")
                }
                if let error = connection.error {
                    VStack(alignment: .leading) {
                        Text("Previous setup attempt failed").font(.headline)
                        Text(error)
                    }.accessibilityIdentifier("connectionError")
                }
                if let preparation = connection.preparation {
                    Section("Retained backup") {
                        Text(
                            "\(preparation.captureCount) saved sources. The original library and pending changes remain on this device."
                        )
                        LabeledContent(
                            "New device ID", value: preparation.enrollment.deviceID.uuidString
                        )
                        .textSelection(.enabled)
                        Text(
                            "Authorize this fresh device ID for the same service and library, and use its device credential below."
                        )
                        .font(.footnote)
                        if preparation.captureCount > 0 {
                            Toggle(
                                "Keep old sources archived; use server library",
                                isOn: $archiveOriginal
                            )
                            .accessibilityIdentifier("archiveOriginalLibrary")
                            Text(
                                "This keeps the original database, backup and pending operations locally. They are not imported or sent to the server."
                            )
                            .font(.footnote)
                            if !archiveOriginal {
                                Button("Export copied sources for review") { exporting = true }
                                    .accessibilityIdentifier("exportConnectionSnapshot")
                                Text(
                                    "The export contains copied sources and their attachments. It excludes the original pending-operation history. Run the host’s snapshot preview and import workflow, then bring back its review and receipt files."
                                )
                                .font(.footnote)
                                Button("Choose host review") {
                                    importingReview = true
                                    importing = true
                                }
                                if let review = connection.review {
                                    reviewSection(review)
                                    TextField(
                                        "Approved review SHA-256 from host", text: $reviewHash
                                    )
                                    .accessibilityIdentifier("connectionReviewHash")
                                    Toggle(
                                        "I reviewed competing values, tombstones, counts and feed expiration",
                                        isOn: $reviewed)
                                    Button("Choose committed import receipt") {
                                        importingReview = false
                                        importing = true
                                    }
                                    .disabled(!reviewed)
                                    if connection.hasReceipt {
                                        Text("Import receipt selected")
                                        TextField(
                                            "Pinned receipt SHA-256 from host result",
                                            text: $receiptHash
                                        )
                                        .accessibilityIdentifier("connectionReceiptHash")
                                    }
                                    Text(
                                        "Use hashes supplied separately by the coordinated host operation. A hash inside an imported file does not establish its origin."
                                    )
                                    .font(.footnote)
                                }
                            }
                        } else {
                            Text(
                                "This backup is empty. No snapshot import is needed. The authenticated connected library will be checked before activation."
                            )
                            .font(.footnote)
                        }
                    }
                    Section("Activate verified connection") {
                        Button("Generate device credential") {
                            var bytes = [UInt8](repeating: 0, count: 32)
                            guard
                                SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                                    == errSecSuccess
                            else {
                                credentialGenerationError =
                                    "Could not create a secure credential. Try again."
                                return
                            }
                            credential = bytes.map { String(format: "%02x", $0) }.joined()
                            authorized = false
                            credentialGenerationError = nil
                        }
                        .disabled(connection.busy)
                        .accessibilityIdentifier("generateConnectionCredential")
                        SecureField("Fresh device credential", text: $credential)
                            .accessibilityIdentifier("connectionCredential")
                        if !credential.isEmpty {
                            LabeledContent("Credential verifier (SHA-256)") {
                                Text(BlobReference(data: Data(credential.utf8)).digest)
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }.accessibilityIdentifier("connectionCredentialVerifier")
                            Text(
                                "Provision only this verifier for the new device ID. Keep this screen open until connecting; the credential is held in memory and enters this device’s Keychain only after verification. If you leave first, revoke any unused grant before generating another credential."
                            )
                            .font(.footnote)
                        }
                        if let credentialGenerationError { Text(credentialGenerationError) }
                        Toggle(
                            "Authorize this device to connect to the verified library",
                            isOn: $authorized)
                        Button("Verify and connect") {
                            let token = credential
                            credential = ""
                            Task {
                                if await connection.connect(
                                    credential: token, reviewHash: reviewHash,
                                    receiptHash: receiptHash, reviewed: reviewed,
                                    authorized: authorized, archiveOriginal: archiveOriginal)
                                {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(
                            connection.busy || !authorized || credential.isEmpty
                                || (!archiveOriginal && preparation.captureCount > 0
                                    && (!reviewed || !connection.hasReceipt
                                        || reviewHash.isEmpty || receiptHash.isEmpty))
                        )
                        .accessibilityIdentifier("activateLibraryConnection")
                        Text(
                            "Keep this backup until the new library is verified on your devices. Original pending operations are retained separately and are not replayed or acknowledged by the import."
                        )
                        .font(.footnote)
                    }
                }
                Section(
                    connection.preparation == nil ? "Prepare connection" : "Prepare another backup"
                ) {
                    TextField("HTTPS sync address", text: $address).keyboardType(.URL)
                        .accessibilityIdentifier("connectionAddress")
                    Button("Check private connection") {
                        Task { await connection.checkEndpoint(address: address) }
                    }
                    .disabled(connection.busy || (address.isEmpty && connection.preparation == nil))
                    .accessibilityIdentifier("checkConnectionEndpoint")
                    Text(
                        "Checks HTTPS from this device without a credential or changes to either library."
                    )
                    .font(.footnote)
                    TextField("Service ID", text: $serviceID).accessibilityIdentifier(
                        "connectionServiceID")
                    TextField("Library ID", text: $libraryID).accessibilityIdentifier(
                        "connectionLibraryID")
                    Button("Save backup and prepare connection") {
                        reviewed = false
                        authorized = false
                        archiveOriginal = false
                        reviewHash = ""
                        receiptHash = ""
                        credential = ""
                        Task {
                            await connection.prepare(
                                address: address, serviceID: serviceID, libraryID: libraryID)
                        }
                    }.disabled(
                        connection.busy || address.isEmpty || serviceID.isEmpty || libraryID.isEmpty
                    )
                    .accessibilityIdentifier("prepareLibraryBackup")
                    Text(
                        "Preparing preserves this device’s saved library. Captures made after preparation require a new backup and host review before connecting."
                    )
                    .font(.footnote)
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .capdCanvas().navigationTitle("Library connection").navigationBarTitleDisplayMode(
                .inline
            )
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        credential = ""
                        dismiss()
                    }.disabled(connection.busy)
                }
            }
        }.interactiveDismissDisabled(connection.busy)
            .fileImporter(
                isPresented: $importing, allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    if importingReview {
                        reviewed = false
                        authorized = false
                        reviewHash = ""
                        receiptHash = ""
                    }
                    connection.load(url, isReview: importingReview)
                }
            }
            .sheet(isPresented: $exporting) {
                if let url = connection.transferDirectory {
                    VStack(spacing: 0) {
                        ConnectionTransferPicker(url: url) { exporting = false }
                        Button("Cancel export") { exporting = false }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .padding(.horizontal)
                            .accessibilityIdentifier("cancelConnectionExport")
                    }.capdCanvas()
                }
            }
            .onDisappear { credential = "" }
    }

    @ViewBuilder private func reviewSection(_ review: MobileSnapshotReview) -> some View {
        LabeledContent("Feed rows to expire", value: review.preview.feedRowsToExpire.formatted())
        Text("Seen counts are maximum-known lower bounds, not exact totals.").font(.footnote)
        ForEach(review.preview.items, id: \.source.id) { item in
            DisclosureGroup(item.source.source.title ?? "Saved source") {
                LabeledContent("Import action", value: item.disposition.rawValue)
                LabeledContent("Known count", value: item.proposedSeenCount.formatted())
                Text(
                    "Fields that differ: "
                        + item.differingFields.map(\.rawValue).joined(separator: ", "))
                // Full values let the operator inspect every preserved/competing field, including future metadata.
                Text(fullValues(item)).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
    }

    private func fullValues(_ item: ContentSnapshotItemPreview) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(item)).map { String(decoding: $0, as: UTF8.self) }
            ?? "Review unavailable"
    }
}

private struct ConnectionTransferPicker: UIViewControllerRepresentable {
    let url: URL
    let finished: () -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // System file copying avoids loading a potentially large asset folder into app memory.
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finished: () -> Void
        init(finished: @escaping () -> Void) { self.finished = finished }
        func documentPicker(
            _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
        ) { finished() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finished() }
    }
}
