import CapdSyncServerHost
import Foundation

@main
struct CapdSyncServerCommand {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] {
            print(
                """
                Usage: capd-sync-server --config PATH --data-dir DIRECTORY [--port PORT]
                Loopback-only HTTP listener (default port 8080; 0 selects an ephemeral port).
                Requires an HTTPS reverse proxy before remote use. No live-library defaults.
                """)
            return
        }
        do {
            var options: [String: String] = [:]
            guard args.count % 2 == 0 else { throw HostError.invalidArguments }
            for offset in stride(from: 0, to: args.count, by: 2) {
                let name = args[offset]
                guard ["--config", "--data-dir", "--port"].contains(name),
                    options.updateValue(args[offset + 1], forKey: name) == nil,
                    !args[offset + 1].isEmpty
                else { throw HostError.invalidArguments }
            }
            guard let config = options["--config"], let directory = options["--data-dir"],
                let port = Int(options["--port"] ?? "8080"), (0...65_535).contains(port)
            else { throw HostError.invalidArguments }
            try await HostHTTP.run(
                configurationURL: URL(fileURLWithPath: config),
                dataDirectory: URL(fileURLWithPath: directory), port: port)
        } catch {
            // Never render underlying errors: they may contain configuration or library bytes.
            FileHandle.standardError.write(
                Data(
                    "capd-sync-server: startup failed; check arguments, configuration and storage binding\n"
                        .utf8))
            exit(1)
        }
    }
}
