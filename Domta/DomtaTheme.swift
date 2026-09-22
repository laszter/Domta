import SwiftUI

/// Derived from the app icon: sky, graphite clipboards, green source and red target.
/// Light/dark shades keep text and controls readable while preserving those roles.
enum DomtaTheme {
    static let graphite = rgb(0x292C3A)

    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0x9AD8F2) : rgb(0x14678E)
    }
    static func source(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0xA2DE58) : rgb(0x397C13)
    }
    static func target(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0xFF9286) : rgb(0xB9312B)
    }
    static func sidebar(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0x292D3C) : rgb(0xD5EBF7)
    }
    static func sidebarInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0xE8F2FA) : rgb(0x263C50)
    }
    static func sidebarMuted(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0xACBED1) : rgb(0x4C6478)
    }
    static func selection(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0x35475D) : rgb(0xBDDEEF)
    }
    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0x1E212C) : rgb(0xF4F8FC)
    }
    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0x282D3C) : .white
    }
    static func rule(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0x465168) : rgb(0xB8CADB)
    }
    static func placeholder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? rgb(0xB0BED0) : rgb(0x57687C)
    }
    private static func rgb(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}


struct DomtaPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration)
    }

    private struct PrimaryButtonBody: View {
        let configuration: ButtonStyle.Configuration
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .foregroundStyle(isEnabled ? (colorScheme == .dark ? DomtaTheme.graphite : .white) : Color.secondary)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isEnabled ? DomtaTheme.accent(colorScheme) : Color.secondary.opacity(0.12))
                        .opacity(configuration.isPressed ? 0.78 : (isHovered && isEnabled ? 0.9 : 1))
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onHover { isHovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
        }
    }
}

