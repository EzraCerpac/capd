import CapdMobile
import Foundation

enum MobileEnvironment {
    static let groupID = "group.dev.jxd.capd.iphone.prototype"

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

    static func adapter() -> any MobileSyncAdapter {
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
        return LocalOnlySyncAdapter()
    }

    static func store() throws -> MobileStore {
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: groupID)
        else {
            throw EnvironmentError.sharedContainerUnavailable
        }
        return try MobileStore(url: container.appendingPathComponent("Library/captures.sqlite"))
    }

    enum EnvironmentError: Error, LocalizedError {
        case sharedContainerUnavailable
        var errorDescription: String? {
            "The shared library is unavailable. Check the app group configuration in Xcode."
        }
    }
}
