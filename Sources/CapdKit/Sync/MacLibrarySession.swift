import CapdSync
import Foundation
import GRDB

public struct MacLibrarySession: Sendable {
    public static let credentialService = "dev.jxd.capd.sync"
    public let store: Store
    public let runtime: MacSyncRuntime?
    public let configuration: MacSyncConfiguration?

    public static func open(paths: StoragePaths) throws -> Self {
        try open(paths: paths, credentials: KeychainSyncCredentialStore(service: credentialService))
    }

    public static func readOnlyStore(paths: StoragePaths) throws -> Store {
        let store = try Store(readOnlyPaths: paths)
        let configured = try MacSyncConfiguration.load(paths: paths)
        try store.reader.read { db in
            let binding = try StoreSync.binding(in: db)
            guard binding == configured?.binding else { throw MacSyncError.configurationRequired }
            if let configured {
                guard
                    try String.fetchOne(db, sql: "SELECT device FROM sync_meta WHERE id=1")
                        == configured.deviceID.uuidString
                else {
                    throw SyncError.wrongDevice
                }
            }
        }
        return store
    }

    static func open(
        paths: StoragePaths, credentials: any SyncCredentialStore,
        transport supplied: (any AsyncSyncTransport)? = nil
    ) throws -> Self {
        let local = try Store(paths: paths)
        guard let configuration = try MacSyncConfiguration.load(paths: paths) else {
            guard try local.reader.read({ try StoreSync.binding(in: $0) }) == nil else {
                throw MacSyncError.configurationRequired
            }
            return Self(store: local, runtime: nil, configuration: nil)
        }
        let enrollment = try configuration.enrollment()
        guard try local.reader.read({ try StoreSync.binding(in: $0) }) == configuration.binding
        else {
            throw MacSyncError.configurationRequired
        }
        let store = try Store(
            paths: paths, syncBinding: configuration.binding, deviceID: configuration.deviceID)
        let transport =
            try supplied
            ?? URLSessionSyncTransport(
                endpoint: configuration.endpoint,
                binding: configuration.binding, deviceID: configuration.deviceID,
                loopbackSOCKSPort: configuration.loopbackSOCKSPort)
        guard transport.binding == configuration.binding,
            transport.deviceID == configuration.deviceID
        else {
            throw MacSyncError.configurationChanged
        }
        let initialIssue: String?
        do {
            if configuration.enabled {
                _ = try credentials.read(for: enrollment)
            }
            initialIssue = nil
        } catch {
            initialIssue = "The device credential is unavailable. Saved changes remain queued."
        }
        let runtime = MacSyncRuntime(
            store: store, configuration: configuration, transport: transport,
            credential: { try credentials.read(for: enrollment) }, initialIssue: initialIssue)
        return Self(store: store, runtime: runtime, configuration: configuration)
    }

    public static func activate(
        paths: StoragePaths, enrollment: SyncEnrollment, loopbackSOCKSPort: Int? = nil
    ) async throws
        -> Self
    {
        let configuration = MacSyncConfiguration(
            enrollment: enrollment, loopbackSOCKSPort: loopbackSOCKSPort)
        let transport = try URLSessionSyncTransport(
            endpoint: enrollment.endpoint,
            binding: enrollment.binding, deviceID: enrollment.deviceID,
            loopbackSOCKSPort: loopbackSOCKSPort)
        return try await activate(
            paths: paths, configuration: configuration,
            credentials: KeychainSyncCredentialStore(service: credentialService),
            transport: transport)
    }

    public static func activate(paths: StoragePaths, enrollmentData: Data) async throws -> Self {
        guard enrollmentData.count <= 16_384 else { throw MacSyncError.invalidConfiguration }
        let decoded = try JSONDecoder().decode(SyncEnrollment.self, from: enrollmentData)
        let enrollment = try SyncEnrollment(
            endpoint: decoded.endpoint, binding: decoded.binding,
            deviceID: decoded.deviceID)
        struct Routing: Decodable { let loopbackSOCKSPort: Int? }
        let routing = try JSONDecoder().decode(Routing.self, from: enrollmentData)
        return try await activate(
            paths: paths, enrollment: enrollment, loopbackSOCKSPort: routing.loopbackSOCKSPort)
    }

