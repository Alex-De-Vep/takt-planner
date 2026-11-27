import AppKit
import SwiftUI

struct FolderLabelPalette: View {
    @Environment(\.translations) private var strings
    @Binding var rgb: UInt32
    @State private var customColor: FolderLabelWheelColor?

    static let defaultRGB: UInt32 = 0x3D_8F_DB
    private static let presets: [(name: String, rgb: UInt32)] = [
        ("Красный", 0xDB_40_50), ("Оранжевый", 0xDF_7A_1D), ("Жёлтый", 0xCB_9B_06),
        ("Зелёный", 0x30_9B_66), ("Голубой", 0x26_A1_BF), ("Синий", defaultRGB),
        ("Фиолетовый", 0x8C_60_CC)
    ]

    static func color(for rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255,
              green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(Self.presets, id: \.rgb) { preset in
                    Button {
                        customColor = nil
                        rgb = preset.rgb
                    } label: {
                        swatch(Self.color(for: preset.rgb), selected: rgb == preset.rgb)
                    }
                    .help(strings[preset.name])
                    .accessibilityLabel(strings[preset.name])
                    .accessibilityAddTraits(rgb == preset.rgb ? .isSelected : [])
                }
                Button {
                    customColor = customColor == nil ? FolderLabelWheelColor(rgb: rgb) : nil
                } label: {
                    swatch(FolderLabelColorWheel.hues, selected: customColor != nil)
                }
                .help(strings["Цветовой круг"])
                .accessibilityLabel(strings["Цветовой круг"])
                .accessibilityIdentifier("folder-label-color-wheel")
            }
            .buttonStyle(.plain)
            if let selection = Binding($customColor) {
                FolderLabelColorWheel(selection: selection)
                    .onChange(of: selection.wrappedValue) { _, color in rgb = color.rgb }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func swatch(_ fill: some ShapeStyle, selected: Bool) -> some View {
        Circle()
            .fill(fill)
            .frame(width: 18, height: 18)
            .overlay {
                if selected {
                    Circle().strokeBorder(.white, lineWidth: 1.5)
                        .shadow(color: .black.opacity(0.35), radius: 1)
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }
}

struct FolderLabelWheelColor: Equatable {
    var hue: CGFloat = 0
    var saturation: CGFloat = 0
    var brightness: CGFloat = 0

    init(rgb: UInt32) {
        let color = NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                            green: CGFloat((rgb >> 8) & 255) / 255,
                            blue: CGFloat(rgb & 255) / 255, alpha: 1)
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
    }

    var rgb: UInt32 {
        let color = NSColor(colorSpace: .sRGB, hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        func byte(_ component: CGFloat) -> UInt32 { UInt32((component * 255).rounded()) }
        return byte(color.redComponent) << 16 | byte(color.greenComponent) << 8 | byte(color.blueComponent)
    }

    mutating func select(at point: CGPoint, radius: CGFloat) {
        let dx = point.x - radius
        let dy = point.y - radius
        let turn = atan2(dy, dx) / (2 * .pi)
        hue = turn < 0 ? turn + 1 : turn
        saturation = min(1, hypot(dx, dy) / radius)
    }

    func marker(radius: CGFloat) -> CGPoint {
        let angle = hue * 2 * .pi
        return CGPoint(x: radius + cos(angle) * saturation * radius,
                       y: radius + sin(angle) * saturation * radius)
    }
}

private struct FolderLabelColorWheel: View {
    @Environment(\.translations) private var strings
    @Binding var selection: FolderLabelWheelColor
    private let radius: CGFloat = 58

    static var hues: AngularGradient {
        AngularGradient(colors: (0...6).map {
            Color(hue: Double($0 % 6) / 6, saturation: 1, brightness: 1)
        }, center: .center)
    }

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(Self.hues)
                .overlay {
                    Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                                 startRadius: 0, endRadius: radius))
                    Circle().fill(.black.opacity(1 - selection.brightness))
                    Circle().strokeBorder(.white, lineWidth: 2).frame(width: 12, height: 12)
                        .shadow(color: .black, radius: 1)
                        .position(selection.marker(radius: radius))
                }
                .frame(width: radius * 2, height: radius * 2)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { selection.select(at: $0.location, radius: radius) })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(strings["Цветовой круг"])
                .accessibilityValue(String(format: "#%06X", selection.rgb))
                .accessibilityAdjustableAction { direction in
                    let step: CGFloat = direction == .increment ? 1 / 24 : -1 / 24
                    selection.hue = (selection.hue + step + 1).truncatingRemainder(dividingBy: 1)
                    if selection.saturation == 0 { selection.saturation = 1 }
                }
            Slider(value: $selection.brightness, in: 0...1) { Text(strings["Яркость"]) }
                .labelsHidden()
                .frame(width: radius * 2)
        }
    }
}
