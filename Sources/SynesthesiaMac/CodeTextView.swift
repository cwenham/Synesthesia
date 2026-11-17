import AppKit
import CodeEditing
import LanguageClient
import Stage
import SwiftUI
import SynesthesiaUI

/// The Mac's text surface: a TextKit 2 text view showing a pipeline's Meeplang, coloured from `meep lsp`'s semantic
/// tokens, with problems underlined, a gutter of line numbers and each module's rate, and selection and hover shared
/// with the canvas (design, section 2).
struct MacCodeText: NSViewRepresentable {
    let document: MeeplangDocument
    let stage: PipelineStage
    let workspace: Workspace

    static var provider: CodeTextSurfaceProvider {
        CodeTextSurfaceProvider { document, stage, workspace in
            AnyView(MacCodeText(document: document, stage: stage, workspace: workspace))
        }
    }

    func makeCoordinator() -> CodeTextCoordinator {
        CodeTextCoordinator(document: document, stage: stage)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let textView = CodeTextView(usingTextLayoutManager: true)
        textView.coordinator = coordinator
        textView.configure(readOnly: document.isReadOnly)
        textView.string = document.text
        textView.delegate = coordinator
        coordinator.textView = textView
        coordinator.appliedReplacement = document.replacement?.id

        let scroll = CodeScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = CodeTheme.background
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        let gutter = GutterView(scrollView: scroll, coordinator: coordinator)
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        coordinator.gutter = gutter
        coordinator.applyStyles()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        // Read here so SwiftUI updates the view when they change.
        let replacement = document.replacement
        let version = document.highlightsVersion
        let diagnostics = document.diagnostics
        let answer = document.answer
        let selection = stage.selection
        let hovered = stage.hovered
        let focus = workspace.textFocus
        _ = (version, diagnostics, answer)

        if let replacement, replacement.id != coordinator.appliedReplacement {
            coordinator.take(replacement)
        }
        coordinator.applyStyles()
        coordinator.follow(selection: selection, hovered: hovered)
        if let focus, focus.pipeline == stage.pipeline.id { coordinator.apply(focus) }
        coordinator.gutter?.needsDisplay = true
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: CodeTextCoordinator) {
        coordinator.stop()
    }
}

/// Keeps the text view, the document and the stage in step.
@MainActor
final class CodeTextCoordinator: NSObject, NSTextViewDelegate {
    let document: MeeplangDocument
    let stage: PipelineStage
    weak var textView: CodeTextView?
    weak var gutter: GutterView?
    var appliedReplacement: Int?
    private var appliedStyles: (version: Int, diagnostics: [LSPDiagnostic])?
    private var appliedFocus: Int?
    /// The module the cursor last selected, so the stage selecting it back doesn't scroll the text.
    private var caretKey: String?
    private var settingSelection = false
    private var hoverTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var popover: NSPopover?
    var completions: (offset: Int, items: [CompletionItem])?

    init(document: MeeplangDocument, stage: PipelineStage) {
        self.document = document
        self.stage = stage
    }

    func stop() {
        hoverTask?.cancel()
        completionTask?.cancel()
        popover?.close()
        stage.pointedFromText = nil
    }

    // MARK: Text to document

