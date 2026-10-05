import CapdDesignSystem
import SwiftUI

public struct WebsiteIconTile: View {
    private let identity: WebsiteIconIdentity?
    private let cache: WebsiteIconCache
    private let load: WebsiteIconCache.Loader?
    private let symbol: String
    private let tint: Color
    private let size: CGFloat
    @State private var image: WebsiteIconImage?
    @State private var loadedIdentity: WebsiteIconIdentity?

    public init(
        identity: WebsiteIconIdentity?, cache: WebsiteIconCache,
        load: WebsiteIconCache.Loader? = nil,
        fallbackSymbol: String = "link", fallbackTint: Color = .blue, size: CGFloat = 28
    ) {
        self.identity = identity
        self.cache = cache
        self.load = load
        symbol = fallbackSymbol
        tint = fallbackTint
        self.size = size
    }

    public var body: some View {
        Group {
            if let identity, let image, loadedIdentity == identity {
                Image(decorative: image.image, scale: 1)
                    .resizable().interpolation(.high).scaledToFit()
                    .padding(size * 0.12).frame(width: size, height: size)
                    .background(
                        .white,
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            } else {
                CapdIconTile(symbol: symbol, tint: tint, size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .task(id: identity) {
            image = nil
            loadedIdentity = nil
            guard let identity, let loaded = await cache.image(for: identity, load: load),
                !Task.isCancelled
            else {
                return
            }
            loadedIdentity = identity
            image = loaded
        }
    }
}
