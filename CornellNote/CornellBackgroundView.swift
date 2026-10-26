import UIKit

/// The fixed Cornell page drawn behind the ink. It is a plain UIView owned by the canvas,
/// so it shares the canvas's lifetime and trait updates without a hosting controller.
final class CornellBackgroundView: UIView {
    private let cueLabel = CornellBackgroundView.makeLabel("Cue / key questions")
    private let notesLabel = CornellBackgroundView.makeLabel("Notes")
    private let summaryLabel = CornellBackgroundView.makeLabel("Summary")

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        isUserInteractionEnabled = false
        layer.cornerRadius = 8
        clipsToBounds = true
        contentMode = .redraw
        [cueLabel, notesLabel, summaryLabel].forEach(addSubview)
        // Line colors are resolved while drawing, so redraw when light/dark appearance changes.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CornellBackgroundView, _) in
            view.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("CornellBackgroundView is created in code")
    }

    private static func makeLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        return label
    }

    private var leftColumn: CGFloat { min(bounds.width * 0.28, 260) }
    private var summaryTop: CGFloat { bounds.height * 0.78 }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 12
        cueLabel.sizeToFit()
        cueLabel.frame.origin = CGPoint(x: inset, y: inset)
        notesLabel.sizeToFit()
        notesLabel.center = CGPoint(x: (bounds.width + bounds.width * 0.28) / 2, y: inset + notesLabel.bounds.height / 2)
        summaryLabel.sizeToFit()
        summaryLabel.frame.origin = CGPoint(x: inset, y: bounds.height - inset - summaryLabel.bounds.height)
    }

    override func draw(_ rect: CGRect) {
        let path = UIBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.move(to: CGPoint(x: leftColumn, y: 0))
        path.addLine(to: CGPoint(x: leftColumn, y: summaryTop))
        path.move(to: CGPoint(x: 0, y: summaryTop))
        path.addLine(to: CGPoint(x: bounds.width, y: summaryTop))
        path.lineWidth = 1
        UIColor.secondaryLabel.withAlphaComponent(0.35).setStroke()
        path.stroke()
    }
}
