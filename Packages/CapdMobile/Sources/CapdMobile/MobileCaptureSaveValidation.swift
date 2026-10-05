import CapdSync
import Foundation
import GRDB

public enum MobileCaptureSaveError: Error, LocalizedError, Equatable {
    case deletedCapture

    public var errorDescription: String? {
        "This source was previously deleted and can’t be saved again here. Choose a different source."
    }
}

enum MobileCaptureSaveValidation {
    static func validate(_ record: SharedCapture, in db: Database) throws {
        let canonical =
            try String.fetchOne(
                db, sql: "SELECT canonical FROM sync_aliases WHERE id=? COLLATE NOCASE",
                arguments: [record.id.uuidString]) ?? record.id.uuidString
        let rows = try Data.fetchCursor(
            db,
            sql: """
                SELECT payload FROM sync_visible
                WHERE id=? COLLATE NOCASE
                    OR json_extract(CAST(payload AS TEXT), '$.source.contentHash')=?
                """, arguments: [canonical, record.source.contentHash])
        while let payload = try rows.next() {
            let current = try JSONDecoder().decode(SharedCapture.self, from: payload)
            guard current.deleted else { continue }
            let sameSource =
                current.source.contentHash == record.source.contentHash
                && current.source.kind == record.source.kind
                && (record.source.kind != .image || current.source.blob == record.source.blob)
            if current.id.uuidString.caseInsensitiveCompare(canonical) == .orderedSame || sameSource
            {
                throw MobileCaptureSaveError.deletedCapture
            }
        }
    }
}
