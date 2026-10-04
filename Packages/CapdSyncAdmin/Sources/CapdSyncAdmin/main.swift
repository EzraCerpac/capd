import CapdSync
import CapdSyncAdministration
import Foundation

@main
struct SnapshotCommand {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            if args == ["--help"] {
                print(
                    """
                    Usage: capd-sync-admin preview|import --data-dir DIRECTORY --service-id UUID \
                    --library-id UUID --snapshot FILE --assets DIRECTORY --review FILE \
                    [--reviewed-sha256 SHA256]
                    Offline existing authority only. Preview exclusively creates the review file;
                    import requires its reviewed SHA-256. No HTTP listener or device enrollment.
                    Counts use maximum-known lower bounds and are never exact.
                    """)
                return
            }
            guard let action = args.first, ["preview", "import"].contains(action),
                args.count % 2 == 1
            else { throw AdministrationError.invalidArguments }
            var options: [String: String] = [:]
            let allowed =
                [
                    "--data-dir", "--service-id", "--library-id", "--snapshot", "--assets",
                    "--review",
                ]
                + (action == "import" ? ["--reviewed-sha256"] : [])
            for index in stride(from: 1, to: args.count, by: 2) {
                guard allowed.contains(args[index]), !args[index + 1].isEmpty,
                    options.updateValue(args[index + 1], forKey: args[index]) == nil
                else { throw AdministrationError.invalidArguments }
            }
            guard options.count == allowed.count,
                let service = UUID(uuidString: options["--service-id"]!),
                let library = UUID(uuidString: options["--library-id"]!)
            else { throw AdministrationError.invalidArguments }
            let host = try SnapshotAdministration(
                dataDirectory: URL(fileURLWithPath: options["--data-dir"]!),
                binding: SyncLibraryBinding(libraryID: library, serviceID: service))
            let snapshot = URL(fileURLWithPath: options["--snapshot"]!)
            let assets = URL(fileURLWithPath: options["--assets"]!)
            let review = URL(fileURLWithPath: options["--review"]!)
            if action == "preview" {
                let result = try host.preview(snapshotURL: snapshot, assetDirectory: assets)
                let hash = try SnapshotAdministration.writeReview(result, to: review)
                print("review-sha256 \(hash)")
                print(
                    "items \(result.preview.items.count); feed rows to expire \(result.preview.feedRowsToExpire); counts are lower bounds"
                )
            } else {
                let receipt = try host.importSnapshot(
                    snapshotURL: snapshot, assetDirectory: assets, reviewURL: review,
                    reviewedSHA256: options["--reviewed-sha256"]!)
                FileHandle.standardOutput.write(
                    try SnapshotAdministration.encode(receipt) + Data("\n".utf8))
            }
        } catch AdministrationError.authorityNeedsRecovery,
            SyncServer.SnapshotPreviewError.authorityNeedsRecovery
        {
            FileHandle.standardError.write(
                Data(
                    "capd-sync-admin: refused; stop the host and checkpoint or recover the authority before preview or import\n"
                        .utf8))
            exit(1)
        } catch {
            FileHandle.standardError.write(
                Data(
                    "capd-sync-admin: refused; check scope, storage lock, assets and reviewed artifact\n"
                        .utf8))
            exit(1)
        }
    }
}
