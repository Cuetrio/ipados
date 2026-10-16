import Foundation
import SwiftData

@Model
final class NoteRecord {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var drawingFileName: String? = nil
    var drawingChecksum: String? = nil
    var drawingSchemaVersion: Int

    init(title: String = "", now: Date = .now) {
        self.id = UUID()
        self.title = title
        self.createdAt = now
        self.updatedAt = now
        self.drawingFileName = nil
        self.drawingChecksum = nil
        self.drawingSchemaVersion = 1
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "無題のノート" : trimmed
    }
}
