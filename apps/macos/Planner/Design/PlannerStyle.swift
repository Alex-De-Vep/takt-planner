import AppKit
import SwiftUI

/// Спокойные поверхности в духе «Заметок» и собственный фиолетовый акцент в обеих темах macOS.
enum PlannerStyle {
    static let accent = Color("AccentColor")

    private static let settingsAccentLight: UInt32 = 0x59616D
    static let settingsAccent = color(light: settingsAccentLight, dark: 0xA7B1BF)
    static let settingsSelection = color(light: 0xE9ECF1, dark: 0x323740)
    static let settingsControlTint = Color(nsColor: rgb(settingsAccentLight))

    private static let assistantBlue: UInt32 = 0x2E58FF
    static let assistantAccent = Color(nsColor: rgb(assistantBlue))
    private static let calendarAccentLight: UInt32 = 0x456FAF
    static let calendarAccent = color(light: calendarAccentLight, dark: 0x8EB9F2)
    static let calendarControlTint = Color(nsColor: rgb(calendarAccentLight))
    static let calendarAccentForeground = color(light: 0xFFFFFF, dark: 0x151B2D)
    static let assistantUserMessageBackground = color(light: 0xEDF1F8, dark: 0x282C37)
    static let assistantGradient = LinearGradient(stops: [
        (assistantBlue, 0.000), (0x584FFF, 0.083), (0x7446FC, 0.167),
        (0x8C3DF4, 0.250), (0xA134E8, 0.333), (0xB42BD9, 0.417),
        (0xC51FC6, 0.500), (0xD410B1, 0.583), (0xE0009A, 0.667),
        (0xEA0080, 0.750), (0xF20066, 0.833), (0xF90046, 0.917), (0xFF0000, 1.000)
    ].map { hex, location in
        Gradient.Stop(color: Color(nsColor: rgb(hex)), location: location)
    }, startPoint: .topLeading, endPoint: .bottomTrailing)
    static let assistantReplyBackground = AnyShapeStyle(assistantGradient.opacity(0.13))
    private static let noteLightAccent: UInt32 = 0x7BC8AB
    static let noteSidebarSelection = color(light: noteLightAccent, dark: 0x397E68)
    static let noteControlAccent = color(light: noteLightAccent, dark: 0x70BFA2)
    static let noteActionTint = color(light: 0x286D57, dark: 0x70BFA2)
    // Подложка панели папок и список используют одну поверхность в обеих темах.
    static let workspaceBackground = nativeColor(light: 0xFAFAFA, dark: 0x242426)
    static let listBackground = Color(nsColor: workspaceBackground)
    static let paper = Color(nsColor: .textBackgroundColor)
    static let selection = color(light: 0xEEE7FA, dark: 0x3D2D58)
    static let actionBackground = color(light: 0xF7F7F5, dark: 0x272729)
    static let successBackground = color(light: 0xEDF5EE, dark: 0x293E30)

    static func assistantCardBackground(_ tint: Color, in colorScheme: ColorScheme) -> Color {
        tint.opacity(colorScheme == .dark ? 0.08 : 0.13)
    }

    static func color(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: nativeColor(light: light, dark: dark))
    }

    private static func nativeColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return rgb(hex)
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
    }
}

struct TaskActionButton: View {
    @Environment(\.translations) private var strings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let symbol: String
    let active: Bool
    var isCompletion = false
    let action: () -> Void

    private var contentColor: Color {
        active ? (isCompletion ? Color.green : PlannerStyle.accent) : Color.primary
    }

    var body: some View {
        Button(action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
                    .foregroundStyle(active && !isCompletion ? Color.yellow : contentColor)
            }
                .contentTransition(.opacity)
                .font(.system(size: 14, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        // Нативная кнопка принимает нажатие также при активном текстовом редакторе задачи.
        .buttonStyle(.borderless)
        .foregroundStyle(contentColor)
        .background(active ? (isCompletion ? PlannerStyle.successBackground : PlannerStyle.selection) : PlannerStyle.paper, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(active ? 0 : 0.12), lineWidth: 0.5)
            .allowsHitTesting(false))
        .animation(PlannerMotion.animation(.feedback, reduceMotion: reduceMotion), value: active)
        .accessibilityValue(active ? strings["Включено"] : strings["Выключено"])
    }
}
