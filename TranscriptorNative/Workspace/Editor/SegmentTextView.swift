import SwiftUI
import AppKit

/// Text of one segment. Reading mode: selectable, click → word, double click → edit.
/// Editing mode: editable with the editor shortcuts (spec 7.6, 7.8). Active word and search
/// matches are drawn as layers behind the glyphs so the word highlight can move (spec 7.5).
struct SegmentTextView: NSViewRepresentable {
    struct Highlights: Equatable {
        var activeWord: Int?
        var matches: [NSRange] = []
        var currentMatch: NSRange?
    }

    let text: String
    let style: TX.TextStyle
    let isEditing: Bool
    var highlights = Highlights()
    var reduceMotion = false
    var accessibilityLabel: String = ""
    /// Called on a single click with the word index under the pointer (nil between words).
    var onClick: (Int?) -> Void = { _ in }
    /// Double click: enter editing with the caret at that character.
    var onDoubleClick: (Int) -> Void = { _ in }
    var onCommit: (String) -> Void = { _ in }
    var onCommitNext: (String) -> Void = { _ in }
    var onSplit: (String, Int) -> Void = { _, _ in }
    var onMoveEdge: (String, Int) -> Void = { _, _ in }
    /// Caret position requested when editing starts.
    var initialCaret: Int?

    func makeNSView(context: Context) -> SegmentTextContainer {
        let view = SegmentTextContainer()
        view.textView.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ view: SegmentTextContainer, context: Context) {
        context.coordinator.parent = self
        view.configure(text: text, style: style, editing: isEditing, caret: initialCaret, label: accessibilityLabel)
        view.update(highlights: highlights, animated: !reduceMotion)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SegmentTextContainer, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        return CGSize(width: width, height: nsView.height(forWidth: width))
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: SegmentTextView
        init(parent: SegmentTextView) { self.parent = parent }
    }
}

final class SegmentTextContainer: NSView {
    let textView = SegmentNSTextView()
    private let wordLayer = CALayer()
    private let underlineLayer = CALayer()
    private var matchLayers: [CALayer] = []
    private var currentText = ""
    private var currentStyle: TX.TextStyle?
    private var lastHighlights = SegmentTextView.Highlights()
    private var wasEditing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        wordLayer.cornerRadius = 3
        wordLayer.opacity = 0
        underlineLayer.opacity = 0
        layer?.addSublayer(wordLayer)
        layer?.addSublayer(underlineLayer)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.focusRingType = .none
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func configure(text: String, style: TX.TextStyle, editing: Bool, caret: Int?, label: String) {
        let styleChanged = currentStyle?.size != style.size || currentStyle?.lineHeight != style.lineHeight
        if styleChanged || (!editing && text != currentText) || (editing && !wasEditing) {
            currentText = text
            currentStyle = style
            textView.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: Self.attributes(style)))
            textView.typingAttributes = Self.attributes(style)
            invalidateIntrinsicContentSize()
        }
        textView.selectedTextAttributes = [.backgroundColor: TX.NSColors.selectionText]
        textView.isEditable = editing
        textView.isSelectable = true
        textView.setAccessibilityLabel(label)
        if editing && !wasEditing {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self.textView)
                let length = (self.textView.string as NSString).length
                self.textView.setSelectedRange(NSRange(location: min(caret ?? length, length), length: 0))
            }
        } else if !editing && wasEditing, window?.firstResponder === textView {
            window?.makeFirstResponder(nil)
        }
        wasEditing = editing
        needsLayout = true
    }

    static func attributes(_ style: TX.TextStyle) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = style.lineHeight
        paragraph.maximumLineHeight = style.lineHeight
        let font = NSFont.systemFont(ofSize: style.size, weight: .regular)
        let baselineOffset = (style.lineHeight - (font.ascender - font.descender)) / 4
        return [
            .font: font,
            .foregroundColor: TX.NSColors.textPrimary,
            .paragraphStyle: paragraph,
            .baselineOffset: baselineOffset
        ]
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textView.textContainer, let manager = textView.layoutManager else { return 24 }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).height
        return max(ceil(used), currentStyle?.lineHeight ?? 24)
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
        textView.textContainer?.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        update(highlights: lastHighlights, animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update(highlights: lastHighlights, animated: false)
    }

    // MARK: Highlights

    func update(highlights: SegmentTextView.Highlights, animated: Bool) {
        let moving = highlights.activeWord != lastHighlights.activeWord
        lastHighlights = highlights
        guard let manager = textView.layoutManager, let container = textView.textContainer else { return }

        // Search matches (amber 30 %, current 60 % with 1 px outline).
        matchLayers.forEach { $0.removeFromSuperlayer() }
        matchLayers = highlights.matches.compactMap { range -> CALayer? in
            guard NSMaxRange(range) <= (textView.string as NSString).length else { return nil }
            let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            let l = CALayer()
            let isCurrent = highlights.currentMatch == range
            l.backgroundColor = TX.NSColors.searchMatch.withAlphaComponent(isCurrent ? 0.6 : 0.3).resolved(in: self)
            if isCurrent {
                l.borderColor = TX.NSColors.searchMatch.resolved(in: self)
                l.borderWidth = 1
            }
            l.cornerRadius = 3
            l.frame = rect.insetBy(dx: -1, dy: 1)
            layer?.insertSublayer(l, below: wordLayer)
            return l
        }

        // Active word: background word.active + 2 pt underline purple.400; 80 ms linear between words.
        let ranges = EditorOperations.wordRanges(in: textView.string)
        guard let index = highlights.activeWord, index < ranges.count, !textView.isEditable else {
            wordLayer.opacity = 0
            underlineLayer.opacity = 0
            return
        }
        let nsRange = NSRange(ranges[index], in: textView.string)
        let glyphs = manager.glyphRange(forCharacterRange: nsRange, actualCharacterRange: nil)
        let rect = manager.boundingRect(forGlyphRange: glyphs, in: container).insetBy(dx: -2, dy: 2)
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated && moving && wordLayer.opacity > 0 ? 0.08 : 0)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        wordLayer.backgroundColor = TX.NSColors.wordActive.resolved(in: self)
        wordLayer.frame = rect
        wordLayer.opacity = 1
        underlineLayer.backgroundColor = TX.NSColors.accentText.resolved(in: self)
        underlineLayer.frame = CGRect(x: rect.minX + 2, y: rect.maxY - 2, width: rect.width - 4, height: 2)
        underlineLayer.opacity = 1
        CATransaction.commit()
    }
}

