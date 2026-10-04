import CapdSystemIntegration
import CoreSpotlight
import Foundation

@MainActor
final class AppSystemIntegration {
    let bridge = CaptureSystemBridge()

    init() { bridge.install() }

    @discardableResult
    func receive(_ url: URL) -> Bool {
        guard let route = CaptureRoute(url: url) else { return false }
        bridge.receive(route)
        return true
    }

    @discardableResult
    func receive(_ activity: NSUserActivity) -> Bool {
        guard let route = CaptureRoute(spotlightActivity: activity) else { return false }
        bridge.receive(route)
        return true
    }
}
