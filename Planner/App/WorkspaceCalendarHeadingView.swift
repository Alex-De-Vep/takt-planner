import AppKit

/// Подпись календаря находится в общей шапке окна, без отдельной стеклянной кнопки.
@MainActor
final class WorkspaceCalendarHeadingView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var width: NSLayoutConstraint!

    var preferredWidth: CGFloat {
        ceil((label.stringValue as NSString).size(withAttributes: [.font: label.font!]).width) + 16
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityIdentifier("calendar-panel-heading")
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        width = widthAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([
            width, heightAnchor.constraint(equalToConstant: 34),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(title: String, accessibilityIdentifier: String = "calendar-panel-heading") {
        label.setAccessibilityIdentifier(accessibilityIdentifier)
        guard label.stringValue != title else { return }
        label.stringValue = title
        width.constant = preferredWidth
    }
}
