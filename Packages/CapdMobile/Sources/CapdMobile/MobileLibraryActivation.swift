import CapdSync
import Foundation
import GRDB

public enum MobileOriginalLibraryDisposition: Sendable {
    case importReviewed
    case keepArchivedOnly
}

/// Retained locally; transferDirectory contains only the manifest and required assets.
public struct MobileLibraryPreparation: Codable, Equatable, Sendable {
    public let version: Int
    public let configuration: MobileLibraryConfiguration
    public let enrollment: SyncEnrollment
    public let snapshot: ContentSnapshotImport
    public let sourceStateDigest: String
    public let manifestDigest: String
    public let manifestFileDigest: String
    public let backupID: UUID
    public let createdAt: Date
    public var captureCount: Int { snapshot.captures.count }

    public func directory(in root: URL) -> URL {
        root.appendingPathComponent("ConnectionBackups/\(backupID.uuidString)")
    }
    public func transferDirectory(in root: URL) -> URL {
        directory(in: root).appendingPathComponent("Transfer")
    }
}

/// Wire-compatible subset of CapdSyncAdmin.SnapshotReview, without linking a host admin tool.
public struct MobileSnapshotReview: Codable, Equatable, Sendable {
    public let version: Int
    public let authorityDirectory: String
    public let snapshotSHA256: String
    public let assets: [BlobReference]
    public let preview: ContentSnapshotImportPreview
}

/// Pins come from the coordinated host-side result, separately from the imported files.
/// Computing a file's own hash and passing it back is not an authority approval.
public struct MobileReviewedImport: Sendable {
    public let review: MobileSnapshotReview
    public let receipt: ContentSnapshotImportReceipt

