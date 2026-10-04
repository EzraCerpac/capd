import SwiftUI

public struct CapdCanvas: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    public init() {}

    public func body(content: Content) -> some View {
        let palette = CapdPalette(
            colorScheme: colorScheme, increasedContrast: contrast == .increased)
        #if os(iOS)
            content
                .scrollContentBackground(.hidden)
                .background(palette.background)
                .tint(palette.accent)
                .toolbarBackground(palette.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
        #else
            content.background(palette.background).tint(
                palette.accent)
        #endif
    }
}

extension View {
    public func capdCanvas() -> some View { modifier(CapdCanvas()) }
}
