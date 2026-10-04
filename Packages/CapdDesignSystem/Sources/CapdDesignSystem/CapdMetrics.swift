import SwiftUI

public enum CapdSpacing {
    public static let tight: CGFloat = 4
    public static let small: CGFloat = 6
    public static let row: CGFloat = 8
    public static let control: CGFloat = 12
    public static let panel: CGFloat = 16
    public static let section: CGFloat = 20
}

public enum CapdRadius {
    public static let row: CGFloat = 8
    public static let panel: CGFloat = 12
}

public enum CapdTypography {
    public static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    public static let title = Font.title2.weight(.semibold)
    public static let rowTitle = Font.subheadline.weight(.medium)
    public static let body = Font.body
    public static let snippet = Font.subheadline
    public static let metadata = Font.system(.caption, design: .monospaced)
    public static let section = Font.system(.caption, design: .monospaced).weight(.medium)
}