    public init(
        reviewBytes: Data, receiptBytes: Data,
        approvedReviewSHA256: String, approvedReceiptSHA256: String
    ) throws {
        guard reviewBytes.count <= 64 * 1_024 * 1_024,
            receiptBytes.count <= SyncHTTPHandler.maximumBodyBytes,
            Self.isDigest(approvedReviewSHA256), Self.isDigest(approvedReceiptSHA256),
            BlobReference(data: reviewBytes).digest == approvedReviewSHA256,
            BlobReference(data: receiptBytes).digest == approvedReceiptSHA256
        else { throw MobileActivationError.invalidHandoff }
        review = try JSONDecoder().decode(MobileSnapshotReview.self, from: reviewBytes)
        receipt = try JSONDecoder().decode(ContentSnapshotImportReceipt.self, from: receiptBytes)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// No administrative HTTP routes and no authority mutation. Host import is an explicit handoff.
public struct MobileLibraryActivation: Sendable {
    private let root: URL
    private let credentials: any SyncCredentialStore

    public init(root: URL, credentials: any SyncCredentialStore) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.credentials = credentials
    }

    /// Caller first suspends and drains its scheduler. Share saves receive transitionBusy
    /// while this coherent SQLite backup is made, and can retry their retained draft.
    public func prepare(endpoint: URL, binding: SyncLibraryBinding) throws
        -> MobileLibraryPreparation
    {
        let lease = try MobileLibraryLease(root: root, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        let selected = try MobileLibraryAccess.selected(in: root)
        guard selected.enrollment == nil else { throw MobileActivationError.invalidConfiguration }
        let enrollment = try SyncEnrollment(endpoint: endpoint, binding: binding, deviceID: UUID())
        try MobileLibraryConfiguration(generation: UUID(), enrollment: enrollment).validate()
        let original = try selected.databaseURL(in: root)
        let reader = try Self.reader(original)
        let state = try Self.stateDigest(reader)
        let id = UUID()
        let directory = root.appendingPathComponent("ConnectionBackups/\(id.uuidString)")
        let backup = directory.appendingPathComponent("Original")
        let raw = directory.appendingPathComponent("OriginalRaw")
        let transfer = directory.appendingPathComponent("Transfer")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: transfer.appendingPathComponent("assets"),
            withIntermediateDirectories: true)
        // SQLite's backup API includes committed WAL content; it never resets the original outbox.
        let writer = try DatabaseQueue(path: backup.appendingPathComponent("captures.sqlite").path)
        try reader.backup(to: writer)
        // Retain the original database/WAL bytes separately from the usable SQLite
        // backup. The read transaction pins committed WAL pages during the copy.
        try reader.read { _ in
            for suffix in ["", "-wal"] {
                let source = URL(fileURLWithPath: original.path + suffix)
                if FileManager.default.fileExists(atPath: source.path) {
                    _ = try Self.readBounded(source, maximum: 1_073_741_824, contents: false)
                    try FileManager.default.copyItem(
                        at: source,
                        to: raw.appendingPathComponent("captures.sqlite" + suffix))
                }
            }
        }
        try Self.copyAssets(
            from: original.deletingLastPathComponent().appendingPathComponent("assets"),
            to: backup.appendingPathComponent("assets"))
        let copied = try MobileStore(url: backup.appendingPathComponent("captures.sqlite"))
        let snapshot = try copied.contentSnapshotImport(snapshotID: id, targetBinding: binding)
        guard enrollment.deviceID != snapshot.sourceDeviceID else {
            throw MobileActivationError.identityAlreadyUsed
        }
        let bytes = try Self.encode(snapshot)
        guard bytes.count <= SyncHTTPHandler.maximumBodyBytes else {
            throw MobileActivationError.fileTooLarge
        }
        try bytes.write(to: transfer.appendingPathComponent("snapshot.json"), options: .atomic)
        for blob in try Self.assets(snapshot) {
            let source = backup.appendingPathComponent("assets/\(blob.digest)")
            let data = try Self.readBounded(source, maximum: 8 * 1_024 * 1_024)
            guard BlobReference(data: data) == blob else { throw SyncError.invalidBlob }
            try data.write(
                to: transfer.appendingPathComponent("assets/\(blob.digest)"), options: .atomic)
        }
        let preparation = MobileLibraryPreparation(
            version: 1, configuration: selected,
            enrollment: enrollment, snapshot: snapshot, sourceStateDigest: state,
            manifestDigest: BlobReference(data: bytes).digest,
            manifestFileDigest: BlobReference(data: bytes).digest, backupID: id, createdAt: Date())
        try Self.encode(preparation).write(
            to: directory.appendingPathComponent("preparation.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return preparation
    }

    /// Read and validate the retained preparation so activation can resume after app termination.
    public func preparations() throws -> [MobileLibraryPreparation] {
        let base = root.appendingPathComponent("ConnectionBackups")
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil
        )
        .compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
            guard
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("preparation.json").path)
                // An interrupted preparation is retained but never offered for activation.
            else { return nil }
            let value = try JSONDecoder().decode(
                MobileLibraryPreparation.self,
                from: Self.readBounded(
                    directory.appendingPathComponent("preparation.json"),
                    maximum: 32 * 1_024 * 1_024))
            guard value.backupID.uuidString == directory.lastPathComponent else {
                throw MobileActivationError.invalidConfiguration
            }
            return value
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func validate(_ handoff: MobileReviewedImport, for preparation: MobileLibraryPreparation)
        throws
    {
        let snapshot = preparation.snapshot
        let preview = handoff.review.preview
        let receipt = handoff.receipt
        let digest = BlobReference(data: try Self.encode(snapshot)).digest
        let assets = try Self.assets(snapshot)
        guard preparation.version == 1, preparation.backupID == snapshot.snapshotID,
            preparation.enrollment.binding == snapshot.targetBinding,
            preparation.enrollment.deviceID != snapshot.sourceDeviceID,
            digest == preparation.manifestDigest,
            handoff.review.version == 1, !handoff.review.authorityDirectory.isEmpty,
            handoff.review.snapshotSHA256 == preparation.manifestFileDigest,
            handoff.review.assets == assets,
            preview.snapshotID == snapshot.snapshotID, receipt.snapshotID == snapshot.snapshotID,
            preview.digest == digest, receipt.digest == digest,
            preview.targetBinding == snapshot.targetBinding,
            receipt.targetBinding == snapshot.targetBinding,
            preview.sourceDeviceID == snapshot.sourceDeviceID,
            receipt.sourceDeviceID == snapshot.sourceDeviceID,
            preview.countPolicy == snapshot.countPolicy,
            receipt.countPolicy == snapshot.countPolicy,
            preview.authorityCursor >= 0, preview.authorityCursor < Int64.max,
            preview.authorityFloor >= 0, preview.authorityFloor <= preview.authorityCursor,
            preview.feedRowsToExpire >= 0,
            receipt.authorityCursor == preview.authorityCursor + 1,
            preview.items.map(\.source) == snapshot.captures,
            receipt.items.count == snapshot.captures.count,
            Set(receipt.items.map(\.sourceCaptureID)).count == receipt.items.count,
            Set(receipt.items.map(\.id)).count == receipt.items.count
        else { throw MobileActivationError.invalidHandoff }
        let mappings = Dictionary(
            uniqueKeysWithValues: receipt.items.map { ($0.sourceCaptureID, $0.canonicalCaptureID) })
        for item in preview.items {
            guard mappings[item.source.id] == item.canonicalCaptureID,
                !item.countIsExact, item.proposedSeenCount >= 1
            else { throw MobileActivationError.invalidHandoff }
            guard let result = receipt.items.first(where: { $0.sourceCaptureID == item.source.id }),
                Set(result.importedNotes.map(\.importedVariantID)).count
                    == result.importedNotes.count
            else { throw MobileActivationError.invalidHandoff }
            let notes =
                [NoteVariant(operationID: item.source.noteOperationID, value: item.source.note)]
                + item.source.noteConflicts
            for note in result.importedNotes {
                guard
                    notes.contains(where: {
                        $0.operationID == note.sourceOperationID && $0.value == note.value
                    })
                else { throw MobileActivationError.invalidHandoff }
            }
        }
    }

    /// Accepts only the reviewed host result; preflight is authenticated and never sends old operations.
    /// The original database and the staged store remain on every failure. No remote import is undone.
    public func activate(
        _ preparation: MobileLibraryPreparation,
        handoff: MobileReviewedImport?, credential: String,
        originalDisposition: MobileOriginalLibraryDisposition = .importReviewed,
        transport: (any AsyncSyncTransport)? = nil
    ) async throws -> MobileLibraryConfiguration {
        try await activate(
            preparation, handoff: handoff, credential: credential,
            originalDisposition: originalDisposition,
            transport: transport, afterPublication: {})
    }

    // Test injection exercises rollback after publication while the exclusive lease is still held.
    func activate(
        _ preparation: MobileLibraryPreparation, handoff: MobileReviewedImport?,
        credential: String,
        originalDisposition: MobileOriginalLibraryDisposition = .importReviewed,
        transport: (any AsyncSyncTransport)?,
        afterPublication: @Sendable () throws -> Void
    ) async throws -> MobileLibraryConfiguration {
        let lease = try MobileLibraryLease(root: root, exclusive: true)
        defer { withExtendedLifetime(lease) {} }
        let current = try MobileLibraryAccess.selected(in: root)
        guard current == preparation.configuration, current.enrollment == nil else {
            throw MobileActivationError.sessionReplaced
        }
        let retained = try JSONDecoder().decode(
            MobileLibraryPreparation.self,
            from: Self.readBounded(
                preparation.directory(in: root).appendingPathComponent("preparation.json"),
                maximum: 32 * 1_024 * 1_024))
        let original = try Self.reader(current.databaseURL(in: root))
        guard retained == preparation,
            try Self.stateDigest(original) == preparation.sourceStateDigest,
            try await original.read({ db in
                let captures = try Data.fetchAll(db, sql: "SELECT payload FROM sync_visible")
                    .map { try JSONDecoder().decode(SharedCapture.self, from: $0) }
                let device = try String.fetchOne(db, sql: "SELECT device FROM sync_meta WHERE id=1")
                return device == preparation.snapshot.sourceDeviceID.uuidString
                    && ContentSnapshotImport(
                        snapshotID: preparation.snapshot.snapshotID,
                        targetBinding: preparation.enrollment.binding,
                        sourceDeviceID: preparation.snapshot.sourceDeviceID, captures: captures)
                        == preparation.snapshot
            })
        else { throw MobileActivationError.stalePreparation }
        if originalDisposition == .keepArchivedOnly {
            guard handoff == nil else { throw MobileActivationError.invalidHandoff }
        } else if !preparation.snapshot.captures.isEmpty {
            guard let handoff else { throw MobileActivationError.missingImport }
            try validate(handoff, for: preparation)
        } else {
            guard handoff == nil else { throw MobileActivationError.invalidHandoff }
        }
        let enrollment = preparation.enrollment
        let remote: any AsyncSyncTransport =
            try transport
            ?? URLSessionSyncTransport(
                endpoint: enrollment.endpoint, binding: enrollment.binding,
                deviceID: enrollment.deviceID)
        guard remote.binding == enrollment.binding, remote.deviceID == enrollment.deviceID else {
            throw SyncBindingError.mismatch
        }
        // Validate the credential in isolated memory; no Keychain write until preflight succeeds.
        let temporary = MemorySyncCredentialStore()
        try temporary.save(credential, for: enrollment)
        let readCredential: @Sendable () throws -> String = { try temporary.read(for: enrollment) }
        let baseline = try await remote.importBaseline(
            credential: readCredential,
            requiringGeneratedProcessingContract: true)
        guard baseline.deviceSequences[enrollment.deviceID] == nil else {
            throw MobileActivationError.identityAlreadyUsed
        }
        if let handoff { try Self.verifyAuthority(baseline, handoff: handoff) }
        let next = MobileLibraryConfiguration(generation: UUID(), enrollment: enrollment)
        let staged = try MobileStore(
            url: next.databaseURL(in: root), deviceID: enrollment.deviceID,
            binding: enrollment.binding)
        try await staged.pull(from: remote, credential: readCredential)
        guard try staged.pending().isEmpty else { throw MobileActivationError.identityAlreadyUsed }
        // Recheck authoritative device history and imported content immediately before publication.
        let verified = try await remote.importBaseline(
            credential: readCredential,
            requiringGeneratedProcessingContract: true)
        guard verified.deviceSequences[enrollment.deviceID] == nil else {
            throw MobileActivationError.identityAlreadyUsed
        }
        if let handoff { try Self.verifyAuthority(verified, handoff: handoff) }
        let visible = try staged.search()
        if let handoff {
            for item in handoff.review.preview.items
            where item.disposition != .preserveTombstone && !item.source.deleted {
                guard visible.contains(where: { $0.id == item.canonicalCaptureID }) else {
                    throw MobileActivationError.missingImport
                }
            }
            try Self.encode(handoff.receipt).write(
                to: preparation.directory(in: root).appendingPathComponent("import-receipt.json"),
                options: .atomic)
        }
        var credentialWritten = false
        var published = false
        do {
            // Recover an interrupted attempt's identical credential without overwriting it.
            // Different credentials in an existing account are retained and refused.
            guard let creator = credentials as? any SyncCredentialCreationStore else {
                throw SyncConnectionError.credentialUnavailable
            }
            credentialWritten = try creator.insertIfAbsent(credential, for: enrollment)
            guard try credentials.read(for: enrollment) == credential else {
                throw SyncConnectionError.credentialUnavailable
            }
            published = true  // Atomic write could succeed before reporting an I/O failure.
            try MobileLibraryAccess.publish(next, in: root)
            // Reopen validation occurs before releasing the transition lock. Share can
            // never observe a selector whose store fails its binding/identity checks.
            let reopened = try MobileStore(
                url: next.databaseURL(in: root),
                deviceID: enrollment.deviceID, binding: enrollment.binding)
            _ = try EnrolledSyncAdapter(
                enrollment: enrollment, store: reopened, credentials: credentials)
            try afterPublication()
            guard try MobileLibraryAccess.selected(in: root) == next else {
                throw MobileActivationError.invalidConfiguration
            }
            return next
        } catch {
            if published {
                do { try MobileLibraryAccess.publish(current, in: root) } catch {
                    throw MobileActivationError.rollbackFailed
                }
            }
            if credentialWritten {
                do { try credentials.remove(for: enrollment) } catch {
                    throw MobileActivationError.credentialCleanupRequired
                }
            }
            throw error
        }
    }

    private static func verifyAuthority(_ baseline: Baseline, handoff: MobileReviewedImport) throws
    {
        guard baseline.cursor >= handoff.receipt.authorityCursor,
            Set(baseline.captures.map(\.id)).count == baseline.captures.count
        else { throw MobileActivationError.missingImport }
        let records = Dictionary(uniqueKeysWithValues: baseline.captures.map { ($0.id, $0) })
        for item in handoff.review.preview.items {
            guard let record = records[item.canonicalCaptureID] else {
                throw MobileActivationError.missingImport
            }
            if item.disposition == .preserveTombstone || item.source.deleted {
                guard record.deleted else { throw MobileActivationError.missingImport }
            } else {
                guard !record.deleted, record.source.kind == item.source.source.kind,
                    record.source.contentHash == item.source.source.contentHash,
                    record.seenCount >= item.proposedSeenCount,
                    Set(record.manualTags).isSuperset(of: item.source.manualTags)
                else { throw MobileActivationError.missingImport }
                let values = Set([record.note] + record.noteConflicts.map(\.value))
                for note in [item.source.note] + item.source.noteConflicts.map(\.value) {
                    guard values.contains(note) else { throw MobileActivationError.missingImport }
                }
            }
        }
    }

    private static func reader(_ url: URL) throws -> DatabaseQueue {
        _ = try readBounded(url, maximum: 1_073_741_824, contents: false)
        var config = Configuration()
        config.readonly = true
        config.busyMode = .timeout(2)
        return try DatabaseQueue(path: url.path, configuration: config)
    }

    /// Logical state includes identity, cursor, exact outbox, receipts, aliases and visible projection.
    /// SQL quote() keeps binary payloads byte-exact without decoding or rewriting operations.
    private static func stateDigest(_ reader: DatabaseQueue) throws -> String {
        let tables: [String: [[String]]] = try reader.read { db in
            let names = try String.fetchAll(
                db,
                sql:
                    "SELECT name FROM sqlite_master WHERE type='table' AND (name LIKE 'sync_%' OR name='mobile_captures' OR name='grdb_migrations') ORDER BY name"
            )
            var result: [String: [[String]]] = [:]
            for name in names {
                let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(quoted))").map { row in
                    "quote(\""
                        + (row["name"] as String).replacingOccurrences(of: "\"", with: "\"\"")
                        + "\")"
                }
                let rows = try Row.fetchAll(
                    db, sql: "SELECT \(columns.joined(separator: ",")) FROM \(quoted)")
                result[name] = rows.map { row in row.map { String.fromDatabaseValue($0.1)! } }
                    .sorted { $0.lexicographicallyPrecedes($1) }
            }
            return result
        }
        return BlobReference(data: try encode(tables)).digest
    }

