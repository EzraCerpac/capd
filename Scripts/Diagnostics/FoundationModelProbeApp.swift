import Darwin
import SwiftUI

@main
struct ModelProbeApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Synthetic model diagnostics")
                .task {
                    if #available(iOS 26.4, *) { await ModelProbe.main() }
                    print("PROBE_FINISHED")
                    fflush(stdout)
                    _exit(0)
                }
        }
    }
}