final class SegmentNSTextView: NSTextView {
    weak var coordinator: SegmentTextView.Coordinator?

    convenience init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        manager.addTextContainer(container)
        self.init(frame: .zero, textContainer: container)
    }

    override var acceptsFirstResponder: Bool { isEditable || super.acceptsFirstResponder }

    override func mouseDown(with event: NSEvent) {
        guard !isEditable, let parent = coordinator?.parent else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let charIndex = characterIndexForInsertion(at: point)
        if event.clickCount >= 2 {
            parent.onDoubleClick(charIndex)
            return
        }
        // A drag selects text for copying; a plain click selects the segment and moves the audio.
        let start = event.locationInWindow
        var dragged = false
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            if next.type == .leftMouseDragged, hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 3 {
                dragged = true
                window?.makeFirstResponder(self)
                super.mouseDown(with: event)
                break
            }
            if next.type == .leftMouseUp { break }
        }
        if !dragged {
            let ranges = EditorOperations.wordRanges(in: string)
            let word = ranges.firstIndex { NSRange($0, in: string).contains(charIndex) || NSMaxRange(NSRange($0, in: string)) == charIndex }
            parent.onClick(word)
        }
    }

    override func doCommand(by selector: Selector) {
        guard isEditable, let parent = coordinator?.parent else { return super.doCommand(by: selector) }
        let flags = NSApp.currentEvent?.modifierFlags.intersection([.command, .option, .shift, .control]) ?? []
        switch selector {
        case #selector(cancelOperation(_:)):
            parent.onCommit(string)
        case #selector(insertNewline(_:)) where flags == .command:
            parent.onCommitNext(string)
        case #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)):
            // ⌥Return splits at the caret (never inserts a line break, spec 10.9).
            parent.onSplit(string, selectedRange().location)
        case #selector(insertNewline(_:)) where flags == .option:
            parent.onSplit(string, selectedRange().location)
        case #selector(insertNewline(_:)):
            // Return inside a segment keeps it as one paragraph: commit instead of breaking the line.
            parent.onCommit(string)
        case #selector(moveUp(_:)) where flags.contains(.option), #selector(moveParagraphBackwardAndModifySelection(_:)):
            if isOnFirstLine { parent.onMoveEdge(string, -1) } else { super.doCommand(by: selector) }
        case #selector(moveDown(_:)) where flags.contains(.option), #selector(moveParagraphForwardAndModifySelection(_:)):
            if isOnLastLine { parent.onMoveEdge(string, 1) } else { super.doCommand(by: selector) }
        default:
            super.doCommand(by: selector)
        }
    }

    override func keyDown(with event: NSEvent) {
        // ⌥↑ / ⌥↓ arrive as moveToBeginning/EndOfParagraph on macOS; handle at the edges here.
        if isEditable, event.modifierFlags.intersection([.command, .option, .shift, .control]) == .option,
           let parent = coordinator?.parent {
            if event.keyCode == KeyCode.up, isOnFirstLine { parent.onMoveEdge(string, -1); return }
            if event.keyCode == KeyCode.down, isOnLastLine { parent.onMoveEdge(string, 1); return }
            if event.keyCode == KeyCode.returnKey { parent.onSplit(string, selectedRange().location); return }
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        // Click outside the segment: save and leave editing (spec 7.6).
        if ok, isEditable, let parent = coordinator?.parent {
            let text = string
            DispatchQueue.main.async { parent.onCommit(text) }
        }
        return ok
    }

    private var isOnFirstLine: Bool { lineRect(at: selectedRange().location).minY <= 1 }
    private var isOnLastLine: Bool {
        let r = lineRect(at: selectedRange().location)
        guard let manager = layoutManager, let container = textContainer else { return true }
        return r.maxY >= manager.usedRect(for: container).maxY - 1
    }

    private func lineRect(at location: Int) -> NSRect {
        guard let manager = layoutManager else { return .zero }
        let length = (string as NSString).length
        if length == 0 { return .zero }
        let glyph = manager.glyphIndexForCharacter(at: min(location, length - 1))
        return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }
}

extension NSColor {
    /// CGColor resolved against a view's effective appearance (layers do not resolve dynamic colours).
    func resolved(in view: NSView) -> CGColor {
        var result = cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance { result = self.cgColor }
        return result
    }
}
