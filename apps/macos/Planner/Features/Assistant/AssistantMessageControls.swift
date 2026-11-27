import AppKit
import SwiftUI

struct AssistantCopyMessageButton: View {
    @Environment(\.translations) private var strings
    @State private var copied: UUID?
    let text: () -> String

    private var title: String { strings[copied == nil ? "Копировать сообщение" : "Сообщение скопировано"] }

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.setString(text(), forType: .string) { copied = UUID() }
        } label: {
            Image(systemName: copied == nil ? "square.on.square" : "checkmark")
                .font(.caption)
                .foregroundStyle(PlannerStyle.assistantAccent)
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(title)
        .accessibilityIdentifier("assistant-message-copy")
        .help(title)
        .task(id: copied) {
            guard copied != nil else { return }
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { copied = nil }
        }
    }
}

/// Плоский текстовый блок: выделением управляет AppKit, прокруткой — список сообщений.
struct AssistantSelectableText: NSViewRepresentable {
    let text: String
    var emphasized = false

    // SwiftUI can ask for several widths in the same layout pass.
    final class Coordinator {
        var text: String?
        var emphasized = false
        var heights: [CGFloat: CGFloat] = [:]
        let measuringLayout = NSLayoutManager()
        let measuringContainer = NSTextContainer(size: .zero)

        init() {
            measuringContainer.lineFragmentPadding = 0
            measuringLayout.addTextContainer(measuringContainer)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = false
        view.textContainer?.containerSize.height = .greatestFiniteMagnitude
        view.textStorage?.addLayoutManager(context.coordinator.measuringLayout)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        // Повторная раскладка чата не сбрасывает выделение и позицию курсора.
        let cache = context.coordinator
        guard let storage = view.textStorage, cache.text != text || cache.emphasized != emphasized else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: emphasized ? .medium : .regular),
            .foregroundColor: NSColor.labelColor
        ]
        if let previous = cache.text, cache.emphasized == emphasized,
           text.utf8.count > previous.utf8.count, text.utf8.starts(with: previous.utf8) {
            let suffix = String(decoding: text.utf8.dropFirst(previous.utf8.count), as: UTF8.self)
            storage.append(NSAttributedString(string: suffix, attributes: attributes))
        } else {
            storage.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        }
        cache.text = text
        cache.emphasized = emphasized
        cache.heights.removeAll(keepingCapacity: true)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        let proposed = proposal.width ?? 300
        let width = proposed.isFinite ? max(1, proposed) : 300
        let cache = context.coordinator
        if let height = cache.heights[width] { return CGSize(width: width, height: height) }
        // Measure at SwiftUI's proposed width without resizing the displayed text or disturbing its selection.
        let container = cache.measuringContainer
        if container.containerSize.width != width {
            container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        let layout = cache.measuringLayout
        layout.ensureLayout(for: container)
        let bottom = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let height = ceil(bottom)
        // Bound the cache during live window resizing.
        if cache.heights.count >= 4 { cache.heights.removeAll(keepingCapacity: true) }
        cache.heights[width] = height
        return CGSize(width: width, height: height)
    }
}
