import SwiftUI

public struct CapdPalette: Sendable {
    public let background: Color
    public let raised: Color
    public let raisedLight: Color
    public let bar: Color
    public let border: Color
    public let text: Color
    public let textSecondary: Color
    public let textTertiary: Color
    public let selection: Color
    public let accent: Color
    public let accentSecondary: Color
    public let success: Color
    public let warning: Color

    public static let dark = CapdPalette(colorScheme: .dark)

    public init(colorScheme: ColorScheme, increasedContrast: Bool = false) {
        if colorScheme == .dark {
            background = Color(red: 0.075, green: 0.075, blue: 0.086)
            raised = Color.white.opacity(0.05)
            raisedLight = Color.white.opacity(0.9)
            bar = .black
            border = Color.white.opacity(increasedContrast ? 0.24 : 0.09)
            text = Color.white.opacity(0.93)
            textSecondary = Color.white.opacity(increasedContrast ? 0.75 : 0.56)
            textTertiary = Color.white.opacity(increasedContrast ? 0.65 : 0.34)
            selection = Color.white.opacity(0.08)
            accent = Color(red: 0.38, green: 0.55, blue: 1.0)
            accentSecondary = Color(red: 0.66, green: 0.42, blue: 0.92)
            success = Color(red: 0.35, green: 0.84, blue: 0.5)
            warning = Color(red: 1.0, green: 0.62, blue: 0.26)
        } else {
            background = Color(red: 0.96, green: 0.96, blue: 0.97)
            raised = Color.black.opacity(0.04)
            raisedLight = .white
            bar = .white
            border = Color.black.opacity(increasedContrast ? 0.3 : 0.1)
            text = Color.black.opacity(0.9)
            textSecondary = Color.black.opacity(increasedContrast ? 0.8 : 0.62)
            textTertiary = Color.black.opacity(increasedContrast ? 0.7 : 0.5)
            selection = Color.black.opacity(0.07)
            accent = Color(red: 0.2, green: 0.36, blue: 0.78)
            accentSecondary = Color(red: 0.46, green: 0.28, blue: 0.66)
            success = Color(red: 0.13, green: 0.48, blue: 0.25)
            warning = Color(red: 0.65, green: 0.31, blue: 0.02)
        }
    }
}
