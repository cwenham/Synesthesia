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

final class CanvasMTKView: MTKView, MTKViewDelegate {
    private let stage: PipelineStage
    private let renderer: StageRenderer
    private var dragged = false

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
        if event.clickCount == 2, stage.hit(at: location(of: event)) == nil {
            stage.fit()
        }
    }

    /// Dragging moves the view, until editing on the canvas (step 5) gives tiles their own drags.
    override func mouseDragged(with event: NSEvent) {
        dragged = true
        NSCursor.closedHand.set()
        stage.pan(by: CGVector(dx: event.deltaX, dy: event.deltaY))
        stage.hover(at: nil)
    }

    override func mouseUp(with event: NSEvent) {
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
