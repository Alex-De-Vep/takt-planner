import AppKit

/// Общая стеклянная капсула toolbar; значки не входят в область текстового редактора.
@MainActor
final class WorkspaceToolbarSearchView: NSView, NSTextFieldDelegate {
    let searchField = NSTextField(string: "")
    let searchIcon = NSImageView()
    let clearButton = NSButton()
    private var widthConstraint: NSLayoutConstraint!
    private var isEditing = false {
        didSet { needsDisplay = true }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 32))
        translatesAutoresizingMaskIntoConstraints = false

        // Однострочный NSTextField использует одну геометрию для подсказки и ввода.
        // Нативная высота не смещает текст относительно лупы, как растянутое поле.
        searchField.font = .systemFont(ofSize: 13)
        searchField.isBezeled = false
        searchField.isBordered = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.cell?.focusRingType = .none
        searchField.usesSingleLineMode = true
        searchField.cell?.isScrollable = true
        searchField.cell?.sendsActionOnEndEditing = false
        searchField.lineBreakMode = .byClipping
        searchField.textColor = .labelColor
        searchField.delegate = self
        searchField.setContentHuggingPriority(.required, for: .vertical)
        searchField.setContentCompressionResistancePriority(.required, for: .vertical)
        searchField.setAccessibilityIdentifier("task-search-field")
        searchField.setAccessibilitySubrole(.searchField)

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.setAccessibilityElement(false)

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        clearButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        clearButton.imagePosition = .imageOnly
        clearButton.contentTintColor = .secondaryLabelColor
        clearButton.isBordered = false
        clearButton.focusRingType = .none
        clearButton.target = self
        clearButton.action = #selector(clearSearch)
        clearButton.isHidden = true

        for view in [searchIcon, searchField, clearButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        // Все элементы центрируются по одной оси. Место очистки зарезервировано:
        // при первом символе ширина ввода и положение курсора не меняются.
        widthConstraint = widthAnchor.constraint(equalToConstant: 160)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: 32),
            searchIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            searchIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchIcon.widthAnchor.constraint(equalToConstant: 14),
            searchIcon.heightAnchor.constraint(equalToConstant: 14),
            searchField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 6),
            searchField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -4),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 16),
            clearButton.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isEditing else { return }
        // Фон остаётся системным, а фокус повторяет капсулу вместо прямоугольника редактора.
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                                   xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
        outline.lineWidth = 1.5
        outline.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === searchIcon ? self : hit
    }

    override func mouseDown(with event: NSEvent) {
        // Лупа и свободная область капсулы тоже открывают ввод с первого нажатия.
        window?.makeFirstResponder(searchField)
    }

    func setText(_ text: String) {
        // При том же тексте обновление из модели не трогает курсор и составные символы.
        if searchField.stringValue != text {
            searchField.stringValue = text
            if let editor = searchField.currentEditor(), editor.string != text {
                editor.string = text
            }
        }
        clearButton.isHidden = text.isEmpty
    }

    func controlTextDidBeginEditing(_ notification: Notification) { isEditing = true }
    func controlTextDidEndEditing(_ notification: Notification) { isEditing = false }

    func controlTextDidChange(_ notification: Notification) {
        clearButton.isHidden = searchField.stringValue.isEmpty
        searchField.sendAction(searchField.action, to: searchField.target)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        // Escape очищает запрос; повторное нажатие выходит из пустого поля.
        if searchField.stringValue.isEmpty { window?.makeFirstResponder(nil) }
        else { clearSearch() }
        return true
    }

    @objc private func clearSearch() {
        setText("")
        window?.makeFirstResponder(searchField)
        searchField.sendAction(searchField.action, to: searchField.target)
    }

    @discardableResult func setAvailableWidth(_ availableWidth: CGFloat) -> Bool {
        let width = max(100, floor(availableWidth))
        guard abs(widthConstraint.constant - width) >= 1 else { return false }
        widthConstraint.constant = width
        return true
    }
}
