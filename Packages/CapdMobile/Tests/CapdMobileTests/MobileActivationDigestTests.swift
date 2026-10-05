import Foundation
import GRDB
import Testing

@testable import CapdMobile

@Test func sourceStateDigestStreamsOrderedBinaryRowsAndKeepsDuplicateMultiplicity() throws {
    func fixture(reverse: Bool) throws -> DatabaseQueue {
        let database = try DatabaseQueue()
        try database.write { db in
            try db.execute(sql: "CREATE TABLE sync_digest (id INTEGER PRIMARY KEY, payload BLOB)")
            try db.execute(sql: "CREATE TABLE sync_unkeyed (value)")
            let ids = reverse ? Array((0..<2_048).reversed()) : Array(0..<2_048)
            for id in ids {
                var payload = Data(repeating: UInt8(id % 256), count: 4_096)
                payload[0] = UInt8(id / 256)
                try db.execute(
                    sql: "INSERT INTO sync_digest VALUES (?, ?)", arguments: [id, payload])
            }
            let values: [DatabaseValue] = [
                .null, Int64(1).databaseValue, Double(1).databaseValue,
                "1".databaseValue, Data([0, 255]).databaseValue, "1".databaseValue,
            ]
            for value in reverse ? values.reversed() : values {
                try db.execute(sql: "INSERT INTO sync_unkeyed VALUES (?)", arguments: [value])
            }
        }
        return database
    }
    let original = try fixture(reverse: false)
    let reordered = try fixture(reverse: true)
    let digest = try MobileLibraryActivation.stateDigest(original)
    #expect(digest.count == 64)
    #expect(try MobileLibraryActivation.stateDigest(reordered) == digest)
    try reordered.write { db in
        try db.execute(
            sql:
                "DELETE FROM sync_unkeyed WHERE rowid=(SELECT MAX(rowid) FROM sync_unkeyed WHERE value='1')"
        )
    }
    #expect(try MobileLibraryActivation.stateDigest(reordered) != digest)
    try original.write { db in
        try db.execute(
            sql: "UPDATE sync_digest SET payload=? WHERE id=0", arguments: [Data([0, 255])])
    }
    #expect(try MobileLibraryActivation.stateDigest(original) != digest)
}

@Test func sourceStateDigestPreservesTypesBoundariesAndEmbeddedNullText() throws {
    let database = try DatabaseQueue()
    try database.write { db in
        try db.execute(sql: "CREATE TABLE sync_digest (first, second)")
        try db.execute(sql: "INSERT INTO sync_digest VALUES (?, ?)", arguments: ["a\0b", "c"])
    }
    let digest = try MobileLibraryActivation.stateDigest(database)
    try database.write { db in
        try db.execute(sql: "UPDATE sync_digest SET first=?, second=?", arguments: ["a", "b\0c"])
    }
    #expect(try MobileLibraryActivation.stateDigest(database) != digest)
    try database.write { db in
        try db.execute(
            sql: "UPDATE sync_digest SET first=?, second=?", arguments: [Data("a\0b".utf8), "c"])
    }
    #expect(try MobileLibraryActivation.stateDigest(database) != digest)
    try database.write { db in
        try db.execute(sql: "UPDATE sync_digest SET first=?, second=?", arguments: ["a\0b", "c"])
    }
    #expect(try MobileLibraryActivation.stateDigest(database) == digest)
    try database.write { db in
        try db.execute(sql: "ALTER TABLE sync_digest ADD COLUMN extra")
    }
    #expect(try MobileLibraryActivation.stateDigest(database) != digest)
}
