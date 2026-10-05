import CapdMobile
import CapdSync
import Foundation

enum MobileEnvironment {
    static let groupID = "group.dev.jxd.capd.iphone.prototype"

    static var holdsSyntheticOfflineWork: Bool {
        #if DEBUG
            return ProcessInfo.processInfo.arguments.contains("--capd-offline-fixture")
        #else
            return false
        #endif
    }

    static func syncPolicy() -> AutomaticSyncPolicy {
        #if DEBUG && targetEnvironment(simulator)
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--capd-synthetic-sync"),
                let index = arguments.firstIndex(of: "--capd-sync-poll-seconds"),
                arguments.indices.contains(index + 1),
                let seconds = Double(arguments[index + 1]), (0.25...30).contains(seconds)
            {
                return AutomaticSyncPolicy(foregroundPullInterval: seconds)
            }
        #endif
        return AutomaticSyncPolicy()
    }

    static func syntheticAdapter() -> (any MobileSyncAdapter)? {
        #if DEBUG && targetEnvironment(simulator)
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--capd-synthetic-sync"),
                let index = arguments.firstIndex(of: "--capd-reference-port"),
                arguments.indices.contains(index + 1),
                let port = UInt16(arguments[index + 1]), port > 0
            {
                return ReferenceSyncAdapter(port: port)
            }
        #endif
        return nil
    }

    static func adapter() -> any MobileSyncAdapter { syntheticAdapter() ?? LocalOnlySyncAdapter() }

    static let credentials = KeychainSyncCredentialStore(service: "dev.jxd.capd.phone.sync")

    static func store() throws -> MobileStore {
        try session(role: .shareExtension).store
    }

    static func root() throws -> URL {
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupID)
        else {
            throw EnvironmentError.sharedContainerUnavailable
        }
        return container
    }

    static func session(role: MobileLibrarySession.Role) throws -> MobileLibrarySession {
        try MobileLibrarySession.open(root: root(), role: role, credentials: credentials)
    }

    static func selectedDatabaseURL() throws -> URL {
        let container = try root()
        return try MobileLibraryAccess.selected(in: container).databaseURL(in: container)
    }

    enum EnvironmentError: Error, LocalizedError {
        case sharedContainerUnavailable
        var errorDescription: String? {
            "The shared library is unavailable. Check the app group configuration in Xcode."
        }
    }
}