    func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        document.edit(textView.string)
        appliedStyles = nil
        gutter?.needsDisplay = true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView, !settingSelection else { return }
        let caret = textView.selectedRange().location
        let key = document.module(atLine: document.lines.line(at: caret))
        caretKey = key
        if let key {
            stage.select([key])
        }
        textView.needsDisplay = true
    }

    /// Takes text the document gives, keeping the cursor where it was as far as it can.
    func take(_ replacement: MeeplangDocument.Replacement) {
        appliedReplacement = replacement.id
        guard let textView, textView.string != replacement.text else { return }
        let selection = textView.selectedRange()
        settingSelection = true
        textView.string = replacement.text
        let length = (replacement.text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        settingSelection = false
        appliedStyles = nil
    }

    // MARK: Colours and problems

    /// Colours the text from the latest tokens, and underlines its problems, when either has changed.
    func applyStyles() {
        guard let textView, let storage = textView.textStorage else { return }
        let current = document.highlightsVersion == document.version
        let version = current ? document.highlightsVersion : -1
        if let appliedStyles, appliedStyles.version == version, appliedStyles.diagnostics == document.diagnostics { return }
        // Colours for older text would land on the wrong words; until the new ones come, the text stays as it was.
        guard current || appliedStyles == nil else { return }
        appliedStyles = (version, document.diagnostics)
        let length = storage.length
        let whole = NSRange(location: 0, length: length)
        storage.beginEditing()
        storage.setAttributes(CodeTheme.plain, range: whole)
        if current {
            for highlight in document.highlights {
                let range = NSRange(location: highlight.range.lowerBound, length: highlight.range.count)
                guard NSMaxRange(range) <= length else { continue }
                storage.addAttributes(CodeTheme.attributes(for: highlight.style), range: range)
            }
        }
        for diagnostic in document.diagnostics where diagnostic.uri == nil || diagnostic.uri == document.uri {
            var range = NSRange(document.lines.range(of: diagnostic.range))
            if range.length == 0 { range.length = min(1, length - range.location) }
            guard range.location >= 0, NSMaxRange(range) <= length, range.length > 0 else { continue }
            storage.addAttributes([
                .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                .underlineColor: diagnostic.isError ? CodeTheme.error : CodeTheme.warning,
                .toolTip: diagnostic.message,
            ], range: range)
        }
        storage.endEditing()
        textView.typingAttributes = CodeTheme.plain
    }

    // MARK: The canvas and the text

    /// Lights the lines of the modules selected and hovered on the canvas, and scrolls to a module selected there.
    func follow(selection: Set<String>, hovered: StageHit?) {
        guard let textView else { return }
        var lit: [CodeTextView.LitLines] = []
        for key in selection {
            if let range = document.range(of: key) { lit.append(.init(range: NSRange(range), color: CodeTheme.selectedLines)) }
        }
        if case .tile(let key)? = hovered, !selection.contains(key), let range = document.range(of: key) {
            lit.append(.init(range: NSRange(range), color: CodeTheme.hoveredLines))
        }
        if lit != textView.lit {
            textView.lit = lit
            textView.needsDisplay = true
        }
        // A selection made on the canvas brings its line into view; one the cursor made doesn't move anything.
        if selection.count == 1, let key = selection.first, key != caretKey, let range = document.range(of: key) {
            caretKey = key
            textView.reveal(lineAt: range.lowerBound)
        }
    }

    /// Scrolls to a module or line asked for, once the text knows where it is, and puts the cursor at its start.
    func apply(_ focus: Workspace.TextFocus) {
        guard focus.id != appliedFocus, let textView else { return }
        let start: Int
        if let key = focus.key {
            guard let range = document.range(of: key) else { return }
            start = range.lowerBound
            caretKey = key
        } else if let line = focus.line {
            start = document.lines.range(ofLine: line).lowerBound
        } else {
            return
        }
        appliedFocus = focus.id
        let line = NSRange(document.lines.range(ofLine: document.lines.line(at: start)))
        settingSelection = true
        textView.setSelectedRange(NSRange(location: start, length: 0))
        settingSelection = false
        textView.reveal(lineAt: start)
        textView.showFindIndicator(for: line)
    }

    /// The pointer is over `offset` in the text, or has left it: the canvas lights that line's module.
    func pointed(at offset: Int?) {
        let key = offset.flatMap { document.module(atLine: document.lines.line(at: $0)) }
        if stage.pointedFromText != key { stage.pointedFromText = key }
    }

    // MARK: Hovers

    /// Shows what the language server says about the word under the pointer, once it has rested there.
    func rested(at offset: Int?, rect: NSRect?) {
        hoverTask?.cancel()
        guard let offset, let rect else {
            popover?.close()
            return
        }
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self, !Task.isCancelled, let text = await self.document.hover(at: offset), !text.isEmpty, !Task.isCancelled else { return }
            self.showHover(text, at: rect)
        }
    }

    private func showHover(_ markdown: String, at rect: NSRect) {
        guard let textView, textView.window != nil else { return }
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        let content = HoverText(markdown: markdown)
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        self.popover = popover
    }

    func closeHover() {
        hoverTask?.cancel()
        popover?.close()
    }

    // MARK: Completions

    /// Asks the language server what could be typed here, then shows the list.
    func complete(at offset: Int) {
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            guard let self else { return }
            let items = await self.document.completions(at: offset)
            guard !Task.isCancelled, let textView = self.textView, textView.selectedRange().location == offset, !items.isEmpty else { return }
            self.completions = (offset, items)
            textView.complete(nil)
        }
    }
}

