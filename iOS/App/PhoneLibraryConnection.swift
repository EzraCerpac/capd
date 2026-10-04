import CapdMobile
import CapdSync
import Foundation
import Observation
import Security

@MainActor
@Observable
final class PhoneLibraryConnection {
    private(set) var preparation: MobileLibraryPreparation?
    private(set) var review: MobileSnapshotReview?
    private(set) var busy = false
    private(set) var status: String?
    private(set) var error: String?
    private(set) var endpointStatusCode: Int?
    private let root: URL
    private let activation: MobileLibraryActivation
    private let beforeTransition: () async -> Void
    private let afterTransition: () async -> Void
    private var reviewBytes: Data?
    private var receiptBytes: Data?
    var hasReceipt: Bool { receiptBytes != nil }
    var transferDirectory: URL? { preparation?.transferDirectory(in: root) }

    init(
        root: URL, credentials: any SyncCredentialStore,
        beforeTransition: @escaping () async -> Void,
        afterTransition: @escaping () async -> Void
    ) {
        self.root = root
        activation = MobileLibraryActivation(root: root, credentials: credentials)
        self.beforeTransition = beforeTransition
        self.afterTransition = afterTransition
        // Retained metadata only; never reads a credential or automatically connects.
        preparation = try? activation.preparations().last
    }

    #if DEBUG
        private static var handledPreparationLaunch = false

