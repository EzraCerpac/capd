import CapdDesignSystem
import CapdMobile
import CapdSync
import SwiftUI

struct SetupHintView: View {
    let openDetails: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CapdSpacing.small) {
            Text("Captures stay on this device").font(CapdTypography.rowTitle)
            Text("Connect an existing library after preserving and reviewing these captures.").font(
                .footnote)
            HStack {
                Button("Device sync", action: openDetails)
                    .accessibilityIdentifier("openSyncSettings")
                Spacer()
                Button("Got it", action: dismiss)
                    .accessibilityIdentifier("dismissSyncIntroduction")
            }.buttonStyle(.borderless)
                .frame(minHeight: 44)
        }.padding(.vertical, CapdSpacing.row)
    }
}

struct AttentionHintView: View {
    let state: AutomaticSyncState
    let openDetails: () -> Void

    var body: some View {
        Button(action: openDetails) {
            Label(SyncPresentationCopy.attentionTitle(state), systemImage: "exclamationmark.bubble")
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.buttonStyle(.borderless)
            .accessibilityIdentifier("syncAttention")
    }
}

struct SyncSettingsView: View {
    let state: AutomaticSyncState
    let retry: () -> Void
    var systemSearch: PhoneSystemSearch? = nil
    var connection: PhoneLibraryConnection? = nil
    var websiteIcons: PhoneWebsiteIcons? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showingSetup = false

    var body: some View {
        NavigationStack {
            Form {
                Section("On this device") {
                    Text("Captures save here immediately and stay available offline.")
                }
                if let websiteIcons {
                    Section("Website icons") {
                        Toggle(
                            "Show synced website icons",
                            isOn: Binding(
                                get: { websiteIcons.displayEnabled },
                                set: { websiteIcons.setDisplayEnabled($0) })
                        ).accessibilityIdentifier("showWebsiteIcons")
                        Text(
                            "Icons arrive through your connected library and stay available offline. This device never requests icons from websites. Enable Load website icons on a connected Mac; its background agent needs to be available to generate new icons, including for links saved here."
                        ).font(.footnote)
                        if let issue = state.websiteIconIssue {
                            Text(issue.detail).font(.footnote)
                                .accessibilityIdentifier("websiteIconSyncIssue")
                        }
                    }
                }
                if let systemSearch {
                    Section("System search") {
                        Toggle(
                            "Find captures in Spotlight and Shortcuts",
                            isOn: Binding(
                                get: { systemSearch.enabled }, set: { systemSearch.setEnabled($0) })
                        )
                        .accessibilityIdentifier("systemSearchEnabled")
                        Text(
                            "Share saved titles and your manual tags with this device’s system search. Source text and notes are excluded. Shared captures appear after capd next opens. Indexed entries receive a 30-day expiration and renew while capd is active. Turning this off requests removal; failures can be retried."
                        )
                        .font(.footnote)
                        if systemSearch.updating {
                            ProgressView("Updating system search")
                        } else if let error = systemSearch.error {
                            Text(error).accessibilityIdentifier("systemSearchError")
                            Button("Retry search update") { systemSearch.retry() }
                        } else {
                            Text(
                                systemSearch.enabled
                                    ? "System search is ready" : "System search is off"
                            )
                            .accessibilityIdentifier("systemSearchStatus")
                        }
                    }
                }
                Section("Device sync") {
                    HStack {
                        Text(SyncPresentationCopy.title(state))
                        Spacer()
                        if state.phase == .syncing {
                            ProgressView().accessibilityLabel("Updating devices")
                        }
                    }.accessibilityIdentifier("deviceSyncState")
                    Text(SyncPresentationCopy.explanation(state)).font(.footnote)
                    if state.phase == .setupRequired {
                        Button("Prepare device connection") { showingSetup = true }
                            .accessibilityIdentifier("prepareDeviceConnection")
                    }
                    if let completed = state.lastSuccessfulSync {
                        LabeledContent("Last completed device update") {
                            Text(completed, style: .relative)
                        }
                    }
                    if state.phase == .attention, state.lastError != nil {
                        Button("Retry connection", action: retry)
                            .accessibilityIdentifier("retryDeviceSync")
                    }
                }
                if state.conflictCount > 0 {
                    Section("Notes to review") {
                        Text(
                            "Sources with note variants are marked in your library. Open one to review its notes. Your notes are retained until you choose a resolution."
                        )
                        Button("Return to library") { dismiss() }
                    }
                }
                if state.rejectedChanges > 0 {
                    Section("Changes not accepted") {
                        Text(
                            "Some device changes were not accepted. Their local data is retained. This build does not yet provide a recovery tool for those changes."
                        )
                    }
                }
                DisclosureGroup("Connection details") {
                    if let error = state.lastError { Text(error).textSelection(.enabled) }
                    if let retry = state.nextRetryAt {
                        LabeledContent("Next automatic attempt") { Text(retry, style: .relative) }
                    }
                    Text(
                        "Device updates run while capd is active. iOS may delay delivery while the app is closed."
                    )
                    .font(.footnote)
                    #if DEBUG
                        LabeledContent(
                            "Local changes to deliver", value: state.pendingChanges.formatted()
                        )
                        .accessibilityIdentifier("pendingStatus")
                    #endif
                }
            }
            .capdCanvas()
            .navigationTitle("Device sync").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("closeSyncSettings")
                }
            }
        }.capdCanvas()
            .sheet(isPresented: $showingSetup) {
                if let connection, !syntheticEnrollmentPreview {
                    LibraryConnectionView(connection: connection)
                } else {
                    EnrollmentPreparationView()
                }
            }
    }

    private var syntheticEnrollmentPreview: Bool {
        #if DEBUG && targetEnvironment(simulator)
            ProcessInfo.processInfo.arguments.contains("--capd-synthetic-enrollment")
        #else
            false
        #endif
    }
}