/// A hover's markdown, as the language server wrote it.
struct HoverText: View {
    let markdown: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(markdown.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    if !line.isEmpty {
                        Text((try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .frame(width: 380)
        .frame(maxHeight: 320)
        .font(.callout)
    }
}

/// The text view itself: lines lit for the canvas's selection, indentation kept on new lines, tabs as spaces, and
/// completions from the language server.
final class CodeTextView: NSTextView {
    weak var coordinator: CodeTextCoordinator?

    struct LitLines: Equatable {
        var range: NSRange
        var color: NSColor
    }

    /// Lines to light behind the text: the modules selected or hovered on the canvas.
    var lit: [LitLines] = []
    private var tracking: NSTrackingArea?

    func configure(readOnly: Bool) {
        isEditable = !readOnly
        isSelectable = true
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        drawsBackground = true
        backgroundColor = CodeTheme.background
        insertionPointColor = CodeTheme.caret
        selectedTextAttributes = [.backgroundColor: CodeTheme.selection]
        typingAttributes = CodeTheme.plain
        font = CodeTheme.font
        textContainerInset = NSSize(width: 6, height: 8)
        // Lines run on rather than wrap, as code does.
        isHorizontallyResizable = true
        isVerticallyResizable = true
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        setAccessibilityLabel("Meeplang")
    }

    /// Scrolls just enough to show the start of the line holding `offset`, so a long line doesn't scroll the text
    /// sideways.
    func reveal(lineAt offset: Int) {
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: min(offset, text.length), length: 0))
        scrollRangeToVisible(NSRange(location: line.location, length: 0))
        // A line starts at the left edge, so the text scrolls fully left to show it.
        if let scroll = enclosingScrollView, scroll.contentView.bounds.origin.x != 0 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.origin.y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    // MARK: Lit lines

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        for line in lit {
            for frame in lineFrames(of: line.range) where frame.intersects(rect) {
                line.color.setFill()
                NSRect(x: rect.minX, y: frame.minY, width: rect.width, height: frame.height).fill()
            }
        }
    }

    /// Where the lines holding `range` are drawn, in this view's coordinates.
    func lineFrames(of range: NSRange) -> [NSRect] {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: max(range.length, 0)) else { return [] }
        var frames: [NSRect] = []
        let origin = textContainerOrigin
        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            frames.append(NSRect(x: frame.minX + origin.x, y: frame.minY + origin.y, width: frame.width, height: frame.height))
            return fragment.rangeInElement.endLocation.compare(end) == .orderedAscending
        }
        return frames
    }

    // MARK: Typing

    /// A new line starts as indented as the one before, since indentation is how Meeplang nests modules.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let caret = selectedRange().location
        let lineStart = text.lineRange(for: NSRange(location: min(caret, text.length), length: 0)).location
        var indent = ""
        var index = lineStart
        while index < caret, index < text.length, let scalar = Unicode.Scalar(text.character(at: index)), scalar == " " || scalar == "\t" {
            indent.append(Character(scalar))
            index += 1
        }
        super.insertNewline(sender)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
    }

    /// Tabs become four spaces, as Meeplang is written.
    override func insertTab(_ sender: Any?) {
        insertText("    ", replacementRange: selectedRange())
    }

    // MARK: Pointing

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let offset = characterIndexForInsertion(at: point)
        let inText = offset >= 0 && offset <= (string as NSString).length
        coordinator?.pointed(at: inText ? offset : nil)
        guard inText, let word = wordRect(at: offset, near: point) else {
            coordinator?.rested(at: nil, rect: nil)
            return
        }
        coordinator?.rested(at: offset, rect: word)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        coordinator?.pointed(at: nil)
        coordinator?.rested(at: nil, rect: nil)
    }

    override func keyDown(with event: NSEvent) {
        coordinator?.closeHover()
        super.keyDown(with: event)
    }

    /// The word at `offset`, in this view's coordinates, if the pointer is on it.
    private func wordRect(at offset: Int, near point: NSPoint) -> NSRect? {
        let text = string as NSString
        guard offset < text.length else { return nil }
        let word = selectionRange(forProposedRange: NSRange(location: offset, length: 0), granularity: .selectByWord)
        guard word.length > 0, let window else { return nil }
        let screen = firstRect(forCharacterRange: word, actualRange: nil)
        let inWindow = window.convertFromScreen(screen)
        let rect = convert(inWindow, from: nil)
        return rect.insetBy(dx: -2, dy: -2).contains(point) ? rect : nil
    }

    // MARK: Completions

    /// ⎋ or F5 asks the language server; its suggestions show when they come.
    override func complete(_ sender: Any?) {
        let caret = selectedRange().location
        if let completions = coordinator?.completions, completions.offset == caret {
            super.complete(sender)
            coordinator?.completions = nil
        } else {
            coordinator?.complete(at: caret)
        }
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let typed = (string as NSString).substring(with: charRange).lowercased()
        let items = coordinator?.completions?.items ?? []
        let labels = items.map { $0.insertText ?? $0.label }.filter { typed.isEmpty || $0.lowercased().hasPrefix(typed) }
        index.pointee = labels.isEmpty ? -1 : 0
        return labels
    }
}

