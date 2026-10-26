import PencilKit
import SwiftUI

/// Keeps drawing undo/redo separate from the title field and other window-level edits,
/// and carries the fixed Cornell background so it pans and zooms with the ink.
final class NoteCanvasView: PKCanvasView {
    private let drawingHistory = UndoManager()
    private let backgroundView = CornellBackgroundView()

    override var undoManager: UndoManager? { drawingHistory }

    override init(frame: CGRect) {
        super.init(frame: frame)
        insertSubview(backgroundView, at: 0)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        insertSubview(backgroundView, at: 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Lay out the page at the unzoomed canvas size, then scale it like the ink. Scroll view
        // subviews already follow the content offset, so only the zoom scale needs applying.
        let pageSize = bounds.size
        backgroundView.transform = .identity
        backgroundView.bounds = CGRect(origin: .zero, size: pageSize)
        backgroundView.center = CGPoint(x: pageSize.width * zoomScale / 2, y: pageSize.height * zoomScale / 2)
        backgroundView.transform = CGAffineTransform(scaleX: zoomScale, y: zoomScale)
        // Render the lines at the zoomed resolution so they stay sharp instead of being upscaled.
        let renderScale = (window?.screen.scale ?? traitCollection.displayScale) * zoomScale
        if backgroundView.contentScaleFactor != renderScale {
            backgroundView.contentScaleFactor = renderScale
            backgroundView.setNeedsDisplay()
        }
        sendSubviewToBack(backgroundView)
    }
}

struct CanvasView: UIViewRepresentable {
    let canvasView: NoteCanvasView
    var isEditable = true
    var onDrawingChanged: (PKDrawing) -> Void = { _ in }

    /// PencilKit stores ink in its light-appearance color and adapts it for dark mode itself,
    /// so the default pen is plain black (shown white in dark mode), not a dynamic color.
    static let initialTool = PKInkingTool(.pen, color: .black, width: 3)

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged)
    }

    func makeUIView(context: Context) -> NoteCanvasView {
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.drawingPolicy = .anyInput
        canvasView.tool = Self.initialTool
        canvasView.alwaysBounceVertical = false
        canvasView.alwaysBounceHorizontal = false
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = 4
        canvasView.delegate = context.coordinator
        canvasView.accessibilityIdentifier = "note-canvas"
        canvasView.accessibilityLabel = "手書き"
        Coordinator.describeStrokes(of: canvasView)

        // The standard picker supplies tools, colors, and widths; the canvas follows its selection.
        let toolPicker = context.coordinator.toolPicker
        toolPicker.selectedTool = Self.initialTool
        toolPicker.showsDrawingPolicyControls = false
        toolPicker.addObserver(canvasView)
        return canvasView
    }

    func updateUIView(_ uiView: NoteCanvasView, context: Context) {
        uiView.isUserInteractionEnabled = isEditable
        context.coordinator.toolPicker.setVisible(isEditable, forFirstResponder: uiView)
        // Change first responder only when editability changes, so title typing keeps its focus.
        guard context.coordinator.appliedEditable != isEditable else { return }
        context.coordinator.appliedEditable = isEditable
        // The picker appears only while the canvas is first responder, which requires a window.
        DispatchQueue.main.async {
            if isEditable {
                uiView.becomeFirstResponder()
            } else {
                uiView.resignFirstResponder()
            }
        }
    }

    static func dismantleUIView(_ uiView: NoteCanvasView, coordinator: Coordinator) {
        coordinator.toolPicker.setVisible(false, forFirstResponder: uiView)
        coordinator.toolPicker.removeObserver(uiView)
        uiView.resignFirstResponder()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let onDrawingChanged: (PKDrawing) -> Void
        let toolPicker = PKToolPicker()
        var appliedEditable: Bool?

        init(onDrawingChanged: @escaping (PKDrawing) -> Void) {
            self.onDrawingChanged = onDrawingChanged
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            Self.describeStrokes(of: canvasView)
            onDrawingChanged(canvasView.drawing)
        }

        /// Tells VoiceOver (and UI tests) how many strokes the note currently holds.
        static func describeStrokes(of canvasView: PKCanvasView) {
            canvasView.accessibilityValue = "線 \(canvasView.drawing.strokes.count) 本"
        }
    }
}
