import CapdMCP
import Foundation

@main struct CapdMCPStdio {
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            var values: [String: String] = [:]
            guard args.count % 2 == 0 else { throw MCPFailure.invalidArguments }
            for offset in stride(from: 0, to: args.count, by: 2) {
                guard ["--credential-file", "--socket"].contains(args[offset]),
                    values.updateValue(args[offset + 1], forKey: args[offset]) == nil
                else { throw MCPFailure.invalidArguments }
            }
            guard let path = values["--credential-file"], path.hasPrefix("/"),
                let socket = values["--socket"], socket.hasPrefix("/")
            else { throw MCPFailure.invalidArguments }
            let bridge = try MCPStdioBridge(
                credentialURL: URL(fileURLWithPath: path), socketURL: URL(fileURLWithPath: socket))
            let input = MCPFrameReader(input: .standardInput)
            while let line = try input.next() {
                if let output = bridge.forward(line) {
                    FileHandle.standardOutput.write(output + Data([10]))
                }
            }
        } catch {
            FileHandle.standardError.write(Data("capd-mcp-stdio: bounded bridge failed\n".utf8))
            exit(1)
        }
    }
}
