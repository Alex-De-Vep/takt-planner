import AppKit
import QuartzCore
import SwiftUI

/// Нативное меню отвечает за мышь, клавиатуру и закрытие по Escape; стрелка следует его реальному состоянию.
struct AssistantTextToolsButton: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let commands: [String]
    let enabled: Bool
    let perform: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> AssistantTextPopupButton {
        let button = AssistantTextPopupButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .rounded
        button.isBordered = true
        button.font = .systemFont(ofSize: 13)
        button.controlSize = .regular
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.setAccessibilityIdentifier("assistant-text-tools")
        context.coordinator.button = button
        return button
    }
    func updateNSView(_ button: AssistantTextPopupButton, context: Context) {
        context.coordinator.perform = perform
        button.reduceMotion = reduceMotion
        button.isEnabled = enabled
        button.setAccessibilityLabel(title)
        if button.menu?.items.dropFirst().map(\.title) != commands || button.menu?.items.first?.title != title {
            let menu = NSMenu()
            menu.autoenablesItems = false
            // Первый пункт pull-down меню — подпись самой кнопки, в списке он не показывается.
            let caption = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            caption.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
            menu.addItem(caption)
            for command in commands {
                let item = NSMenuItem(title: command, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
                item.target = context.coordinator
                menu.addItem(item)
            }
            button.menu = menu
            button.invalidateIntrinsicContentSize()
        }
        button.menu?.delegate = context.coordinator
        button.menu?.items.dropFirst().forEach { $0.isEnabled = enabled }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AssistantTextPopupButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
    static func dismantleNSView(_ view: AssistantTextPopupButton, coordinator: Coordinator) {
        view.menu?.cancelTracking()
        view.menu?.delegate = nil
        view.menu?.items.forEach { $0.target = nil }
        view.setExpanded(false)
        coordinator.button = nil
        coordinator.perform = nil
    }
    final class Coordinator: NSObject, NSMenuDelegate {
        weak var button: AssistantTextPopupButton?
        var perform: ((String) -> Void)?
        func menuWillOpen(_ menu: NSMenu) { button?.setExpanded(true) }
        func menuDidClose(_ menu: NSMenu) { button?.setExpanded(false) }
        @objc func choose(_ item: NSMenuItem) {
            guard button?.isEnabled == true else { return }
            perform?(item.title)
        }
    }
}

final class AssistantTextPopupButton: NSPopUpButton {
    private let chevron = AssistantMenuChevron()
    private(set) var expanded = false
    var reduceMotion = false
    override init(frame buttonFrame: NSRect, pullsDown flag: Bool) {
        super.init(frame: buttonFrame, pullsDown: flag)
        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        chevron.imageScaling = .scaleProportionallyUpOrDown
        chevron.setAccessibilityElement(false)
        chevron.wantsLayer = true
        addSubview(chevron)
    }
    required init?(coder: NSCoder) { nil }
    override var intrinsicContentSize: NSSize {
        let native = super.intrinsicContentSize
        return NSSize(width: native.width + 18, height: native.height)
    }
    override func layout() {
        super.layout()
        chevron.frame = NSRect(x: bounds.maxX - 23, y: bounds.midY - 5, width: 10, height: 10)
        chevron.layer?.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        chevron.layer?.position = CGPoint(x: chevron.frame.midX, y: chevron.frame.midY)
    }
    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        guard let layer = chevron.layer else { return }
        let angle = value ? CGFloat.pi : 0
        let previous = layer.presentation()?.value(forKeyPath: "transform.rotation.z") as? CGFloat ?? (value ? 0 : CGFloat.pi)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        CATransaction.commit()
        if reduceMotion { layer.removeAnimation(forKey: "menu-chevron") }
        else {
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = previous; animation.toValue = angle
            animation.duration = 0.16
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(animation, forKey: "menu-chevron")
        }
    }
}

/// Стрелка не перехватывает нажатия на правый край кнопки.
private final class AssistantMenuChevron: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
