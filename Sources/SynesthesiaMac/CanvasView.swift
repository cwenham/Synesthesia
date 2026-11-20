import AppKit
import MetalKit
import MetalStage
import Stage
import SwiftUI
import SynesthesiaUI

/// The Mac's canvas surface: a Metal view that draws the Continuum every frame and turns the pointer, trackpad and
/// mouse into its gestures, and those of the pipeline under the pointer when its tiles are drawn.
struct MacCanvas: NSViewRepresentable {
    let stage: ContinuumStage

    /// One renderer for the app, so the glyph atlas is shared by every canvas.
    @MainActor static let renderer = StageRenderer()

    static var provider: CanvasSurfaceProvider {
        CanvasSurfaceProvider { stage in
            if renderer == nil {
                return AnyView(ContentUnavailableView("Metal isn't available", systemImage: "exclamationmark.triangle",
                                                      description: Text("The canvas needs a Metal GPU.")))
            }
            return AnyView(MacCanvas(stage: stage))
        }
    }

    func makeNSView(context: Context) -> CanvasMTKView {
        CanvasMTKView(stage: stage, renderer: Self.renderer!)
    }

    func updateNSView(_ view: CanvasMTKView, context: Context) {}
}

final class CanvasMTKView: MTKView, MTKViewDelegate, NSMenuItemValidation {
    private let canvas: ContinuumStage
    private let renderer: StageRenderer
    private var dragged = false
    /// The tile pressed on, which a drag moves, and the pipeline it's in.
    private var pressedTile: String?
    private var pressedStage: PipelineStage?
    /// The pipeline under the pointer, or the one in focus, for keys, menus and drops.
    private var stage: PipelineStage? { canvas.focusedStage }
    /// Where the mouse went down, to tell a drag from a click.
    private var pressedAt: CGPoint = .zero

    init(stage: ContinuumStage, renderer: StageRenderer) {
        canvas = stage
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = renderer.pixelFormat
        framebufferOnly = true
        preferredFramesPerSecond = 120
        let background = Theme.current.canvas.background
        clearColor = MTLClearColor(red: Double(background.x), green: Double(background.y), blue: Double(background.z), alpha: 1)
        delegate = self
        // Verbs from the palette and messages from probes are dropped here, as text.
        registerForDraggedTypes([.string])
        setAccessibilityRole(.group)
        setAccessibilityLabel("The Continuum: hosts and their pipelines")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Points from the top left, as the stage has them.
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { drawFrame() }
    }

