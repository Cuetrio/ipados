import PencilKit
import SwiftUI
import UIKit.UIGestureRecognizerSubclass

struct SecondFingerGate {
    enum Action: Equatable {
        case none, disableDrawing, enableDrawing
    }

    private(set) var isBlocked = false

    mutating func update(directTouches: Int, pencilTouches: Int) -> Action {
        if isBlocked {
            if directTouches == 0 && pencilTouches == 0 {
                isBlocked = false
                return .enableDrawing
            }
        } else if directTouches >= 2 && pencilTouches == 0 {
            isBlocked = true
            return .disableDrawing
        }
        return .none
    }
}

/// Observes input without recognizing a gesture or delaying delivery to PencilKit and the scroll view.
private final class TouchObserver: UIGestureRecognizer {
    var onChange: ((Int, Int) -> Void)?
    private var activeTouches: Set<UITouch> = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouches.formUnion(touches.filter { $0.type == .direct || $0.type == .pencil })
        notifyChange()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    private func finish(_ touches: Set<UITouch>) {
        activeTouches.subtract(touches)
        notifyChange()
    }

    private func notifyChange() {
        onChange?(activeTouches.filter { $0.type == .direct }.count,
                  activeTouches.filter { $0.type == .pencil }.count)
    }
}

/// Keeps drawing undo/redo separate from the title field and other window-level edits,
/// and carries the fixed Cornell background so it pans and zooms with the ink.
final class NoteCanvasView: PKCanvasView, UIGestureRecognizerDelegate {
    private let drawingHistory = UndoManager()
    private let backgroundView = CornellBackgroundView()
    private var secondFingerGate = SecondFingerGate()
    var onStrokeCancelled: (() -> Void)?

    override var undoManager: UndoManager? { drawingHistory }

    override init(frame: CGRect) {
        super.init(frame: frame)
        insertSubview(backgroundView, at: 0)
        installFocusTap()
        installTouchObserver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        insertSubview(backgroundView, at: 0)
        installFocusTap()
        installTouchObserver()
    }

    private func installTouchObserver() {
        let observer = TouchObserver()
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        observer.delegate = self
        observer.onChange = { [weak self] direct, pencil in
            guard let self else { return }
            switch self.secondFingerGate.update(directTouches: direct, pencilTouches: pencil) {
            case .disableDrawing:
                self.cancelInProgressStroke()
            case .enableDrawing:
                self.drawingGestureRecognizer.isEnabled = true
            case .none:
                break
            }
        }
        addGestureRecognizer(observer)
    }

    func cancelInProgressStroke() {
        drawingGestureRecognizer.isEnabled = false
        onStrokeCancelled?()
    }

    private func installFocusTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(focusFromTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    @objc private func focusFromTap() {
        restoreDrawingFocus()
    }

    func restoreDrawingFocus() {
        if Self.shouldRestoreDrawingFocus(isEditable: isUserInteractionEnabled, isFirstResponder: isFirstResponder) {
            becomeFirstResponder()
        }
    }

    static func shouldRestoreDrawingFocus(isEditable: Bool, isFirstResponder: Bool) -> Bool {
        isEditable && !isFirstResponder
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
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
        sendSubviewToBack(backgroundView)
    }
}

struct CanvasView: UIViewRepresentable {
    let canvasView: NoteCanvasView
    var isEditable = true
    var onDrawingChanged: (PKDrawing) -> Void = { _ in }
    var onStrokeChanged: (Bool) -> Void = { _ in }

    /// PencilKit stores ink in its light-appearance color and adapts it for dark mode itself,
    /// so the default pen is plain black (shown white in dark mode), not a dynamic color.
    static let initialTool = PKInkingTool(.pen, color: .black, width: 3)

    func makeCoordinator() -> Coordinator {
        Coordinator(onDrawingChanged: onDrawingChanged, onStrokeChanged: onStrokeChanged)
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
        context.coordinator.observeCancellation(of: canvasView)
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
        uiView.onStrokeCancelled = nil
        uiView.resignFirstResponder()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let onDrawingChanged: (PKDrawing) -> Void
        let toolPicker = PKToolPicker()
        var appliedEditable: Bool?

        let onStrokeChanged: (Bool) -> Void

        init(onDrawingChanged: @escaping (PKDrawing) -> Void, onStrokeChanged: @escaping (Bool) -> Void) {
            self.onDrawingChanged = onDrawingChanged
            self.onStrokeChanged = onStrokeChanged
        }

        func observeCancellation(of canvasView: NoteCanvasView) {
            canvasView.onStrokeCancelled = { [weak self, weak canvasView] in
                guard let self, let canvasView else { return }
                self.canvasViewDidEndUsingTool(canvasView)
            }
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            (canvasView as? NoteCanvasView)?.restoreDrawingFocus()
            onStrokeChanged(true)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            onDrawingChanged(canvasView.drawing)
            onStrokeChanged(false)
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
