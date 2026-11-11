import AppKit
import QuartzCore
import SwiftUI

/// Короткие переходы без пружин: управление реагирует сразу, меняется только представление.
enum PlannerMotion {
    enum Kind {
        case feedback, content, listChange, panel

        var duration: TimeInterval {
            switch self {
            case .feedback: 0.16
            case .content: 0.22
            case .listChange: 0.26
            case .panel: 0.26
            }
        }
    }

    static func animation(_ kind: Kind = .content, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: kind.duration)
    }

    @MainActor static func configure(_ context: NSAnimationContext, kind: Kind = .panel) {
        context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : kind.duration
        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    }
}
