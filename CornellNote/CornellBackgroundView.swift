import SwiftUI

struct CornellBackgroundView: View {
    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let lineColor = Color.secondary.opacity(0.35)
                let leftColumn = min(size.width * 0.28, 260)
                let summaryTop = size.height * 0.78

                var border = Path()
                border.addRect(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
                context.stroke(border, with: .color(lineColor), lineWidth: 1)

                var vertical = Path()
                vertical.move(to: CGPoint(x: leftColumn, y: 0))
                vertical.addLine(to: CGPoint(x: leftColumn, y: summaryTop))
                context.stroke(vertical, with: .color(lineColor), lineWidth: 1)

                var horizontal = Path()
                horizontal.move(to: CGPoint(x: 0, y: summaryTop))
                horizontal.addLine(to: CGPoint(x: size.width, y: summaryTop))
                context.stroke(horizontal, with: .color(lineColor), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                Text("Cue / key questions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                Text("Summary")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            .overlay(alignment: .top) {
                Text("Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    .padding(.leading, proxy.size.width * 0.28)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