/// A scroll view that puts its vertical ruler beside the text rather than over it, as it otherwise does here.
final class CodeScrollView: NSScrollView {
    override func tile() {
        super.tile()
        guard rulersVisible, hasVerticalRuler, let ruler = verticalRulerView else { return }
        let width = ruler.ruleThickness
        var clip = contentView.frame
        guard clip.minX < width else { return }
        clip.size.width -= width - clip.minX
        clip.origin.x = width
        contentView.frame = clip
        ruler.frame = NSRect(x: 0, y: clip.minY, width: width, height: clip.height)
        if let scroller = horizontalScroller, hasHorizontalScroller {
            var frame = scroller.frame
            frame.size.width -= max(0, width - frame.minX)
            frame.origin.x = max(frame.minX, width)
            scroller.frame = frame
        }
    }
}

/// Line numbers, and beside each module's first line its messages a second and a sparkline of the last minute, with
/// a mark on lines that have problems (design, section 2, level 2).
final class GutterView: NSRulerView {
    private weak var coordinator: CodeTextCoordinator?
    private var timer: Timer?

    init(scrollView: NSScrollView, coordinator: CodeTextCoordinator) {
        self.coordinator = coordinator
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = scrollView.documentView
        ruleThickness = 104
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        setAccessibilityLabel("Line numbers and counts")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Counts are refreshed once a second, as level 2 has them, while it's in a window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    @objc private func scrolled() { needsDisplay = true }

    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        CodeTheme.gutter.setFill()
        bounds.fill()
        CodeTheme.gutterEdge.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        guard let coordinator, let textView = coordinator.textView, let layout = textView.textLayoutManager,
              let content = layout.textContentManager else { return }
        let document = coordinator.document
        let stage = coordinator.stage
        let visible = textView.visibleRect
        let origin = textView.textContainerOrigin
        let problemLines = Set(document.diagnostics.filter { $0.uri == nil || $0.uri == document.uri }.map(\.range.start.line))
        let start = layout.textLayoutFragment(for: NSPoint(x: 0, y: max(visible.minY - origin.y, 0)))?.rangeInElement.location ?? content.documentRange.location

        layout.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame.offsetBy(dx: origin.x, dy: origin.y)
            if frame.minY > visible.maxY { return false }
            let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
            let line = document.lines.line(at: offset)
            let top = convert(NSPoint(x: 0, y: frame.minY), from: textView).y
            let height = fragment.textLineFragments.first?.typographicBounds.height ?? frame.height
            self.drawLine(line, top: top, height: height, problem: problemLines.contains(line), keys: document.modulesByLine[line] ?? [], stage: stage)
            return true
        }
    }

    private func drawLine(_ line: Int, top: CGFloat, height: CGFloat, problem: Bool, keys: [String], stage: PipelineStage) {
        let number = NSAttributedString(string: "\(line + 1)", attributes: CodeTheme.lineNumber)
        let size = number.size()
        let middle = top + height / 2
        number.draw(at: NSPoint(x: bounds.maxX - 8 - size.width, y: middle - size.height / 2))
        if problem {
            CodeTheme.error.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: middle - 3, width: 6, height: 6)).fill()
        }
        // A module's counts: its rate, and its last minute as a sparkline, from the running module with its key.
        guard let key = keys.first, let module = stage.module(key) else { return }
        guard let live = module.live, stage.isCurrent else {
            if module.isNew {
                let note = NSAttributedString(string: "new", attributes: CodeTheme.gutterNote)
                note.draw(at: NSPoint(x: 14, y: middle - note.size().height / 2))
            }
            return
        }
        let failing = live.rates[.failed] + live.rates[.refused]
        let rate = NSAttributedString(string: StageFormat.rate(live.activity), attributes: failing > 0.05 ? CodeTheme.gutterFailing : CodeTheme.gutterRate)
        let rateSize = rate.size()
        rate.draw(at: NSPoint(x: 52 - rateSize.width, y: middle - rateSize.height / 2))
        let samples = live.history.samples
        guard samples.count > 1 else { return }
        let box = NSRect(x: 56, y: middle - 6, width: 26, height: 12)
        let highest = max(samples.max() ?? 0, 0.001)
        let path = NSBezierPath()
        for (index, sample) in samples.enumerated() {
            let point = NSPoint(
                x: box.minX + box.width * CGFloat(index) / CGFloat(max(samples.count - 1, 1)),
                y: box.maxY - box.height * CGFloat(sample / highest)
            )
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.lineWidth = 1
        (failing > 0.05 ? CodeTheme.error : CodeTheme.spark).setStroke()
        path.stroke()
    }
}

