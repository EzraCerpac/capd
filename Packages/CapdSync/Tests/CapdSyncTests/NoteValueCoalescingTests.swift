import Foundation
import Testing

@testable import CapdSync

struct NoteValueCoalescingTests {
    @Test(arguments: [Optional("Same note"), nil, Optional("")])
    func identicalConcurrentValuesAreAccepted(value: String?) throws {
        let fixture = try NoteFixture()
        defer { fixture.clean() }
        let first = try fixture.write(value, base: fixture.base)
        let accepted = try #require(first.capture)
        let second = try fixture.write(value, base: fixture.base)
        let coalesced = try #require(second.capture)
        #expect(second.outcome == .accepted)
        #expect(coalesced.note == value)
        #expect(coalesced.noteConflicts.isEmpty)
        #expect(coalesced.noteRevision == accepted.noteRevision)
        #expect(coalesced.noteOperationID == second.operationID)
    }

    @Test func identicalConflictCandidatesKeepDistinctVariantsAndIndependentFields() throws {
        let fixture = try NoteFixture()
        defer { fixture.clean() }
        _ = try fixture.write("A", base: fixture.base)
        let second = try fixture.write("B", base: fixture.base)
        #expect(second.outcome == .noteConflict)
        let conflict = try #require(second.capture)
        #expect(Set(conflict.noteConflicts.compactMap(\.value)) == ["A", "B"])
        for value in ["B", "A"] {
            let repeated = try fixture.write(value, base: fixture.base, rating: 4)
            let capture = try #require(repeated.capture)
            #expect(repeated.outcome == .accepted)
            #expect(capture.noteConflicts == conflict.noteConflicts)
            #expect(capture.note == conflict.note)
            #expect(capture.noteOperationID == conflict.noteOperationID)
            #expect(capture.noteRevision == conflict.noteRevision)
            #expect(capture.rating == 4)
        }
    }

    @Test func duplicateCandidateDoesNotInvalidateReviewedResolution() throws {
        let fixture = try NoteFixture()
        defer { fixture.clean() }
        _ = try fixture.write("A", base: fixture.base)
        let conflict = try #require(fixture.write("B", base: fixture.base).capture)
        _ = try fixture.write("B", base: fixture.base)
        let receipt = try fixture.write(
            "A", base: conflict.revision, resolving: conflict.noteConflicts.map(\.operationID))
        #expect(receipt.outcome == .accepted)
        #expect(receipt.capture?.note == "A")
        #expect(receipt.capture?.noteConflicts.isEmpty == true)
    }

    @Test func staleAndPartialKnownValueResolutionsRetainUnseenVariants() throws {
        let fixture = try NoteFixture()
        defer { fixture.clean() }
        _ = try fixture.write("A", base: fixture.base)
        let observed = try #require(fixture.write("B", base: fixture.base).capture)
        let distinct = try fixture.write("C", base: fixture.base)
        #expect(distinct.outcome == .noteConflict)
        let current = try #require(distinct.capture)
        #expect(Set(current.noteConflicts.compactMap(\.value)) == ["A", "B", "C"])
        let stale = try fixture.write(
            "B", base: observed.revision, resolving: observed.noteConflicts.map(\.operationID))
        #expect(stale.outcome == .accepted)
        #expect(stale.capture?.noteConflicts == current.noteConflicts)
        #expect(stale.capture?.noteRevision == current.noteRevision)
        let partial = try fixture.write(
            "A", base: try #require(stale.capture).revision,
            resolving: [try #require(current.noteConflicts.first).operationID])
        #expect(partial.outcome == .accepted)
        #expect(partial.capture?.noteConflicts == current.noteConflicts)
        let resolution = try fixture.write(
            "All reviewed", base: try #require(partial.capture).revision,
            resolving: current.noteConflicts.map(\.operationID))
        #expect(resolution.outcome == .accepted)
        #expect(resolution.capture?.note == "All reviewed")
        #expect(resolution.capture?.noteConflicts.isEmpty == true)
    }

    @Test func coalescedPredecessorProvesQueuedSuccessorCausality() throws {
        let fixture = try NoteFixture()
        defer { fixture.clean() }
        _ = try fixture.write("A", base: fixture.base)
        let device = UUID()
        let predecessor = try fixture.write("A", base: fixture.base, device: device)
        #expect(predecessor.outcome == .accepted)
        let successor = try fixture.write(
            "Next local note", base: fixture.base, device: device, sequence: 2,
            predecessor: predecessor.operationID)
        #expect(successor.outcome == .accepted)
        #expect(successor.capture?.note == "Next local note")
        #expect(successor.capture?.noteConflicts.isEmpty == true)
    }

    @Test(arguments: [false, true])
    func duplicateCreateProvesOnlyItsCoalescedNoteCausality(concurrentEdit: Bool) throws {
        let fixture = try NoteFixture()
        defer { fixture.clean() }
        let authority = try #require(fixture.write("A", base: fixture.base).capture)
        let duplicate = SharedCapture(source: authority.source, note: "A")
        let device = UUID()
        let predecessor = try fixture.server.apply(
            SyncOperation(
                deviceID: device, sequence: 1, captureID: duplicate.id, baseRevision: 0,
                mutation: .create(duplicate)))
        #expect(predecessor.outcome == .accepted)
        #expect(predecessor.capture?.id == authority.id)
        #expect(predecessor.capture?.noteOperationID == predecessor.operationID)
        #expect(predecessor.capture?.noteRevision == authority.noteRevision)
        if concurrentEdit {
            _ = try fixture.write(
                "Concurrent note", base: try #require(predecessor.capture).revision)
        }
        let successor = try fixture.server.apply(
            SyncOperation(
                deviceID: device, sequence: 2, captureID: duplicate.id, baseRevision: 0,
                predecessorID: predecessor.operationID,
                mutation: .edit(CaptureEdit(note: NoteEdit("Next local note")))))
        #expect(successor.outcome == (concurrentEdit ? .noteConflict : .accepted))
        if concurrentEdit {
            #expect(
                Set(try #require(successor.capture).noteConflicts.compactMap(\.value))
                    == ["Concurrent note", "Next local note"])
        } else {
            #expect(successor.capture?.note == "Next local note")
            #expect(successor.capture?.noteConflicts.isEmpty == true)
        }
    }
}

private struct NoteFixture {
    let root: URL
    let server: SyncServer
    let captureID: UUID
    let base: Int64

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "capd-note-coalescing-\(UUID())")
        server = try SyncServer(
            databaseURL: root.appendingPathComponent("server.sqlite"),
            blobDirectory: root.appendingPathComponent("blobs"))
        let capture = SharedCapture(
            source: CaptureSource(
                kind: .text, contentHash: "synthetic note", selection: "Synthetic note fixture"),
            note: "Original")
        captureID = capture.id
        let created = try server.apply(
            SyncOperation(
                deviceID: UUID(), sequence: 1, captureID: capture.id, baseRevision: 0,
                mutation: .create(capture)))
        base = try #require(created.capture).revision
    }

    func clean() { try? FileManager.default.removeItem(at: root) }

    func write(
        _ value: String?, base: Int64, resolving: [UUID] = [], rating: Int? = nil,
        device: UUID = UUID(), sequence: Int64 = 1, predecessor: UUID? = nil
    ) throws -> SyncReceipt {
        try server.apply(
            SyncOperation(
                deviceID: device, sequence: sequence, captureID: captureID, baseRevision: base,
                predecessorID: predecessor,
                mutation: .edit(
                    CaptureEdit(note: NoteEdit(value, resolving: resolving), rating: rating))))
    }
}