    private func drawFrame() {
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
              let commands = renderer.makeCommandBuffer() else { return }
        let snapshot = canvas.frame(at: CACurrentMediaTime(), viewSize: bounds.size)
        renderer.encode(snapshot, into: commands, pass: pass, size: bounds.size, pixelScale: window?.backingScaleFactor ?? 2)
        commands.present(drawable)
        commands.commit()
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func location(of event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseMoved(with event: NSEvent) {
        canvas.hover(at: location(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        canvas.hover(at: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragged = false
        // A drag that starts on a tile moves it, and everything under it, under the tile it's dropped on; one that
        // starts on the background moves the view.
        pressedAt = location(of: event)
        pressedTile = nil
        pressedStage = nil
        if case .inside(_, .tile(let key))? = canvas.hit(at: pressedAt), let under = canvas.pipelineStage(at: pressedAt),
           under.editing != nil, !event.modifierFlags.contains(.command) {
            pressedTile = key
            pressedStage = under
        }
        if event.clickCount == 2 {
            // A tile opens its text beside the canvas; a pipeline or host is zoomed into; the background shows all.
            canvas.doubleClick(at: pressedAt)
        }
    }

    /// Dragging the background moves the view; dragging a tile carries its ghost, lighting the tile it would go under.
    override func mouseDragged(with event: NSEvent) {
        let point = location(of: event)
        if let pressedTile, let pressedStage {
            // A few points of wobble is still a click.
            guard dragged || hypot(point.x - pressedAt.x, point.y - pressedAt.y) > 4 else { return }
            dragged = true
            NSCursor.closedHand.set()
            canvas.hover(at: nil)
            pressedStage.dragTile(pressedTile, to: point)
            return
        }
        dragged = true
        NSCursor.closedHand.set()
        canvas.pan(by: CGVector(dx: event.deltaX, dy: event.deltaY))
        canvas.hover(at: nil)
    }

    override func mouseUp(with event: NSEvent) {
        if let moving = pressedTile, let pressedStage, dragged {
            pressedTile = nil
            self.pressedStage = nil
            NSCursor.arrow.set()
            pressedStage.editing?.move(moving, under: pressedStage.endTileDrag())
            return
        }
        pressedTile = nil
        pressedStage = nil
        if dragged {
            NSCursor.arrow.set()
            canvas.hover(at: location(of: event))
        } else if event.clickCount < 2 {
            canvas.click(at: location(of: event), modifiers: event.modifierFlags.contains(.command) ? .command : [])
        }
    }

    /// Two fingers or the wheel move the view; with ⌘ held they zoom, around the pointer.
    override func scrollWheel(with event: NSEvent) {
        let point = location(of: event)
        if event.modifierFlags.contains(.command) {
            let lines = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY / 4
            canvas.zoom(by: exp(lines * 0.5), at: point)
        } else {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            canvas.pan(by: CGVector(dx: event.scrollingDeltaX * scale, dy: event.scrollingDeltaY * scale))
        }
        canvas.hover(at: point)
    }

    override func magnify(with event: NSEvent) {
        canvas.zoom(by: 1 + event.magnification, at: location(of: event))
    }

    override func smartMagnify(with event: NSEvent) {
        canvas.doubleClick(at: location(of: event))
    }

    // MARK: Editing

    /// ⌫ deletes the selected modules; ⌥⌫ deletes them with everything under them.
    override func keyDown(with event: NSEvent) {
        let delete = event.keyCode == 51 || event.keyCode == 117
        if delete, let stage, !stage.selection.isEmpty, let editing = stage.editing {
            editing.delete(stage.selection, branch: event.modifierFlags.contains(.option))
        } else {
            super.keyDown(with: event)
        }
    }

    /// A tile's menu: probe it, send it a message, show it in the text, or delete it. A wire's: probe it.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let stage = canvas.pipelineStage(at: location(of: event)) else { return nil }
        let hit = stage.hit(at: location(of: event))
        if case .wire(let key)? = hit, let editing = stage.editing {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem("Probe Wire") { editing.probe(.wire(key)) })
            return menu
        }
        guard case .tile(let key)? = hit else { return nil }
        if !stage.selection.contains(key) { stage.select([key], reveal: false) }
        let keys = stage.selection
        let menu = NSMenu()
        if let editing = stage.editing {
            menu.addItem(ClosureMenuItem("Probe Output") { editing.probe(.module(key)) })
            menu.addItem(ClosureMenuItem("Send a Message…") { editing.compose(into: key) })
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem("Show in Text") { [stage] in stage.requestText(at: key) })
        if let editing = stage.editing {
            menu.addItem(.separator())
            let label = keys.count == 1 ? "Delete" : "Delete \(keys.count) Modules"
            menu.addItem(ClosureMenuItem(label) { editing.delete(keys, branch: false) })
            menu.addItem(ClosureMenuItem(label + " with Everything Under It") { editing.delete(keys, branch: true) })
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "Drag a tile onto another to move it there", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        return menu
    }

    /// ⌘Z on the canvas undoes the text's last change, whether it was typed or made here.
    override var undoManager: UndoManager? {
        stage?.editing?.undoManager ?? super.undoManager
    }

    @objc func undo(_ sender: Any?) {
        undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        undoManager?.redo()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            item.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo ?? false
        case #selector(redo(_:)):
            item.title = undoManager?.redoMenuItemTitle ?? "Redo"
            return undoManager?.canRedo ?? false
        default:
            return true
        }
    }

    // MARK: Drops

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    /// The pipeline a drop would go to: the one drawn in full under the pointer, if it can be edited.
    private func dropStage(_ sender: any NSDraggingInfo) -> PipelineStage? {
        guard let under = canvas.pipelineStage(at: convert(sender.draggingLocation, from: nil)), under.editing != nil else { return nil }
        return under
    }

    /// Lights what a drop would land on: a tile, or a wire.
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.availableType(from: [.string]) != nil, let under = dropStage(sender) else {
            clearDropTargets()
            return []
        }
        // While something is dragged over, what it would land on is lit, and nothing shows as hovered.
        canvas.hover(at: nil)
        clearDropTargets(except: under)
        under.dropTarget = under.hit(at: convert(sender.draggingLocation, from: nil))
        return .copy
    }

    private func clearDropTargets(except kept: PipelineStage? = nil) {
        for pipeline in canvas.continuum.hosts.flatMap(\.pipelines) {
            let stage = canvas.stage(for: pipeline)
            if stage !== kept { stage.dropTarget = nil }
        }
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearDropTargets()
        canvas.hover(at: nil)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        clearDropTargets()
        guard let under = dropStage(sender), let payload = sender.draggingPasteboard.string(forType: .string), let editing = under.editing else { return false }
        let hit = under.hit(at: convert(sender.draggingLocation, from: nil))
        window?.makeFirstResponder(self)
        return editing.drop(payload, on: hit)
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        clearDropTargets()
    }

    // MARK: VoiceOver

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityChildren() -> [Any]? {
        guard let window else { return [] }
        return canvas.accessibilityItems().map { item in
            let onScreen = window.convertToScreen(convert(item.frame, to: nil))
            let role: NSAccessibility.Role = if case .tile = item.hit { .button } else { .unknown }
            return NSAccessibilityElement.element(withRole: role, frame: onScreen, label: item.label, parent: self)
        }
    }
}

/// A menu item that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(_ title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func runAction() {
        run()
    }
}