    private static func copyAssets(from source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        guard source.resolvingSymlinksInPath() == source else {
            throw MobileActivationError.invalidConfiguration
        }
        var total = 0
        for file in try FileManager.default.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil)
        {
            let bytes = try readBounded(file, maximum: 8 * 1_024 * 1_024)
            total += bytes.count
            guard total <= 1_073_741_824 else { throw MobileActivationError.fileTooLarge }
            try bytes.write(
                to: destination.appendingPathComponent(file.lastPathComponent), options: .atomic)
        }
    }

    private static func assets(_ snapshot: ContentSnapshotImport) throws -> [BlobReference] {
        var unique: [String: BlobReference] = [:]
        for blob in snapshot.captures.compactMap(\.source.blob) {
            guard unique[blob.digest] == nil || unique[blob.digest] == blob else {
                throw SyncError.invalidBlob
            }
            unique[blob.digest] = blob
        }
        guard unique.count <= 4_096 else { throw MobileActivationError.fileTooLarge }
        return unique.values.sorted { $0.digest < $1.digest }
    }

    public static func readBounded(_ url: URL, maximum: Int, contents: Bool = true) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            (values.fileSize ?? Int.max) <= maximum,
            url.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL
        else { throw MobileActivationError.fileTooLarge }
        if !contents { return Data() }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: maximum + 1) ?? Data()
        guard bytes.count <= maximum else { throw MobileActivationError.fileTooLarge }
        return bytes
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
}
