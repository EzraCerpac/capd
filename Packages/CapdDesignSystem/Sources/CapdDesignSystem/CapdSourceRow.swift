import SwiftUI

public struct CapdSourceRow: View {
    private let title: String
    private let metadata: String
    private let snippet: String
    private let symbol: String
    private let tint: Color
    private let tags: [String]
    private let status: String?
    private let customIcon: ((CGFloat) -> AnyView)?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var textSize
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 28

    public init(
        title: String, metadata: String, snippet: String, symbol: String, tint: Color,
        tags: [String] = [], status: String? = nil
    ) {
        self.title = title
        self.metadata = metadata
        self.snippet = snippet
        self.symbol = symbol
        self.tint = tint
        self.tags = tags
        self.status = status
        customIcon = nil
    }

    public init(
        title: String, metadata: String, snippet: String, symbol: String, tint: Color,
        tags: [String] = [], status: String? = nil,
        @ViewBuilder icon: @escaping (CGFloat) -> some View
    ) {
        self.title = title
        self.metadata = metadata
        self.snippet = snippet
        self.symbol = symbol
        self.tint = tint
        self.tags = tags
        self.status = status
        customIcon = { AnyView(icon($0)) }
    }

    public var body: some View {
        Group {
            if textSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: CapdSpacing.row) {
                    icon
                    text
                }
            } else {
                HStack(alignment: .top, spacing: CapdSpacing.control) {
                    icon
                    text
                }
            }
        }
        .padding(.vertical, CapdSpacing.row)
        .frame(minHeight: 44)
    }

    @ViewBuilder
    private var icon: some View {
        if let customIcon {
            customIcon(min(iconSize, 44))
        } else {
            CapdIconTile(symbol: symbol, tint: tint, size: min(iconSize, 44))
        }
    }

    private var text: some View {
        let palette = CapdPalette(
            colorScheme: colorScheme, increasedContrast: contrast == .increased)
        return VStack(alignment: .leading, spacing: CapdSpacing.tight) {
            Text(title).font(CapdTypography.rowTitle).foregroundStyle(palette.text)
                .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
            Text(metadata.map(String.init).joined(separator: "\u{200B}")).font(
                CapdTypography.metadata
            )
            .accessibilityLabel(metadata).foregroundStyle(palette.textSecondary)
            .lineLimit(textSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            if !snippet.isEmpty {
                Text(snippet).font(CapdTypography.snippet).foregroundStyle(palette.textSecondary)
                    .lineLimit(textSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status {
                Text(status).font(CapdTypography.metadata).foregroundStyle(palette.textSecondary)
            }
            if !tags.isEmpty {
                if textSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: CapdSpacing.tight) { chips }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: CapdSpacing.small) { chips }
                        VStack(alignment: .leading, spacing: CapdSpacing.tight) { chips }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chips: some View {
        ForEach(Array(tags.prefix(2).enumerated()), id: \.offset) { _, tag in CapdTagChip(tag) }
    }
}
