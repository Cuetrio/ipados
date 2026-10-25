import PencilKit
import SwiftUI

/// Keeps drawing undo/redo separate from the title field and other window-level edits.
final class NoteCanvasView: PKCanvasView {
    private let drawingHistory = UndoManager()

    override var undoManager: UndoManager? { drawingHistory }
}

struct CanvasView: UIViewRepresentable {
    let canvasView: NoteCanvasView
    var isEditable = true
    var onDrawingChanged: (PKDrawing) -> Void = { _ in }

    static let initialTool = PKInkingTool(.pen, color: .label, width: 3)

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
            onDrawingChanged(canvasView.drawing)
        }
    }
}
