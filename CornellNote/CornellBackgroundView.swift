import UIKit

/// The fixed Cornell page drawn behind the ink. It is a plain UIView owned by the canvas,
/// so it shares the canvas's lifetime and trait updates without a hosting controller.
///
/// The page and its lines are solid-color layers rather than a drawn bitmap. They need no
/// backing image, so they stay sharp and cost no extra memory at any zoom scale.
final class CornellBackgroundView: UIView {
    private static let lineColor = UIColor.secondaryLabel.withAlphaComponent(0.35)

    private let columnLine = CornellBackgroundView.makeLine()
    private let summaryLine = CornellBackgroundView.makeLine()
    private let cueLabel = CornellBackgroundView.makeLabel("Cue / key questions")
    private let notesLabel = CornellBackgroundView.makeLabel("Notes")
    private let summaryLabel = CornellBackgroundView.makeLabel("Summary")

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        isUserInteractionEnabled = false
        layer.cornerRadius = 8
        layer.borderWidth = 1
        clipsToBounds = true
        [columnLine, summaryLine, cueLabel, notesLabel, summaryLabel].forEach(addSubview)
        updateBorderColor()
        // A layer border takes a fixed CGColor, so resolve it again when the appearance changes.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CornellBackgroundView, _) in
            view.updateBorderColor()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("CornellBackgroundView is created in code")
    }

    private static func makeLine() -> UIView {
        let line = UIView()
        line.backgroundColor = lineColor
        return line
    }

    private static func makeLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        return label
    }

    private func updateBorderColor() {
        layer.borderColor = Self.lineColor.resolvedColor(with: traitCollection).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let leftColumn = min(bounds.width * 0.28, 260)
        let summaryTop = bounds.height * 0.78
        columnLine.frame = CGRect(x: leftColumn - 0.5, y: 0, width: 1, height: summaryTop)
        summaryLine.frame = CGRect(x: 0, y: summaryTop - 0.5, width: bounds.width, height: 1)

        let inset: CGFloat = 12
        cueLabel.sizeToFit()
        cueLabel.frame.origin = CGPoint(x: inset, y: inset)
        notesLabel.sizeToFit()
        notesLabel.center = CGPoint(x: (bounds.width + bounds.width * 0.28) / 2, y: inset + notesLabel.bounds.height / 2)
        summaryLabel.sizeToFit()
        summaryLabel.frame.origin = CGPoint(x: inset, y: bounds.height - inset - summaryLabel.bounds.height)
    }
}
