import AppKit
import MetalKit
import MetalStage
import Stage
import SwiftUI
import SynesthesiaUI

/// The Mac's canvas surface: a Metal view that draws a stage every frame and turns the pointer, trackpad and mouse
/// into the stage's gestures.
struct MacCanvas: NSViewRepresentable {
    let stage: PipelineStage

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
    private let stage: PipelineStage
    private let renderer: StageRenderer
    private var dragged = false
    /// The tile being ⌥-dragged to move it.
    private var movingTile: String?

    init(stage: PipelineStage, renderer: StageRenderer) {
        self.stage = stage
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = renderer.pixelFormat
        framebufferOnly = true
        preferredFramesPerSecond = 120
        let background = Theme.background
        clearColor = MTLClearColor(red: Double(background.x), green: Double(background.y), blue: Double(background.z), alpha: 1)
        delegate = self
        setAccessibilityRole(.group)
        setAccessibilityLabel("Pipeline \(stage.pipeline.name)")
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
        let snapshot = stage.frame(at: CACurrentMediaTime(), viewSize: bounds.size)
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
        stage.hover(at: location(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        stage.hover(at: nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragged = false
        // ⌥-dragging a tile moves it, and everything under it, under the tile it's dropped on.
        if event.modifierFlags.contains(.option), case .tile(let key)? = stage.hit(at: location(of: event)), stage.editing != nil {
            movingTile = key
        } else {
            movingTile = nil
        }
        if event.clickCount == 2 {
            // The background fits the pipeline; a tile opens its text beside the canvas.
            switch stage.hit(at: location(of: event)) {
            case nil: stage.fit()
            case .tile(let key)?: stage.requestText(at: key)
            case .wire?: break
            }
        }
    }

    /// Dragging moves the view; ⌥-dragging a tile moves its branch, lighting the tile it would go under.
    override func mouseDragged(with event: NSEvent) {
        dragged = true
        if let movingTile {
            NSCursor.dragCopy.set()
            if case .tile(let key)? = stage.hit(at: location(of: event)), key != movingTile {
                stage.dropTarget = .tile(key)
            } else {
                stage.dropTarget = nil
            }
            return
        }
        NSCursor.closedHand.set()
        stage.pan(by: CGVector(dx: event.deltaX, dy: event.deltaY))
        stage.hover(at: nil)
    }

    override func mouseUp(with event: NSEvent) {
        if let moving = movingTile {
            movingTile = nil
            NSCursor.arrow.set()
            if case .tile(let target)? = stage.dropTarget {
                stage.editing?.move(moving, under: target)
            }
            stage.dropTarget = nil
            if dragged { return }
        }
        if dragged {
            NSCursor.arrow.set()
            stage.hover(at: location(of: event))
        } else {
            stage.click(at: location(of: event), modifiers: event.modifierFlags.contains(.command) ? .command : [])
        }
    }

    /// Two fingers or the wheel move the view; with ⌘ held they zoom, around the pointer.
    override func scrollWheel(with event: NSEvent) {
        let point = location(of: event)
        if event.modifierFlags.contains(.command) {
            let lines = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 40 : event.scrollingDeltaY / 4
            stage.zoom(by: exp(lines * 0.5), at: point)
        } else {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
            stage.pan(by: CGVector(dx: event.scrollingDeltaX * scale, dy: event.scrollingDeltaY * scale))
        }
        stage.hover(at: point)
    }

    override func magnify(with event: NSEvent) {
        stage.zoom(by: 1 + event.magnification, at: location(of: event))
    }

    override func smartMagnify(with event: NSEvent) {
        stage.fit()
    }

    // MARK: Editing

    /// ⌫ deletes the selected modules; ⌥⌫ deletes them with everything under them.
    override func keyDown(with event: NSEvent) {
        let delete = event.keyCode == 51 || event.keyCode == 117
        if delete, !stage.selection.isEmpty, let editing = stage.editing {
            editing.delete(stage.selection, branch: event.modifierFlags.contains(.option))
        } else {
            super.keyDown(with: event)
        }
    }

    /// A tile's menu: show it in the text, or delete it.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard case .tile(let key)? = stage.hit(at: location(of: event)) else { return nil }
        if !stage.selection.contains(key) { stage.select([key], reveal: false) }
        let keys = stage.selection
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Show in Text") { [stage] in stage.requestText(at: key) })
        if let editing = stage.editing {
            menu.addItem(.separator())
            let label = keys.count == 1 ? "Delete" : "Delete \(keys.count) Modules"
            menu.addItem(ClosureMenuItem(label) { editing.delete(keys, branch: false) })
            menu.addItem(ClosureMenuItem(label + " with Everything Under It") { editing.delete(keys, branch: true) })
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "⌥-drag a tile onto another to move it there", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        return menu
    }

    /// ⌘Z on the canvas undoes the text's last change, whether it was typed or made here.
    override var undoManager: UndoManager? {
        stage.editing?.undoManager ?? super.undoManager
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

    // MARK: VoiceOver

    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityChildren() -> [Any]? {
        guard let window else { return [] }
        return stage.accessibilityItems().map { item in
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
