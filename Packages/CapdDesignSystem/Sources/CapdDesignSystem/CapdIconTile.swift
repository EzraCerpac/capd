import SwiftUI

public struct CapdIconTile: View {
    private let symbol: String
    private let tint: Color
    private let size: CGFloat

    public init(symbol: String, tint: Color, size: CGFloat = 28) {
        self.symbol = symbol
        self.tint = tint
        self.size = size
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}
