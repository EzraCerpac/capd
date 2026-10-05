import Foundation
import GRDB
import Testing

@testable import CapdMobile
@testable import CapdSync

private struct RecoveryAuthorizer: SyncAuthorizer {
    let enrollment: SyncEnrollment
    func authorize(bearerCredential: String) throws -> SyncPrincipal? {
        guard bearerCredential == "synthetic-recovery-only" else { return nil }
        return SyncPrincipal(
            serviceID: enrollment.binding.serviceID, libraryID: enrollment.binding.libraryID,
            deviceID: enrollment.deviceID)
    }
}

private struct RecoveryRemote: AsyncSyncTransport {
    let binding: SyncLibraryBinding
    let deviceID: UUID
    let handler: SyncHTTPHandler
    init(_ server: SyncServer, _ enrollment: SyncEnrollment) {
        binding = enrollment.binding
        deviceID = enrollment.deviceID
        handler = SyncHTTPHandler(
            serviceID: binding.serviceID, authorizer: RecoveryAuthorizer(enrollment: enrollment),
            server: { _ in server })
    }
    func send(_ request: SyncHTTPRequest) async throws -> SyncHTTPResponse {
        handler.handle(request)
    }
}

private final class InterruptedRecoveryCredentials: SyncCredentialCreationStore,
    @unchecked Sendable
{
    let store = MemorySyncCredentialStore()
    private let lock = NSLock()
    private var interruptedDevices: Set<UUID> = []
    func read(for enrollment: SyncEnrollment) throws -> String { try store.read(for: enrollment) }
    func save(_ credential: String, for enrollment: SyncEnrollment) throws {
        try store.save(credential, for: enrollment)
    }
    func remove(for enrollment: SyncEnrollment) throws { try store.remove(for: enrollment) }
    func insertIfAbsent(_ credential: String, for enrollment: SyncEnrollment) throws -> Bool {
        let inserted = try store.insertIfAbsent(credential, for: enrollment)
        if lock.withLock({ interruptedDevices.insert(enrollment.deviceID).inserted }) {
            throw SyncHTTPError.unavailable
        }
        return inserted
    }
}

private struct ConnectionRecoveryFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let credentials = InterruptedRecoveryCredentials()
    let binding = SyncLibraryBinding(libraryID: UUID(), serviceID: UUID())
    let endpoint = URL(string: "https://synthetic.example.invalid/v1/sync")!
    var activation: MobileLibraryActivation { .init(root: root, credentials: credentials) }
    func initialize() throws -> MobileLibraryPreparation {
        _ = try MobileLibrarySession.open(root: root, role: .app, credentials: credentials)
        return try activation.prepare(endpoint: endpoint, binding: binding)
    }
    func interrupt(_ preparation: MobileLibraryPreparation) async throws {
        let server = try SyncServer(
            databaseURL: root.appendingPathComponent("authority.sqlite"),
            blobDirectory: root.appendingPathComponent("authority-assets"),
            libraryID: binding.libraryID, serviceID: binding.serviceID)
        await #expect(throws: SyncHTTPError.unavailable) {
            try await activation.activate(
                preparation, handoff: nil, credential: "synthetic-recovery-only",
                transport: RecoveryRemote(server, preparation.enrollment))
        }
        #expect(try activation.hasPendingCredentialRecovery(for: preparation))
    }
    @MainActor func model(beforeTransition: @escaping () async -> Void = {})
        -> PhoneLibraryConnection
    {
        PhoneLibraryConnection(
            root: root, credentials: credentials, beforeTransition: beforeTransition,
            afterTransition: {})
    }
    @MainActor func replace(_ model: PhoneLibraryConnection) async {
        await model.prepare(
            address: endpoint.absoluteString, serviceID: binding.serviceID.uuidString,
            libraryID: binding.libraryID.uuidString)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}

