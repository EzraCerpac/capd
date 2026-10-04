import ArgumentParser
import CapdKit
import Foundation

struct Sync: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect, run, activate or pause Mac library sync.",
        subcommands: [Status.self, Run.self, Activate.self, Deactivate.self, Resume.self])

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show local sync state without network access.")
        func run() throws {
            let session = try openLibrarySession()
            let status = blocking {
                if let runtime = session.runtime { return await runtime.status() }
                return MacSyncStatus.localOnly
            }
            print(try jsonString(status))
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Synchronize saved changes and remote captures.")
        func run() throws {
            let session = try openLibrarySession()
            guard let runtime = session.runtime else {
                throw CLIError(message: "Sync is not configured for this library.", code: 3)
            }
            let result = blocking { await runtime.sync(within: .seconds(35)) }
            print(try jsonString(result))
            if result.phase == .offline || result.phase == .attention {
                throw CLIError(message: result.issue ?? "Sync needs attention.", code: 3)
            }
        }
    }

    struct Activate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Validate an enrollment and atomically activate a prepared Mac library.",
            discussion:
                "Stop other library writers first. The matching device credential must already exist in the Capd sync Keychain service."
        )
        @Option(help: "Path to public enrollment JSON: endpoint, binding and deviceID.")
        var enrollment: String
        func run() throws {
            let data = try Data(contentsOf: URL(fileURLWithPath: enrollment))
            let paths = try StoragePaths.live
            let result = blocking {
                do {
                    _ = try await MacLibrarySession.activate(paths: paths, enrollmentData: data)
                    return Result<Void, any Error>.success(())
                } catch { return .failure(error) }
            }
            try result.get()
            print("Sync activated for the prepared Mac library.")
        }
    }

    struct Deactivate: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Pause networking while retaining the bound library and queued changes.")
        func run() throws { try Sync.setEnabled(false) }
    }

    struct Resume: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Resume networking for the existing bound library.")
        func run() throws { try Sync.setEnabled(true) }
    }

    private static func setEnabled(_ enabled: Bool) throws {
        let paths = try StoragePaths.live
        let result = blocking {
            do {
                try await MacLibrarySession.setEnabled(enabled, paths: paths)
                return Result<Void, any Error>.success(())
            } catch { return .failure(error) }
        }
        try result.get()
        print(
            enabled
                ? "Sync networking resumed."
                : "Sync networking paused. The library remains bound; saved changes stay queued.")
    }
}
