import CryptoKit
import Foundation
import GRDB

public struct MacDiscoveryCapture: Sendable {
    public let localID: Int64
    public let id: UUID
    public let title: String
    public let manualTags: [String]
    public let revision: Int64
}

public struct MacDiscoverySnapshot: Sendable {
    public let libraryID: UUID
    public let captures: [MacDiscoveryCapture]

    /// A complete bounded read-only snapshot. Never creates mappings, a sync client,
    /// credentials, or a missing library. Bound identities come from the projection.
    public static func load(paths: StoragePaths, localLibraryID: UUID) throws -> Self {
        let store = try MacLibrarySession.readOnlyStore(paths: paths)
        return try store.reader.read { db in
            let binding = try StoreSync.binding(in: db)
            let libraryID = binding?.libraryID ?? localLibraryID
            let captures = try Capture.order(Capture.CodingKeys.id).fetchCursor(db)
            let hasMappings = try db.tableExists("sync_capture_ids")
            var entries: [UUID: (capture: MacDiscoveryCapture, directlyCanonical: Bool)] = [:]
            while let capture = try captures.next() {
                guard let localID = capture.id else { throw MacDiscoveryError.invalidIdentity }
                let mapped =
                    hasMappings
                    ? try String.fetchOne(
                        db,
                        sql: "SELECT global_id FROM sync_capture_ids WHERE local_id=?",
                        arguments: [localID]) : nil
                let id: UUID
                if let mapped, let value = UUID(uuidString: mapped) {
                    id = value
                } else {
                    guard binding == nil else { throw MacDiscoveryError.invalidIdentity }
                    let digest = Array(
                        SHA256.hash(data: Data("\(libraryID.uuidString):\(localID)".utf8)))
                    id = UUID(
                        uuid: (
                            digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
                            digest[6], digest[7], digest[8], digest[9], digest[10], digest[11],
                            digest[12], digest[13], digest[14], digest[15]
                        ))
                }
                let record = binding == nil ? nil : try StoreSync.visible(db, id: id)
                guard binding == nil || record != nil else {
                    throw MacDiscoveryError.invalidIdentity
                }
                if record?.deleted == true { continue }
                let canonicalID = record?.id ?? id
                let directlyCanonical = record?.id == id
                if let previous = entries[canonicalID],
                    previous.directlyCanonical || !directlyCanonical
                {
                    continue
                }
                let manual =
                    record?.manualTags
                    ?? (capture.tagsVersion == Capture.pinnedTagsVersion ? capture.tagList : [])
                let title = record == nil ? capture.title : record?.source.title
                let host = record == nil ? capture.host : record?.source.host
                let url = record == nil ? capture.url : record?.source.url
                let entry = MacDiscoveryCapture(
                    localID: localID, id: canonicalID,
                    title: title ?? host ?? url.flatMap(URL.init(string:))?.host ?? "Saved capture",
                    manualTags: manual,
                    revision: record?.revision ?? 0)
                entries[canonicalID] = (entry, directlyCanonical)
                guard entries.count <= 1000 else { throw MacDiscoveryError.snapshotTooLarge }
            }
            return Self(
                libraryID: libraryID,
                captures: entries.values.map(\.capture).sorted { $0.localID < $1.localID })
        }
    }
}

public enum MacDiscoveryError: Error, LocalizedError {
    case snapshotTooLarge, invalidIdentity
    public var errorDescription: String? {
        switch self {
        case .snapshotTooLarge: "System search supports libraries of up to 1,000 captures."
        case .invalidIdentity: "System search could not validate the library identities."
        }
    }
}
