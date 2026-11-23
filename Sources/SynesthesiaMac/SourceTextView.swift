import AppKit
import CodeEditing
import ContinuumKit
import FlowKit
import SwiftUI
import SynesthesiaUI

/// The Mac's C# surface (design, section 2, level 1): a read-only TextKit 2 text view of an inflection's file,
/// coloured by ``CSharpText``, its class's lines lit and its declaration revealed, with a gutter giving each
/// inflection's handling times at its class's line.
struct MacSourceText: NSViewRepresentable {
    let code: CodeLevel
    let inflection: InflectionCode
    let workspace: Workspace

    static var provider: SourceTextSurfaceProvider {
        SourceTextSurfaceProvider { code, inflection, workspace in
            AnyView(MacSourceText(code: code, inflection: inflection, workspace: workspace))
        }
    }

    func makeCoordinator() -> SourceTextCoordinator {
        SourceTextCoordinator(code: code, inflection: inflection, workspace: workspace)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let textView = SourceTextView(usingTextLayoutManager: true)
        textView.coordinator = coordinator
        textView.configure()
        coordinator.textView = textView

        let scroll = CodeScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = CodeTheme.background
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        let gutter = SourceGutterView(scrollView: scroll, coordinator: coordinator)
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        coordinator.gutter = gutter
        coordinator.showText()
        NotificationCenter.default.addObserver(coordinator, selector: #selector(SourceTextCoordinator.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // Read here so SwiftUI updates the view when it changes.
        let request = code.revealRequest
        let coordinator = context.coordinator
        if coordinator.textShown?.text != inflection.text?.text { coordinator.showText() }
        coordinator.reveal(request)
        coordinator.gutter?.needsDisplay = true
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: SourceTextCoordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
}

/// Keeps the text view showing the inflection's file, its declaration revealed when asked, and tells the code level
/// which lines are on screen.
@MainActor
final class SourceTextCoordinator: NSObject {
    let code: CodeLevel
    let inflection: InflectionCode
    weak var workspace: Workspace?
    weak var textView: SourceTextView?
    weak var gutter: SourceGutterView?
    private(set) var textShown: CSharpText?
    private var appliedReveal: Int?

    init(code: CodeLevel, inflection: InflectionCode, workspace: Workspace) {
        self.code = code
        self.inflection = inflection
        self.workspace = workspace
    }

    /// Puts the file's text in the view, coloured, with the class's lines lit.
    func showText() {
        guard let textView, let text = inflection.text, let storage = textView.textStorage else { return }
        textShown = text
        let attributed = NSMutableAttributedString(string: text.text, attributes: CodeTheme.plain)
        let length = attributed.length
        for highlight in text.highlights where highlight.range.upperBound <= length {
            attributed.addAttributes(CodeTheme.attributes(for: highlight.style), range: NSRange(location: highlight.range.lowerBound, length: highlight.range.count))
        }
        storage.setAttributedString(attributed)
        if let span = inflection.span {
            let start = text.lines.range(ofLine: span.first).lowerBound
            let end = text.lines.range(ofLine: span.last).upperBound
            textView.lit = NSRange(location: start, length: max(0, end - start))
        } else {
            textView.lit = nil
        }
        appliedReveal = nil
    }

    /// Brings the class into view, its documentation at the top if it fits, and flashes its declaration's line.
    func reveal(_ request: Int) {
        guard request != appliedReveal, let textView, let text = textShown, let line = inflection.declarationLine else { return }
        // Laid out first, or there's nowhere to scroll to.
        guard textView.window != nil else { return }
        appliedReveal = request
        let declaration = text.lines.range(ofLine: line - 1)
        let first = text.lines.range(ofLine: inflection.span?.first ?? line - 1)
        textView.scrollToTop(offset: first.lowerBound, keeping: declaration.lowerBound)
        textView.setSelectedRange(NSRange(location: declaration.lowerBound, length: 0))
        textView.showFindIndicator(for: NSRange(location: declaration.lowerBound, length: declaration.count))
        scrolled()
    }

    /// Tells the code level which lines are on screen, for tools describing the view.
    @objc func scrolled() {
        guard let textView, let text = textShown else { return }
        let lines = textView.visibleLines(in: text.lines)
        if code.visibleLines != lines { code.visibleLines = lines }
    }

    func back() {
        workspace?.closeCode()
    }
}

/// The text view: read-only, selectable and searchable, with the class's lines lit behind the text.
final class SourceTextView: NSTextView {
    weak var coordinator: SourceTextCoordinator?
    /// The class's lines, lit faintly so its extent shows among the others in the file.
    var lit: NSRange? {
        didSet { needsDisplay = true }
    }

    func configure() {
        isEditable = false
        isSelectable = true
        isRichText = false
        importsGraphics = false
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        drawsBackground = true
        backgroundColor = CodeTheme.background
        selectedTextAttributes = [.backgroundColor: CodeTheme.selection]
        font = CodeTheme.font
        textContainerInset = NSSize(width: 6, height: 8)
        isHorizontallyResizable = true
        isVerticallyResizable = true
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        setAccessibilityLabel("C#")
    }

    /// The view has its window, so the class can be revealed now.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let coordinator else { return }
        DispatchQueue.main.async { [weak coordinator] in
            MainActor.assumeIsolated {
                guard let coordinator else { return }
                coordinator.reveal(coordinator.code.revealRequest)
            }
        }
    }

    /// ⎋ goes back to the Meeplang.
    override func cancelOperation(_ sender: Any?) {
        coordinator?.back()
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let lit else { return }
        CodeTheme.classLines.setFill()
        for frame in lineFrames(of: lit) where frame.intersects(rect) {
            NSRect(x: rect.minX, y: frame.minY, width: rect.width, height: frame.height).fill()
        }
    }

    /// Scrolls so the line at `offset` is at the top, as long as the line at `keeping` stays in view, and fully left.
    func scrollToTop(offset: Int, keeping: Int) {
        guard let scroll = enclosingScrollView else { return }
        let target = lineFrames(of: NSRange(location: offset, length: 0)).first
        let kept = lineFrames(of: NSRange(location: keeping, length: 0)).first
        guard let target else { return }
        let height = scroll.contentView.bounds.height
        var y = max(0, target.minY - 6)
        // A long documentation comment mustn't push the declaration off the bottom.
        if let kept, kept.maxY - y > height - 24 { y = max(0, kept.minY - height / 3) }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The lines on screen, from 0.
    func visibleLines(in lines: LineIndex) -> ClosedRange<Int>? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let visible = visibleRect
        let origin = textContainerOrigin
        func offset(at y: CGFloat) -> Int? {
            guard let fragment = layout.textLayoutFragment(for: NSPoint(x: 0, y: max(y - origin.y, 0))) else { return nil }
            return content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
        }
        guard let top = offset(at: visible.minY) else { return nil }
        let bottom = offset(at: visible.maxY - 1) ?? lines.length
        let first = lines.line(at: top)
        return first...max(first, lines.line(at: bottom))
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
}

/// Line numbers, and at each inflection's class the handling times of the modules that run it, merged: the median on
/// the class's line, the 99th percentile on the next, and a small histogram beside them, with the whole figures on
/// hover (design, section 2, level 1).
final class SourceGutterView: LineGutter, NSViewToolTipOwner {
    private weak var coordinator: SourceTextCoordinator?
    /// Each inflection's class line, from 0, for this file.
    private var marks: [Int: InflectionCode] = [:]
    private var tips: [(rect: NSRect, inflection: InflectionCode)] = []

    init(scrollView: NSScrollView, coordinator: SourceTextCoordinator) {
        self.coordinator = coordinator
        super.init(scrollView: scrollView, thickness: 132, label: "Line numbers and handling times")
    }

    override func line(at offset: Int) -> Int {
        coordinator?.textShown?.lines.line(at: offset) ?? 0
    }

    override func willDrawLines() {
        guard let coordinator else { return }
        marks = Dictionary(coordinator.code.marks(sharingFileWith: coordinator.inflection).map { ($0.line, $0.code) }, uniquingKeysWith: { first, _ in first })
        removeAllToolTips()
        tips = []
    }

    override func drawLine(_ line: Int, top: CGFloat, height: CGFloat) {
        let middle = top + height / 2
        drawNumber(line, middle: middle)
        guard let coordinator, let inflection = marks[line] else { return }
        let times = coordinator.code.times(of: inflection)
        let box = NSRect(x: 0, y: top, width: bounds.width - 40, height: height * 2)
        tips.append((box, inflection))
        addToolTip(box, owner: self, userData: nil)
        if inflection.runsHere, coordinator.code.subject.key != nil {
            CodeTheme.runsHere.setFill()
            NSBezierPath(ovalIn: NSRect(x: 4, y: middle - 2.5, width: 5, height: 5)).fill()
        }
        guard !times.uses.isEmpty else { return }
        let merged = times.merged
        guard !merged.isEmpty else {
            let note = NSAttributedString(string: "no times", attributes: CodeTheme.gutterNote)
            note.draw(at: NSPoint(x: 12, y: middle - note.size().height / 2))
            return
        }
        let p50 = NSAttributedString(string: "p50 " + (merged.quantile(0.5).map(TimeText.compact) ?? "—"), attributes: CodeTheme.gutterRate)
        p50.draw(at: NSPoint(x: 12, y: middle - p50.size().height / 2))
        let p99 = NSAttributedString(string: "p99 " + (merged.quantile(0.99).map(TimeText.compact) ?? "—"), attributes: CodeTheme.gutterNote)
        p99.draw(at: NSPoint(x: 12, y: middle + height - p99.size().height / 2))
        drawHistogram(merged, in: NSRect(x: 66, y: top + 2, width: 24, height: height * 2 - 4))
    }

    /// The buckets with any times in them, as bars from fastest to slowest, the median's bar brighter.
    private func drawHistogram(_ histogram: HandlingHistogram, in box: NSRect) {
        var counts = histogram.buckets
        if histogram.zero > 0 { counts.insert(histogram.zero, at: 0) }
        guard let first = counts.firstIndex(where: { $0 > 0 }), let last = counts.lastIndex(where: { $0 > 0 }) else { return }
        var bars = Array(counts[first...last])
        // At most 12 bars: neighbours are added together.
        let group = max(1, Int((Double(bars.count) / 12).rounded(.up)))
        if group > 1 { bars = stride(from: 0, to: bars.count, by: group).map { bars[$0..<min($0 + group, bars.count)].reduce(0, +) } }
        let highest = Double(bars.max() ?? 1)
        let width = box.width / CGFloat(bars.count)
        var seen: Int64 = 0
        let middle = histogram.count / 2
        for (index, count) in bars.enumerated() {
            let before = seen
            seen += count
            guard count > 0 else { continue }
            // Square roots, so a few slow ones still show beside many fast.
            let height = max(1, box.height * CGFloat((Double(count) / highest).squareRoot()))
            let bar = NSRect(x: box.minX + CGFloat(index) * width, y: box.maxY - height, width: max(1, width - 1), height: height)
            (before <= middle && middle < seen ? CodeTheme.spark : CodeTheme.spark.withAlphaComponent(0.45)).setFill()
            bar.fill()
        }
    }

    /// The whole figures, when the pointer rests on an inflection's times.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let coordinator, let tip = tips.first(where: { $0.rect.contains(point) }) else { return "" }
        return coordinator.code.times(of: tip.inflection).summary(named: tip.inflection.name)
    }
}

/// The editors that can open C# at a line, found as installed, and the browser.
@MainActor
enum MacEditors {
    /// Rider first: Meep is C#.
    static let known = [
        ExternalEditor(id: "com.jetbrains.rider", name: "Rider"),
        ExternalEditor(id: "com.microsoft.VSCode", name: "VS Code"),
        ExternalEditor(id: "com.microsoft.VSCodeInsiders", name: "VS Code Insiders"),
    ]

    static var provider: CodeEditors {
        CodeEditors(installed: installed, open: open, browse: { NSWorkspace.shared.open($0) })
    }

    static func installed() -> [ExternalEditor] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.id) != nil }
    }

    /// Opens `path` at `line` in the editor: Rider with `--line`, as JetBrains' command line does on the Mac; VS Code
    /// with its `vscode://file/` address.
    static func open(_ path: String, line: Int?, in editor: ExternalEditor) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.id) else {
            return "\(editor.name) isn't installed."
        }
        let line = max(line ?? 1, 1)
        switch editor.id {
        case "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders":
            var parts = URLComponents()
            parts.scheme = editor.id == "com.microsoft.VSCode" ? "vscode" : "vscode-insiders"
            parts.host = "file"
            parts.path = "\(path):\(line):1"
            guard let url = parts.url else { return "The file's path couldn't be given to \(editor.name)." }
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        default:
            // A new instance hands the file and line to the Rider already running, then quits, as `open -na` does.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--line", "\(line)", path]
            NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        }
        return nil
    }
}