@MainActor @Test(arguments: [false, true])
func actualConnectionRetainsInterruptedRecoveryAcrossReplacement(afterTransition: Bool) async throws
{
    let f = ConnectionRecoveryFixture()
    defer { f.clean() }
    _ = try f.initialize()
    var recoveryPreparation: MobileLibraryPreparation?
    let model = f.model(beforeTransition: {
        if afterTransition, let recoveryPreparation {
            try? await f.interrupt(recoveryPreparation)
        }
    })
    await f.replace(model)
    let old = try #require(model.preparation)
    recoveryPreparation = old
    let originalStatus = model.status
    let preview = ContentSnapshotImportPreview(
        snapshotID: old.snapshot.snapshotID, digest: old.manifestDigest,
        targetBinding: old.enrollment.binding, sourceDeviceID: old.snapshot.sourceDeviceID,
        authorityCursor: 0, authorityFloor: 0, feedRowsToExpire: 0,
        countPolicy: .maximumKnownLowerBound, items: [])
    let review = MobileSnapshotReview(
        version: 1, authorityDirectory: "/synthetic/authority",
        snapshotSHA256: old.manifestFileDigest, assets: [], preview: preview)
    let receipt = ContentSnapshotImportReceipt(
        id: UUID(), snapshotID: old.snapshot.snapshotID, digest: old.manifestDigest,
        targetBinding: old.enrollment.binding, sourceDeviceID: old.snapshot.sourceDeviceID,
        authorityCursor: 0, countPolicy: .maximumKnownLowerBound, items: [])
    let reviewFile = f.root.appendingPathComponent("synthetic-review.json")
    let receiptFile = f.root.appendingPathComponent("synthetic-receipt.json")
    try JSONEncoder().encode(review).write(to: reviewFile)
    try JSONEncoder().encode(receipt).write(to: receiptFile)
    model.load(reviewFile, isReview: true)
    model.load(receiptFile, isReview: false)
    #expect(model.review == review)
    #expect(model.hasReceipt)
    if !afterTransition { try await f.interrupt(old) }
    #expect(model.preparation == old)
    let journalURL = old.directory(in: f.root).appendingPathComponent("activation-credential.json")
    let originalJournal = afterTransition ? nil : try Data(contentsOf: journalURL)
    await f.replace(model)
    #expect(model.preparation == old)
    #expect(model.error != nil)
    #expect(model.status == originalStatus)
    #expect(model.review == review)
    #expect(model.hasReceipt)
    #expect(model.hasPendingCredentialRecovery)
    #expect(!model.canPrepareBackup)
    #expect(try f.credentials.read(for: old.enrollment) == "synthetic-recovery-only")
    if let originalJournal { #expect(try Data(contentsOf: journalURL) == originalJournal) }
    #expect(try f.activation.preparations() == [old])
    let reopened = f.model()
    #expect(reopened.preparation == old)
    #expect(reopened.hasPendingCredentialRecovery)
    #expect(try MobileLibraryAccess.selected(in: f.root) == .legacy)
}

@MainActor @Test func actualConnectionRefusesUnreadableRecoveryJournal() async throws {
    let f = ConnectionRecoveryFixture()
    defer { f.clean() }
    let old = try f.initialize()
    let file = old.directory(in: f.root).appendingPathComponent("activation-credential.json")
    let bytes = Data("incomplete retained recovery".utf8)
    try bytes.write(to: file)
    let model = f.model()
    await f.replace(model)
    #expect(model.preparation == old)
    #expect(model.error != nil)
    #expect(!model.canPrepareBackup)
    #expect(try Data(contentsOf: file) == bytes)
    #expect(f.model().preparation == old)
}

@MainActor @Test func actualConnectionAllowsUnusedBackupReplacement() async throws {
    let f = ConnectionRecoveryFixture()
    defer { f.clean() }
    let old = try f.initialize()
    let model = f.model()
    await f.replace(model)
    let next = try #require(model.preparation)
    #expect(next.backupID != old.backupID)
    #expect(model.error == nil)
    #expect(model.status != nil)
    #expect(f.model().preparation == next)
    #expect(FileManager.default.fileExists(atPath: old.directory(in: f.root).path))
    #expect(try MobileLibraryAccess.selected(in: f.root) == .legacy)
}

@Test(arguments: [false, true])
func unusedReplacementWithdrawalRetainsArchiveAndRecovery(malformedJournal: Bool) async throws {
    let f = ConnectionRecoveryFixture()
    defer { f.clean() }
    let old = try f.initialize()
    let candidate = try f.activation.prepare(
        endpoint: f.endpoint, binding: f.binding, replacing: old)
    let manifest = candidate.directory(in: f.root).appendingPathComponent("preparation.json")
    let manifestBytes = try Data(contentsOf: manifest)
    let snapshot = candidate.transferDirectory(in: f.root).appendingPathComponent("snapshot.json")
    let snapshotBytes = try Data(contentsOf: snapshot)
    try await f.interrupt(old)
    let journal = old.directory(in: f.root).appendingPathComponent("activation-credential.json")
    if malformedJournal { try Data("incomplete retained recovery".utf8).write(to: journal) }
    let journalBytes = try Data(contentsOf: journal)
    for _ in 0..<2 { try f.activation.withdrawUnusedReplacement(candidate, preserving: old) }
    #expect(try f.activation.preparations() == [old])
    #expect(try Data(contentsOf: journal) == journalBytes)
    #expect(try Data(contentsOf: snapshot) == snapshotBytes)
    #expect(
        try Data(
            contentsOf: candidate.directory(in: f.root).appendingPathComponent(
                "retained-unused-preparation.json")) == manifestBytes)
    #expect(try f.credentials.read(for: old.enrollment) == "synthetic-recovery-only")
    #expect(try MobileLibraryAccess.selected(in: f.root) == .legacy)
}

