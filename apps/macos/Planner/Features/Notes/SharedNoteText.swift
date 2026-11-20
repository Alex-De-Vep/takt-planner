import AppKit

/// The body text lives in PlannerNote.text. Offsets match AppKit and Android's UTF-16 selections.
struct SharedNoteText: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let imageLimit = 2 * 1024 * 1024
    var version = currentVersion
    var spans: [Span]

    struct Span: Codable, Equatable, Sendable {
        let start: Int
        let end: Int
        var bold: Bool? = nil
        var italic: Bool? = nil
        var underline: Bool? = nil
        var size: Int? = nil
        var link: String? = nil
        var image: Data? = nil
    }

    enum Failure: LocalizedError {
        case unsupportedStyle, invalidDocument, imageTooLarge, noteTooLarge
        var errorDescription: String? {
            switch self {
            case .unsupportedStyle: "Заметка содержит оформление, которое пока нельзя перенести в общий редактор."
            case .invalidDocument: "Не удалось прочитать структуру заметки."
            case .imageTooLarge: "Изображение превышает лимит общего редактора."
            case .noteTooLarge: "Заметка превышает лимит синхронизации."
            }
        }
    }

    func validate(text: String) throws {
        guard version == Self.currentVersion, spans.count <= 4096 else { throw Failure.invalidDocument }
        let units = Array(text.utf16)
        var previousEnd = 0
        var images = Set<Int>()
        func isBoundary(_ index: Int) -> Bool {
            index == units.count || !(0xDC00...0xDFFF).contains(units[index])
        }
        for span in spans {
            guard span.start >= previousEnd, span.end > span.start, span.end <= units.count,
                  isBoundary(span.start), isBoundary(span.end),
                  span.size.map({ (8...72).contains($0) }) ?? true,
                  span.link.map({ Self.url($0) != nil }) ?? true else { throw Failure.invalidDocument }
            if let image = span.image {
                guard span.end - span.start == 1, units[span.start] == 0xFFFC else { throw Failure.invalidDocument }
                guard image.count <= Self.imageLimit else { throw Failure.imageTooLarge }
                guard Self.isPNG(image) else { throw Failure.invalidDocument }
                images.insert(span.start)
            }
            previousEnd = span.end
        }
        guard units.indices.allSatisfy({ units[$0] != 0xFFFC || images.contains($0) }) else {
            throw Failure.invalidDocument
        }
    }

    static func encode(_ content: NSAttributedString) throws -> Self {
        let manager = NSFontManager.shared
        var spans = [Span]()
        var failure: Error?
        content.enumerateAttributes(in: NSRange(location: 0, length: content.length)) { attributes, range, stop in
            do {
                // Paste can include fonts, colors and paragraph styles outside the shared format.
                // Keep the original text and project its formatting onto the supported styles.
                var span = Span(start: range.location, end: NSMaxRange(range))
                if let font = attributes[.font] as? NSFont {
                    let traits = manager.traits(of: font)
                    if traits.contains(.boldFontMask) { span.bold = true }
                    if traits.contains(.italicFontMask) { span.italic = true }
                    let size = font.pointSize.rounded()
                    if (8...72).contains(size), size != 16 { span.size = Int(size) }
                }
                if let underline = attributes[.underlineStyle] as? Int, underline & 0xFF != 0 {
                    span.underline = true
                }
                if let rawLink = attributes[.link] {
                    let link = (rawLink as? URL)?.absoluteString ?? rawLink as? String ?? ""
                    if Self.url(link) != nil { span.link = link }
                }
                if let attachment = attributes[.attachment] as? NSTextAttachment {
                    guard let raw = attachment.fileWrapper?.regularFileContents,
                          let bitmap = NSBitmapImageRep(data: raw),
                          bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0,
                          bitmap.pixelsWide <= 2500, bitmap.pixelsHigh <= 2500,
                          let image = bitmap.representation(using: .png, properties: [:]) else { throw Failure.unsupportedStyle }
                    guard image.count <= Self.imageLimit else { throw Failure.imageTooLarge }
                    span.image = image
                }
                if span.bold == true || span.italic == true || span.underline == true || span.size != nil ||
                    span.link != nil || span.image != nil { spans.append(span) }
            } catch {
                failure = error
                stop.pointee = true
            }
        }
        if let failure { throw failure }
        let body = Self(spans: spans)
        try body.validate(text: content.string)
        return body
    }

    @MainActor func attributedText(_ text: String) throws -> NSAttributedString {
        try validate(text: text)
        let value = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor,
        ])
        let manager = NSFontManager.shared
        for span in spans {
            let range = NSRange(location: span.start, length: span.end - span.start)
            var font = NSFont.systemFont(ofSize: CGFloat(span.size ?? 16))
            if span.bold == true { font = manager.convert(font, toHaveTrait: .boldFontMask) }
            if span.italic == true { font = manager.convert(font, toHaveTrait: .italicFontMask) }
            value.addAttribute(.font, value: font, range: range)
            if span.underline == true {
                value.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if let link = span.link.flatMap(Self.url) { value.addAttribute(.link, value: link, range: range) }
            if let data = span.image {
                guard let bitmap = NSBitmapImageRep(data: data), bitmap.pixelsWide <= 2500, bitmap.pixelsHigh <= 2500,
                      let image = NSImage(data: data) else { throw Failure.invalidDocument }
                if image.size.width > 560 {
                    image.size = NSSize(width: 560, height: image.size.height * 560 / image.size.width)
                }
                let attachment = NSTextAttachment()
                let wrapper = FileWrapper(regularFileWithContents: data)
                wrapper.preferredFilename = "image.png"
                attachment.fileWrapper = wrapper
                attachment.attachmentCell = NSTextAttachmentCell(imageCell: image)
                value.addAttribute(.attachment, value: attachment, range: range)
            }
        }
        return value
    }

    private static func url(_ link: String) -> URL? {
        guard link.utf8.count <= 2048, let url = URL(string: link), let scheme = url.scheme?.lowercased(),
              ["https", "http", "mailto"].contains(scheme),
              scheme == "mailto" || url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func isPNG(_ data: Data) -> Bool {
        let header = Array(data.prefix(24))
        guard header.count == 24, header.prefix(8).elementsEqual([137, 80, 78, 71, 13, 10, 26, 10]),
              header[12..<16].elementsEqual([73, 72, 68, 82]) else { return false }
        func dimension(_ at: Int) -> Int { header[at..<at + 4].reduce(0) { ($0 << 8) | Int($1) } }
        return (1...2500).contains(dimension(16)) && (1...2500).contains(dimension(20))
    }
}
