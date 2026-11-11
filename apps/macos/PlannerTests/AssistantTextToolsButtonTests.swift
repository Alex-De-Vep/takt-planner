import AppKit
import Testing
@testable import Planner

@MainActor struct AssistantTextToolsButtonTests {
    @Test func arrowTracksMenuOpeningClosingAndCancellation() {
        let button = AssistantTextPopupButton(frame: NSRect(x: 0, y: 0, width: 220, height: 28), pullsDown: true)
        let coordinator = AssistantTextToolsButton.Coordinator()
        coordinator.button = button
        let menu = NSMenu()
        #expect(!button.expanded)
        coordinator.menuWillOpen(menu)
        #expect(button.expanded)
        coordinator.menuDidClose(menu)
        #expect(!button.expanded)
        coordinator.menuWillOpen(menu)
        coordinator.menuDidClose(menu)
        #expect(!button.expanded)
    }
    @Test func disabledButtonNeverDispatchesAnAction() {
        let button = AssistantTextPopupButton(frame: .zero, pullsDown: true)
        let coordinator = AssistantTextToolsButton.Coordinator()
        coordinator.button = button
        var performed: [String] = []
        coordinator.perform = { performed.append($0) }
        let command = NSMenuItem(title: "Расписать задачу", action: nil, keyEquivalent: "")
        button.isEnabled = false
        coordinator.choose(command)
        #expect(performed.isEmpty)
        button.isEnabled = true
        coordinator.choose(command)
        #expect(performed == ["Расписать задачу"])
        button.reduceMotion = true
        coordinator.menuWillOpen(NSMenu())
        #expect(button.expanded)
        coordinator.menuDidClose(NSMenu())
        #expect(!button.expanded)
    }
    @Test func nativeTrackingOpensAndClosesTheDisclosure() {
        let button = AssistantTextPopupButton(frame: NSRect(x: 12, y: 12, width: 220, height: 28), pullsDown: true)
        let coordinator = AssistantTextToolsButton.Coordinator()
        coordinator.button = button
        let menu = NSMenu()
        menu.addItem(withTitle: "Доработать текст", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Расписать задачу", action: nil, keyEquivalent: "")
        button.menu = menu; menu.delegate = coordinator
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 260, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(button)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let probe = TrackingProbe(button: button, menu: menu)
        let timer = Timer(timeInterval: 0.2, target: probe, selector: #selector(TrackingProbe.finish), userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        button.performClick(nil)
        #expect(probe.observedExpanded)
        #expect(!button.expanded)
    }

}

@MainActor private final class TrackingProbe: NSObject {
    let button: AssistantTextPopupButton
    let menu: NSMenu
    var observedExpanded = false
    init(button: AssistantTextPopupButton, menu: NSMenu) { self.button = button; self.menu = menu }
    @objc func finish() {
        observedExpanded = button.expanded
        menu.cancelTrackingWithoutAnimation()
    }
}