/// The text's colours: the canvas's palette, on its off-black.
@MainActor
enum CodeTheme {
    static let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    static let background = NSColor(hex: 0x131418)
    static let gutter = NSColor(hex: 0x16171C)
    static let gutterEdge = NSColor(hex: 0x262932)
    static let text = NSColor(hex: 0xD6DAE2)
    static let caret = NSColor(hex: 0x39D5FF)
    static let selection = NSColor(hex: 0x2D4A66)
    static let selectedLines = NSColor(hex: 0x39D5FF, alpha: 0.10)
    static let hoveredLines = NSColor(hex: 0xFFFFFF, alpha: 0.05)
    static let error = NSColor(hex: 0xFF4D5E)
    static let warning = NSColor(hex: 0xFF9A3D)
    static let spark = NSColor(hex: 0x39D5FF, alpha: 0.8)

    static let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: text]
    static let lineNumber: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular), .foregroundColor: NSColor(hex: 0x5C6272),
    ]
    static let gutterRate: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor(hex: 0x8C93A3),
    ]
    static let gutterFailing: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: error,
    ]
    static let gutterNote: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: NSColor(hex: 0x5C6272),
    ]

    static func attributes(for style: TokenStyle) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color(for: style)]
        switch style {
        case .verb, .keyword: attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .semibold)
        case .comment: attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        default: break
        }
        return attributes
    }

    static func color(for style: TokenStyle) -> NSColor {
        switch style {
        case .keyword: NSColor(hex: 0xFF7AB6)
        case .verb: NSColor(hex: 0x39D5FF)
        case .method: NSColor(hex: 0x7CC8FF)
        case .namespace: NSColor(hex: 0x9AA7FF)
        case .template: NSColor(hex: 0xC792EA)
        case .parameter: NSColor(hex: 0xFFC23D)
        case .property: NSColor(hex: 0xE0B060)
        case .name: NSColor(hex: 0x6CFF8E)
        case .constant: NSColor(hex: 0xFF9A3D)
        case .builtin: NSColor(hex: 0xFF52D9)
        case .type: NSColor(hex: 0x8C9BFF)
        case .decorator: NSColor(hex: 0xB8BCC6)
        case .string: NSColor(hex: 0xC3E88D)
        case .number: NSColor(hex: 0xF78C6C)
        case .operator: NSColor(hex: 0x89DDFF)
        case .comment: NSColor(hex: 0x6A7286)
        case .variable: text
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
        )
    }
}
