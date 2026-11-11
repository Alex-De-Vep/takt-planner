import AppKit

/// Постоянная круглая кнопка или значок на панели с подсветкой только при наведении.
@MainActor
final class WorkspaceToolbarButtonSurface: NSView {
    static let diameter: CGFloat = 36
    private static let sidebarButtonSize = NSSize(width: 34, height: 26)
    enum Presentation { case circle, sidebar }
    let contentView: NSView
    private let glass = NSGlassEffectView()
    private var contentConstraints: [NSLayoutConstraint] = []
    private var widthConstraint: NSLayoutConstraint!
    private var glassLeading: NSLayoutConstraint!
    private var contentLeading: NSLayoutConstraint?
    var presentation: Presentation = .circle {
        didSet { if oldValue != presentation { configureContent() } }
    }
    var leadingInset: CGFloat = 0 {
        didSet {
            guard oldValue != leadingInset else { return }
            widthConstraint.constant = Self.diameter + leadingInset
            glassLeading.constant = leadingInset
            contentLeading?.constant = leadingInset + (Self.diameter - Self.sidebarButtonSize.width) / 2
        }
    }

    init(content: NSView) {
        let diameter = Self.diameter
        contentView = content
        super.init(frame: NSRect(x: 0, y: 0, width: diameter, height: diameter))
        translatesAutoresizingMaskIntoConstraints = false
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.style = .regular
        glass.cornerRadius = diameter / 2
        addSubview(glass)
        widthConstraint = widthAnchor.constraint(equalToConstant: diameter)
        glassLeading = glass.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: diameter),
            glassLeading, glass.topAnchor.constraint(equalTo: topAnchor),
            glass.widthAnchor.constraint(equalToConstant: diameter),
            glass.heightAnchor.constraint(equalToConstant: diameter)
        ])
        configureContent()
    }

    required init?(coder: NSCoder) { nil }

    private func configureContent() {
        // Меняется только оболочка: экземпляр кнопки, действие, подсказка и доступность сохраняются.
        NSLayoutConstraint.deactivate(contentConstraints)
        glass.contentView = nil
        contentView.removeFromSuperview()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        glass.isHidden = presentation == .sidebar
        let host: NSView
        if presentation == .circle {
            glass.contentView = contentView
            host = glass
            contentLeading = nil
        } else {
            addSubview(contentView)
            host = self
            contentLeading = contentView.leadingAnchor.constraint(equalTo: leadingAnchor,
                constant: leadingInset + (Self.diameter - Self.sidebarButtonSize.width) / 2)
        }
        // У открытой панели подсветка ниже круга toolbar и имеет овальную форму, как в «Заметках».
        let size = presentation == .circle ? NSSize(width: Self.diameter, height: Self.diameter) : Self.sidebarButtonSize
        contentConstraints = [
            contentLeading ?? contentView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            contentView.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            contentView.widthAnchor.constraint(equalToConstant: size.width),
            contentView.heightAnchor.constraint(equalToConstant: size.height)
        ]
        NSLayoutConstraint.activate(contentConstraints)
        if let button = contentView as? NSButton {
            button.borderShape = presentation == .circle ? .circle : .capsule
        }
    }
}
