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