        func runRequestedPreparation() async {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--capd-offline-fixture") {
                guard !Self.handledPreparationLaunch else { return }
                Self.handledPreparationLaunch = true
                await runOfflineFixture(args)
                return
            }
            if args.contains("--capd-stage-device-credential")
                || args.contains("--capd-activate-archived-library")
            {
                guard !Self.handledPreparationLaunch else { return }
                Self.handledPreparationLaunch = true
                await runRequestedActivation(args)
                return
            }
            guard !Self.handledPreparationLaunch,
                args.contains("--capd-prepare-connection")
                    || args.contains("--capd-export-preparation")
            else { return }
            Self.handledPreparationLaunch = true
            if let i = args.firstIndex(of: "--capd-prepare-connection"),
                args.indices.contains(i + 3)
            {
                await prepare(address: args[i + 1], serviceID: args[i + 2], libraryID: args[i + 3])
            } else if !args.contains("--capd-export-preparation") {
                return
            }
            let prepared = error == nil && preparation != nil
            if prepared, args.contains("--capd-check-private-endpoint") {
                await checkEndpoint(address: preparation?.enrollment.endpoint.absoluteString ?? "")
            }
            struct Result: Encodable {
                let preparationSucceeded: Bool
                let snapshotID: UUID?
                let proposedDeviceID: UUID?
                let captureCount: Int?
                let manifestSHA256: String?
                let exportDirectory: String?
                let selectedConfiguration: MobileLibraryConfiguration?
                let endpointStatusCode: Int?
                let failure: String?
                let credentialCreated = false
                let activated = false
            }
            var exported: String?
            if prepared, let preparation {
                do {
                    let relative = "Library/ConnectionPreviews/\(preparation.backupID.uuidString)"
                    let destination = root.appendingPathComponent(relative)
                    try FileManager.default.createDirectory(
                        at: destination.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.copyItem(
                            at: preparation.directory(in: root), to: destination)
                    }
                    exported = relative
                } catch { self.error = error.localizedDescription }
            }
            let result = Result(
                preparationSucceeded: prepared,
                snapshotID: prepared ? preparation?.backupID : nil,
                proposedDeviceID: prepared ? preparation?.enrollment.deviceID : nil,
                captureCount: prepared ? preparation?.captureCount : nil,
                manifestSHA256: prepared ? preparation?.manifestFileDigest : nil,
                exportDirectory: exported,
                selectedConfiguration: try? MobileLibraryAccess.selected(in: root),
                endpointStatusCode: endpointStatusCode,
                failure: error ?? (prepared ? nil : "No retained preparation is available."))
            if let data = try? JSONEncoder().encode(result) {
                try? data.write(
                    to: root.appendingPathComponent("Library/connection-preparation-result.json"),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }

        private func runOfflineFixture(_ args: [String]) async {
            struct Result: Encodable {
                var action: String?
                var capture: MobileCapture?
                var pendingIDs: [UUID] = []
                var failure: String?
            }
            var result = Result()
            await beforeTransition()
            do {
                guard let index = args.firstIndex(of: "--capd-offline-fixture"),
                    args.indices.contains(index + 3),
                    let id = UUID(uuidString: args[index + 2]),
                    let preparation,
                    let enrollment = try MobileLibraryAccess.selected(in: root).enrollment,
                    enrollment == preparation.enrollment,
                    UUID(uuidString: args[index + 1]) == enrollment.deviceID
                else { throw MobileActivationError.invalidConfiguration }
                let action = args[index + 3]
                result.action = action
                let selected = try MobileLibraryAccess.selected(in: root)
                let store = try MobileStore(
                    url: selected.databaseURL(in: root),
                    deviceID: enrollment.deviceID, binding: enrollment.binding)
                let marker = "Capd device sync check " + id.uuidString
                if action == "create" {
                    guard try store.capture(id: id) == nil else { throw SyncError.invalidOperation }
                    var capture = MobileCapture(
                        id: id, kind: .text, title: marker,
                        selection: marker, note: "Created offline on iPhone")
                    capture.manualTags = ["phone-sync-check"]
                    try store.save(capture)
                } else if let capture = try store.capture(id: id) {
                    guard capture.title == marker, capture.selection == marker else {
                        throw SyncError.invalidOperation
                    }
                    switch action {
                    case "edit":
                        try store.update(
                            capture, note: "Edited offline on iPhone",
                            tags: ["phone-sync-check", "offline-tag"])
                    case "delete": try store.delete(id: id)
                    case "inspect": break
                    default: throw SyncError.invalidOperation
                    }
                } else if action != "inspect" {
                    throw SyncError.invalidOperation
                }
                result.capture = try store.capture(id: id)
                result.pendingIDs = try store.pending().filter { $0.captureID == id }.map(\.id)
            } catch { result.failure = error.localizedDescription }
            if let bytes = try? JSONEncoder().encode(result) {
                try? bytes.write(
                    to: root.appendingPathComponent("Library/synthetic-sync-result.json"),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            await afterTransition()
        }

        private func runRequestedActivation(_ args: [String]) async {
            struct Result: Encodable {
                var deviceID: UUID?
                var snapshotID: UUID?
                var credentialSHA256: String?
                var activated = false
                var activeCaptureCount: Int?
                var pendingCount: Int?
                var originalCapturesAbsent: Bool?
                var selectedConfiguration: MobileLibraryConfiguration?
                var failure: String?
            }
            var result = Result()
            let staging = KeychainSyncCredentialStore(service: "dev.jxd.capd.phone.setup")
            do {
                let flag =
                    args.contains("--capd-stage-device-credential")
                    ? "--capd-stage-device-credential" : "--capd-activate-archived-library"
                guard let index = args.firstIndex(of: flag), args.indices.contains(index + 3),
                    let preparation,
                    UUID(uuidString: args[index + 1]) == preparation.backupID,
                    UUID(uuidString: args[index + 2]) == preparation.enrollment.deviceID,
                    args[index + 3] == preparation.manifestFileDigest,
                    try MobileLibraryAccess.selected(in: root) == preparation.configuration
                else { throw MobileActivationError.invalidConfiguration }
                result.deviceID = preparation.enrollment.deviceID
                result.snapshotID = preparation.backupID
                let token: String
                if flag == "--capd-stage-device-credential" {
                    if let existing = try? staging.read(for: preparation.enrollment) {
                        token = existing
                    } else {
                        var bytes = [UInt8](repeating: 0, count: 32)
                        guard
                            SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                                == errSecSuccess
                        else { throw SyncConnectionError.credentialUnavailable }
                        token = bytes.map { String(format: "%02x", $0) }.joined()
                        _ = try staging.insertIfAbsent(token, for: preparation.enrollment)
                    }
                } else {
                    token = try staging.read(for: preparation.enrollment)
                }
                let digest = BlobReference(data: Data(token.utf8)).digest
                result.credentialSHA256 = digest
                if flag == "--capd-activate-archived-library" {
                    guard args.indices.contains(index + 4), args[index + 4] == digest else {
                        throw SyncConnectionError.invalidCredential
                    }
                    result.activated = await connect(
                        credential: token, reviewHash: "", receiptHash: "", reviewed: false,
                        authorized: true, archiveOriginal: true)
                    guard result.activated else {
                        result.failure = error ?? "Activation failed."
                        throw MobileActivationError.invalidConfiguration
                    }
                    try staging.remove(for: preparation.enrollment)
                    let selected = try MobileLibraryAccess.selected(in: root)
                    result.selectedConfiguration = selected
                    let store = try MobileStore(
                        url: selected.databaseURL(in: root),
                        deviceID: preparation.enrollment.deviceID,
                        binding: preparation.enrollment.binding)
                    let captures = try store.search()
                    result.activeCaptureCount = captures.count
                    result.pendingCount = try store.pending().count
                    result.originalCapturesAbsent = Set(captures.map(\.id)).isDisjoint(
                        with: preparation.snapshot.captures.map(\.id))
                }
            } catch {
                if result.failure == nil { result.failure = error.localizedDescription }
            }
            if let bytes = try? JSONEncoder().encode(result) {
                try? bytes.write(
                    to: root.appendingPathComponent("Library/connection-activation-result.json"),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
    #endif

    func checkEndpoint(address: String) async {
        guard !busy else { return }
        busy = true
        error = nil
        status = nil
        endpointStatusCode = nil
        defer { busy = false }
        do {
            let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let endpoint = raw.isEmpty ? preparation?.enrollment.endpoint : URL(string: raw)
            else { throw SyncConnectionError.invalidEndpoint }
            let transport = try URLSessionSyncTransport(
                endpoint: endpoint,
                binding: SyncLibraryBinding(libraryID: UUID(), serviceID: UUID()),
                deviceID: UUID(), maximumResponseBytes: 8192, timeout: 10)
            let response = try await transport.send(
                SyncHTTPRequest(
                    method: "POST", path: "/v1/sync",
                    headers: ["Content-Type": "application/json"], body: Data("{}".utf8)))
            endpointStatusCode = response.status
            status =
                response.status == 401
                ? "Private HTTPS endpoint reached (HTTP 401). No credential was sent. Library identity still needs authenticated verification."
                : "HTTPS endpoint replied HTTP \(response.status), rather than the expected 401. Connection is not verified."
        } catch { self.error = error.localizedDescription }
    }

    func prepare(address: String, serviceID: String, libraryID: String) async {
        guard !busy else { return }
        busy = true
        error = nil
        status = nil
        defer { busy = false }
        do {
            guard
                let endpoint = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
                let service = UUID(
                    uuidString: serviceID.trimmingCharacters(in: .whitespacesAndNewlines)),
                let library = UUID(
                    uuidString: libraryID.trimmingCharacters(in: .whitespacesAndNewlines))
            else { throw SyncConnectionError.invalidEndpoint }
            let binding = SyncLibraryBinding(libraryID: library, serviceID: service)
            _ = try SyncEnrollment(endpoint: endpoint, binding: binding, deviceID: UUID())
            await beforeTransition()
            let activation = activation
            do {
                preparation = try await Task.detached(priority: .utility) {
                    try activation.prepare(endpoint: endpoint, binding: binding)
                }.value
                review = nil
                reviewBytes = nil
                receiptBytes = nil
                status = "Backup saved. Your original library and pending changes are retained."
            } catch { self.error = error.localizedDescription }
            await afterTransition()
        } catch { self.error = error.localizedDescription }
    }

    func load(_ url: URL, isReview: Bool) {
        guard !busy else { return }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let bytes = try MobileLibraryActivation.readBounded(
                url,
                maximum: isReview ? 64 * 1_024 * 1_024 : SyncHTTPHandler.maximumBodyBytes)
            if isReview {
                let value = try JSONDecoder().decode(MobileSnapshotReview.self, from: bytes)
                guard let preparation,
                    value.preview.snapshotID == preparation.snapshot.snapshotID,
                    value.preview.targetBinding == preparation.enrollment.binding,
                    value.snapshotSHA256 == preparation.manifestFileDigest
                else { throw MobileActivationError.invalidHandoff }
                review = value
                reviewBytes = bytes
                receiptBytes = nil
            } else {
                _ = try JSONDecoder().decode(ContentSnapshotImportReceipt.self, from: bytes)
                receiptBytes = bytes
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func connect(
        credential: String, reviewHash: String, receiptHash: String,
        reviewed: Bool, authorized: Bool, archiveOriginal: Bool = false
    ) async -> Bool {
        guard !busy, let preparation, authorized,
            preparation.captureCount == 0 || reviewed || archiveOriginal
        else { return false }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let handoff: MobileReviewedImport?
            if preparation.captureCount > 0 && !archiveOriginal {
                guard let reviewBytes, let receiptBytes else {
                    throw MobileActivationError.missingImport
                }
                handoff = try MobileReviewedImport(
                    reviewBytes: reviewBytes, receiptBytes: receiptBytes,
                    approvedReviewSHA256: reviewHash.trimmingCharacters(
                        in: .whitespacesAndNewlines),
                    approvedReceiptSHA256: receiptHash.trimmingCharacters(
                        in: .whitespacesAndNewlines))
                try activation.validate(handoff!, for: preparation)
            } else {
                handoff = nil
            }
            await beforeTransition()
            do {
                _ = try await activation.activate(
                    preparation, handoff: handoff, credential: credential,
                    originalDisposition: archiveOriginal ? .keepArchivedOnly : .importReviewed)
                status =
                    "Connected. The app and share sheet now use the verified library. Your original library is retained."
                await afterTransition()
                return true
            } catch {
                self.error = error.localizedDescription
                await afterTransition()
                return false
            }
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}