    static func activate(
        paths: StoragePaths, configuration: MacSyncConfiguration,
        credentials: any SyncCredentialStore, transport: any AsyncSyncTransport,
        afterInstall: @escaping @Sendable (Database) throws -> Void = { _ in }
    ) async throws -> Self {
        let enrollment = try configuration.enrollment()
        guard transport.binding == configuration.binding,
            transport.deviceID == configuration.deviceID
        else {
            throw MacSyncError.configurationChanged
        }
        try paths.createDirectories()
        let lease = try await MacSyncLease.wait(paths: paths)
        defer { withExtendedLifetime(lease) {} }
        let previous = try MacSyncConfiguration.bytes(paths: paths)
        let blobDirectory = paths.assetsDirectory.appendingPathComponent("sync")
        let hadBlobDirectory = FileManager.default.fileExists(atPath: blobDirectory.path)
        let priorBlobs = Set(
            hadBlobDirectory
                ? try FileManager.default.contentsOfDirectory(atPath: blobDirectory.path) : [])
        if let existing = try MacSyncConfiguration.load(paths: paths) {
            guard existing.endpoint == configuration.endpoint,
                existing.loopbackSOCKSPort == configuration.loopbackSOCKSPort,
                existing.binding == configuration.binding,
                existing.deviceID == configuration.deviceID
            else { throw MacSyncError.configurationChanged }
        }
        let local = try Store(paths: paths)
        let bound = try await local.reader.read { try StoreSync.binding(in: $0) }
        guard bound == nil || bound == configuration.binding else {
            throw SyncBindingError.mismatch
        }
        let credential: @Sendable () throws -> String = { try credentials.read(for: enrollment) }
        let baseline = try await transport.importBaseline(
            credential: credential, requiringGeneratedProcessingContract: true, summaryOnly: true)
        try Task.checkCancellation()
        let count = try await local.reader.read { try Capture.fetchCount($0) }
        let handoff: StoreSyncImportHandoff?
        if bound == nil, count > 0 {
            handoff = try await StoreSyncImportHandoff(
                store: local, transport: transport, credential: credential)
        } else {
            guard bound != nil || (baseline.deviceSequences[configuration.deviceID] ?? 0) == 0
            else {
                throw SyncError.wrongDevice
            }
            handoff = nil
        }
        let store: Store
        do {
            store = try Store(
                paths: paths, syncBinding: configuration.binding, imported: handoff,
                deviceID: configuration.deviceID,
                commitConfiguration: { db in
                    if bound == nil && handoff == nil {
                        guard try Capture.fetchCount(db) == 0 else {
                            throw SyncBindingError.enrollmentRequiresEmptyLibrary
                        }
                    }
                    try configuration.install(paths: paths)
                    try afterInstall(db)
                })
        } catch {
            try MacSyncConfiguration.restore(previous, paths: paths)
            if bound == nil, try await local.reader.read({ try StoreSync.binding(in: $0) }) == nil,
                FileManager.default.fileExists(atPath: blobDirectory.path)
            {
                let added = Set(
                    try FileManager.default.contentsOfDirectory(atPath: blobDirectory.path)
                ).subtracting(priorBlobs)
                for name in added {
                    try FileManager.default.removeItem(
                        at: blobDirectory.appendingPathComponent(name))
                }
                if !hadBlobDirectory,
                    try FileManager.default.contentsOfDirectory(atPath: blobDirectory.path).isEmpty
                {
                    try FileManager.default.removeItem(at: blobDirectory)
                }
            }
            throw error
        }
        return Self(
            store: store,
            runtime: MacSyncRuntime(
                store: store, configuration: configuration, transport: transport,
                credential: credential),
            configuration: configuration)
    }

    public static func setEnabled(_ enabled: Bool, paths: StoragePaths) async throws {
        let lease = try await MacSyncLease.wait(paths: paths)
        defer { withExtendedLifetime(lease) {} }
        guard var configuration = try MacSyncConfiguration.load(paths: paths) else {
            throw MacSyncError.configurationRequired
        }
        let local = try Store(paths: paths)
        guard
            try await local.reader.read({ try StoreSync.binding(in: $0) }) == configuration.binding
        else {
            throw MacSyncError.configurationRequired
        }
        _ = try Store(
            paths: paths, syncBinding: configuration.binding, deviceID: configuration.deviceID)
        configuration.enabled = enabled
        try configuration.install(paths: paths)
    }
}
