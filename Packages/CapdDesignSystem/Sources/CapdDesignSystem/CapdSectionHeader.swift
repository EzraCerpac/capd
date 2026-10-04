import SwiftUI

public struct CapdSectionHeader: View {
    private let title: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ title: String) { self.title = title }

    public var body: some View {
        let palette = CapdPalette(
            colorScheme: colorScheme, increasedContrast: contrast == .increased)
        Text(title)
            .font(CapdTypography.section)
            .foregroundStyle(palette.textSecondary)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, CapdSpacing.row)
            .background(palette.background)
    }
}
