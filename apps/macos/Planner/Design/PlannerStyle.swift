import AppKit
import SwiftUI

/// Спокойные поверхности в духе «Заметок» и собственный фиолетовый акцент в обеих темах macOS.
enum PlannerStyle {
    static let accent = Color("AccentColor")
    // Подложка панели папок и список используют одну поверхность в обеих темах.
    static let workspaceBackground = nativeColor(light: 0xFAFAFA, dark: 0x242426)
    static let listBackground = Color(nsColor: workspaceBackground)
    static let paper = Color(nsColor: .textBackgroundColor)
    static let selection = color(light: 0xEEE7FA, dark: 0x3D2D58)
    static let actionBackground = color(light: 0xF7F7F5, dark: 0x272729)
    static let successBackground = color(light: 0xEDF5EE, dark: 0x293E30)

    static func color(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: nativeColor(light: light, dark: dark))
    }

    private static func nativeColor(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: 1)
        }
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
