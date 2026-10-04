import SwiftUI

public struct CapdTagChip: View {
    private let tag: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var textSize

    public init(_ tag: String) { self.tag = tag }

    public var body: some View {
        let palette = CapdPalette(
            colorScheme: colorScheme, increasedContrast: contrast == .increased)
        let label = Text(tag.map(String.init).joined(separator: "\u{200B}"))
            .font(CapdTypography.metadata)
            .foregroundStyle(palette.textSecondary)
            .accessibilityLabel(tag)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, CapdSpacing.small)
            .padding(.vertical, 3)
        if textSize.isAccessibilitySize {
            label
                .background(palette.raised, in: RoundedRectangle(cornerRadius: CapdRadius.row))
                .overlay(
                    RoundedRectangle(cornerRadius: CapdRadius.row).strokeBorder(
                        palette.border, lineWidth: 1))
        } else {
            label.background(palette.raised, in: Capsule())
                .overlay(Capsule().strokeBorder(palette.border, lineWidth: 1))
        }
    }
}