enum SyncPresentationCopy {
    static func attentionTitle(_ state: AutomaticSyncState) -> String {
        if state.conflictCount > 0 { return "Some notes need review" }
        if state.rejectedChanges > 0 { return "Some device changes need attention" }
        return "Device sync needs attention"
    }

    static func title(_ state: AutomaticSyncState) -> String {
        switch state.phase {
        case .setupRequired: "Not connected"
        case .idle: "Automatic device updates"
        case .syncing: "Updating devices"
        case .offline: "Offline"
        case .retrying: "Reconnecting"
        case .paused: "Paused"
        case .attention: attentionTitle(state)
        }
    }

    static func explanation(_ state: AutomaticSyncState) -> String {
        switch state.phase {
        case .setupRequired:
            "This device is not connected. Prepare a backup and review the library import before connecting."
        case .idle:
            "capd delivers changes automatically between connected devices. Captures remain available here when you're offline."
        case .syncing:
            "capd is updating the connected library. You can keep capturing."
        case .offline:
            "Your captures are saved here. Device updates resume when capd is open and connected."
        case .retrying:
            "Your captures are saved here. capd is trying the connection again automatically."
        case .paused:
            "Device updates continue when capd is active. Captures remain available here."
        case .attention:
            state.conflictCount > 0 || state.rejectedChanges > 0
                ? "Local data is retained. See the details below before continuing."
                : "Your captures are saved here. The connection has not recovered after automatic attempts."
        }
    }
}

private struct EnrollmentPreparationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = SyncEnrollmentDraft()
    @State private var result: String?

    private var syntheticPreview: Bool {
        #if DEBUG && targetEnvironment(simulator)
            ProcessInfo.processInfo.arguments.contains("--capd-synthetic-enrollment")
        #else
            false
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Preserve your library") {
                    Text(
                        "Your captures stay on this device. Connecting this library requires a verified migration and backup before device enrollment is available."
                    )
                    Button("Connect this device") {}
                        .disabled(true)
                        .accessibilityIdentifier("connectDeviceDisabled")
                }
                if syntheticPreview {
                    Section("Disposable test setup") {
                        Text(
                            "This preview uses synthetic details and temporary storage. It does not contact a server or connect your library."
                        ).font(.footnote)
                        TextField("HTTPS sync address", text: $draft.address)
                            .textContentType(.URL).keyboardType(.URL)
                            .accessibilityIdentifier("setupAddress")
                        TextField("Service ID", text: $draft.serviceID)
                        TextField("Library ID", text: $draft.libraryID)
                        TextField("Device ID", text: $draft.deviceID)
                        SecureField("Synthetic credential", text: $draft.credential)
                            .accessibilityIdentifier("setupCredential")
                        Button("Fill synthetic details") {
                            result = nil
                            draft.address = "https://sync.example.invalid/v1/sync"
                            draft.serviceID = UUID().uuidString
                            draft.libraryID = UUID().uuidString
                            draft.deviceID = UUID().uuidString
                            draft.credential = "synthetic-preview-only"
                        }.accessibilityIdentifier("fillSyntheticSetup")
                        Button("Check test setup") {
                            do {
                                let count = try draft.verifyTemporarySetup()
                                result =
                                    "Test setup verified: \(count) queued capture survived reopening temporary storage. Your library is unchanged."
                            } catch {
                                result = error.localizedDescription
                            }
                            draft.credential = ""
                        }.accessibilityIdentifier("checkSyntheticSetup")
                        if let result {
                            Text(result).accessibilityIdentifier("syntheticSetupResult")
                        }
                    }.textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }
            .capdCanvas()
            .navigationTitle("Device connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        draft.credential = ""
                        dismiss()
                    }
                }
            }
        }
    }
}
