import Foundation

public struct SyncEnrollmentDraft: Sendable {
    public var address = ""
    public var serviceID = ""
    public var libraryID = ""
    public var deviceID = ""
    public var credential = ""

    public init() {}

    public func validate() throws -> SyncEnrollment {
        guard let endpoint = URL(string: address), let service = UUID(uuidString: serviceID),
            let library = UUID(uuidString: libraryID), let device = UUID(uuidString: deviceID),
            [service, library, device].allSatisfy({
                $0 != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            })
        else { throw SyncConnectionError.invalidEndpoint }
        try SyncCredentialValidation.check(credential)
        return try SyncEnrollment(
            endpoint: endpoint, binding: SyncLibraryBinding(libraryID: library, serviceID: service),
            deviceID: device)
    }

    /// Saves and reopens a synthetic capture only in disposable storage. No network or Keychain use.
    public func verifyTemporarySetup() throws -> Int {
        let enrollment = try validate()
        let credentials = MemorySyncCredentialStore()
        try credentials.save(credential, for: enrollment)
        defer { try? credentials.remove(for: enrollment) }
        guard try credentials.read(for: enrollment) == credential else {
            throw SyncConnectionError.credentialUnavailable
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-setup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("preview.sqlite")
        let blobs = root.appendingPathComponent("blobs")
        do {
            let client = try SyncClient(
                databaseURL: database, blobDirectory: blobs, deviceID: enrollment.deviceID,
                binding: enrollment.binding)
            let capture = SharedCapture(
                source: CaptureSource(kind: .text, selection: "Synthetic setup preview"))
            try client.enqueue(captureID: capture.id, mutation: .create(capture))
        }
        let reopened = try SyncClient(
            databaseURL: database, blobDirectory: blobs, binding: enrollment.binding)
        guard reopened.deviceID == enrollment.deviceID else { throw SyncError.wrongDevice }
        return try reopened.pendingOperations().count
    }
}

/// Live enrollment stays closed while migration and its cutover authorization are pending.
public enum SyncEnrollmentActivation {
    public static func requireReady() throws {
        throw SyncConnectionError.enrollmentDisabled
    }
}