@Test(arguments: ["sameID", "candidateJournal", "changedManifest", "activeSelector"])
func withdrawalRefusesUnownedOrUsedCandidates(kind: String) async throws {
    let f = ConnectionRecoveryFixture()
    defer { f.clean() }
    let old = try f.initialize()
    let candidate = try f.activation.prepare(
        endpoint: f.endpoint, binding: f.binding, replacing: old)
    try await f.interrupt(old)
    if kind == "candidateJournal" || kind == "activeSelector" {
        try await f.interrupt(candidate)
    }
    if kind == "activeSelector" {
        let server = try SyncServer(
            databaseURL: f.root.appendingPathComponent("authority.sqlite"),
            blobDirectory: f.root.appendingPathComponent("authority-assets"),
            libraryID: f.binding.libraryID, serviceID: f.binding.serviceID)
        _ = try await f.activation.activate(
            candidate, handoff: nil, credential: "",
            transport: RecoveryRemote(server, candidate.enrollment))
    }
    let manifest = candidate.directory(in: f.root).appendingPathComponent("preparation.json")
    if kind == "changedManifest" { try Data("unrelated changed metadata".utf8).write(to: manifest) }
    let bytes = try Data(contentsOf: manifest)
    #expect(throws: (any Error).self) {
        try f.activation.withdrawUnusedReplacement(
            kind == "sameID" ? old : candidate, preserving: old)
    }
    #expect(try Data(contentsOf: manifest) == bytes)
    #expect(try f.activation.hasPendingCredentialRecovery(for: old))
    #expect(try f.credentials.read(for: old.enrollment) == "synthetic-recovery-only")
}

@Test(arguments: [false, true])
func leaseOwnedPreparerRefusesProtectedRecovery(malformedJournal: Bool) async throws {
    let f = ConnectionRecoveryFixture()
    defer { f.clean() }
    let old = try f.initialize()
    try await f.interrupt(old)
    if malformedJournal {
        try Data("unreadable recovery".utf8).write(
            to: old.directory(in: f.root).appendingPathComponent(
                "activation-credential.json"))
    }
    let directory = f.root.appendingPathComponent("ConnectionBackups")
    let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(throws: MobileBackupReplacementError.pendingCredentialRecovery) {
        try f.activation.prepare(endpoint: f.endpoint, binding: f.binding, replacing: old)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == before)
    #expect(try f.activation.preparations() == [old])
}

@Test func onlyAuxiliaryEvidenceMigrationPreservesPreparedSourceDigest() throws {
    let f = ConnectionRecoveryFixture()
    defer { f.clean() }
    let preparation = try f.initialize()
    let db = try DatabaseQueue(path: f.root.appendingPathComponent("Library/captures.sqlite").path)
    let original = try MobileLibraryActivation.stateDigest(db)
    #expect(original == preparation.sourceStateDigest)
    try db.write { db in
        try removeAuxiliaryEvidence(db)
        try db.execute(
            sql: "INSERT INTO grdb_migrations(identifier) VALUES ('mobile-answer-evidence-v5')")
        try db.execute(
            sql: "CREATE TABLE mobile_answer_evidence(id INTEGER PRIMARY KEY, revision TEXT)")
        try db.execute(sql: "INSERT INTO mobile_answer_evidence VALUES (1, 'synthetic-token')")
    }
    #expect(try MobileLibraryActivation.stateDigest(db) == original)
    try db.write { db in
        try db.execute(
            sql: "INSERT INTO grdb_migrations(identifier) VALUES ('unrelated-future-migration')")
    }
    #expect(try MobileLibraryActivation.stateDigest(db) != original)
    try db.write { db in
        try db.execute(
            sql: "DELETE FROM grdb_migrations WHERE identifier='unrelated-future-migration'")
        try db.execute(sql: "UPDATE sync_meta SET sequence=sequence+1 WHERE id=1")
    }
    #expect(try MobileLibraryActivation.stateDigest(db) != original)
}

