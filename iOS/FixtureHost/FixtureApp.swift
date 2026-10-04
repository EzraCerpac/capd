import SwiftUI
import UIKit

@main
struct FixtureApp: App {
    @State private var sharing = false
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 24) {
                Text("Synthetic share fixture").font(.title2)
                Button("Share fixture text") { sharing = true }
                if let raw = ProcessInfo.processInfo.environment["CAPD_FIXTURE_ROUTE"],
                    let url = URL(string: raw), url.scheme == "capd"
                {
                    Button("Open synthetic capture route") { UIApplication.shared.open(url) }
                }
            }.sheet(isPresented: $sharing) { FixtureShareSheet() }
        }
    }
}

struct FixtureShareSheet: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: ["Synthetic external source: marsh bird survey."],
            applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