private func removeAuxiliaryEvidence(_ db: Database) throws {
    for event in ["insert", "update", "delete"] {
        try db.execute(sql: "DROP TRIGGER IF EXISTS mobile_answer_evidence_\(event)")
    }
    try db.execute(sql: "DROP TABLE IF EXISTS mobile_answer_evidence")
    try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier='mobile-answer-evidence-v5'")
}

@Test(arguments: ["unchanged", "captureChanged", "otherMigration"])
func interruptedV4RecoverySurvivesOnlyAuxiliaryV5Upgrade(change: String) async throws {
    let f = ConnectionRecoveryFixture()
    defer { f.clean() }
    _ = try MobileLibrarySession.open(root: f.root, role: .app, credentials: f.credentials)
    let originalURL = f.root.appendingPathComponent("Library/captures.sqlite")
    let db = try DatabaseQueue(path: originalURL.path)
    let expectedMigrationCount = try await db.read {
        try Int.fetchOne(
            $0,
            sql:
                "SELECT COUNT(*) FROM grdb_migrations WHERE identifier='mobile-answer-evidence-v5'")
    }
    try await db.write { try removeAuxiliaryEvidence($0) }
    #expect(
        try await db.read {
            try Int.fetchOne(
                $0,
                sql:
                    "SELECT COUNT(*) FROM grdb_migrations WHERE identifier='mobile-answer-evidence-v5'"
            )
        } == 0)
    let old = try f.activation.prepare(endpoint: f.endpoint, binding: f.binding)
    try await f.interrupt(old)
    let journal = old.directory(in: f.root).appendingPathComponent("activation-credential.json")
    let bytes = try Data(contentsOf: journal)
    let oldDigest = try MobileLibraryActivation.stateDigest(db)
    #expect(oldDigest == old.sourceStateDigest)
    let upgraded = try MobileStore(url: originalURL)
    #expect(
        try await db.read {
            try Int.fetchOne(
                $0,
                sql:
                    "SELECT COUNT(*) FROM grdb_migrations WHERE identifier='mobile-answer-evidence-v5'"
            )
        } == expectedMigrationCount)
    #expect(try MobileLibraryActivation.stateDigest(db) == oldDigest)
    #expect(try Data(contentsOf: journal) == bytes)
    #expect(try f.activation.preparations() == [old])
    #expect(try f.credentials.read(for: old.enrollment) == "synthetic-recovery-only")
    if change == "captureChanged" {
        try upgraded.save(CaptureInput.make(text: "Changed retained source", isLink: false))
    } else if change == "otherMigration" {
        try await db.write {
            try $0.execute(
                sql:
                    "INSERT INTO grdb_migrations(identifier) VALUES ('unrelated-future-migration')"
            )
        }
    }
    let server = try SyncServer(
        databaseURL: f.root.appendingPathComponent("authority.sqlite"),
        blobDirectory: f.root.appendingPathComponent("authority-assets"),
        libraryID: f.binding.libraryID, serviceID: f.binding.serviceID)
    let remote = RecoveryRemote(server, old.enrollment)
    if change == "unchanged" {
        let selected = try await f.activation.activate(
            old, handoff: nil, credential: "", transport: remote)
        #expect(selected.enrollment == old.enrollment)
        #expect(try !f.activation.hasPendingCredentialRecovery(for: old))
    } else {
        await #expect(throws: MobileActivationError.stalePreparation) {
            try await f.activation.activate(
                old, handoff: nil, credential: "", transport: remote)
        }
        #expect(try Data(contentsOf: journal) == bytes)
        #expect(try f.activation.hasPendingCredentialRecovery(for: old))
        #expect(try MobileLibraryAccess.selected(in: f.root) == .legacy)
    }
    #expect(try f.credentials.read(for: old.enrollment) == "synthetic-recovery-only")
}
