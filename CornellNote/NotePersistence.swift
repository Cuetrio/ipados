import CryptoKit
import Foundation
import PencilKit
import SwiftData
import UIKit

enum NotePersistenceError: Error {
    case insufficientCapacity
    case invalidDrawingPath
    case checksumMismatch
    case unsupportedDrawingSchema
    case invalidDrawingData
    case metadataCommitFailed
}

enum NoteSaveState: Equatable {
    case saved
    case saving
    case unsavedChanges
    case saveFailed

    var label: String {
        switch self {
        case .saved: return "Saved"
        case .saving: return "Saving"
        case .unsavedChanges: return "Unsaved changes"
        case .saveFailed: return "Save failed"
        }
    }
}

protocol NoteFileSystem: AnyObject {
    var rootURL: URL { get }
    func createDirectory(at url: URL) throws
    func availableCapacity(for url: URL) throws -> Int64
    func writeAndFlush(_ data: Data, to url: URL) throws
    func readData(at url: URL) throws -> Data
    func moveItem(at sourceURL: URL, to destinationURL: URL) throws
    func removeItem(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func fileExists(at url: URL) -> Bool
}

class LocalNoteFileSystem: NoteFileSystem {
    let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.rootURL = applicationSupport.appendingPathComponent("CornellNote", isDirectory: true)
        }
    }

    func createDirectory(at url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func availableCapacity(for url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    func writeAndFlush(_ data: Data, to url: URL) throws {
        try createDirectory(at: url.deletingLastPathComponent())
        fileManager.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [])
    }

    func fileExists(at url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }
}

@MainActor
final class NotePersistenceController {
    static let drawingSchemaVersion = 1

    let modelContext: ModelContext
    let fileSystem: NoteFileSystem
    var clock: () -> Date
    private let commitMetadata: () throws -> Void

    init(
        modelContext: ModelContext,
        fileSystem: NoteFileSystem = LocalNoteFileSystem(),
        clock: @escaping () -> Date = { .now },
        commitMetadata: (() throws -> Void)? = nil
    ) {
        self.modelContext = modelContext
        self.fileSystem = fileSystem
        self.clock = clock
        self.commitMetadata = commitMetadata ?? { try modelContext.save() }
    }

    static func makeContainer(fileSystem: NoteFileSystem, inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema([NoteRecord.self])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            try fileSystem.createDirectory(at: fileSystem.rootURL)
            configuration = ModelConfiguration(
                schema: schema,
                url: fileSystem.rootURL.appendingPathComponent("metadata.store")
            )
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func save(note: NoteRecord, drawing: PKDrawing) throws {
        let data = drawing.dataRepresentation()
        let drawingDirectory = drawingsDirectory(for: note)
        try fileSystem.createDirectory(at: drawingDirectory)
        let capacity = try fileSystem.availableCapacity(for: fileSystem.rootURL)
        guard capacity >= Int64(data.count) else { throw NotePersistenceError.insufficientCapacity }

        let generation = UUID().uuidString.lowercased()
        let checksum = data.sha256Hex
        let finalName = "\(generation)-\(checksum).drawing"
        let temporaryURL = drawingDirectory.appendingPathComponent(".\(generation).tmp")
        let finalURL = drawingDirectory.appendingPathComponent(finalName)

        do {
            try fileSystem.writeAndFlush(data, to: temporaryURL)
            let readBack = try fileSystem.readData(at: temporaryURL)
            guard readBack.sha256Hex == checksum else { throw NotePersistenceError.checksumMismatch }
            guard (try? PKDrawing(data: readBack)) != nil else { throw NotePersistenceError.invalidDrawingData }
            try fileSystem.moveItem(at: temporaryURL, to: finalURL)
        } catch {
            try? fileSystem.removeItem(at: temporaryURL)
            throw error
        }

        let oldFileName = note.drawingFileName
        let oldChecksum = note.drawingChecksum
        let oldSchemaVersion = note.drawingSchemaVersion
        let oldUpdatedAt = note.updatedAt
        note.drawingFileName = relativePath(for: finalURL)
        note.drawingChecksum = checksum
        note.drawingSchemaVersion = Self.drawingSchemaVersion
        note.updatedAt = clock()

        do {
            try commitMetadata()
        } catch {
            note.drawingFileName = oldFileName
            note.drawingChecksum = oldChecksum
            note.drawingSchemaVersion = oldSchemaVersion
            note.updatedAt = oldUpdatedAt
            throw NotePersistenceError.metadataCommitFailed
        }

        cleanupOrphans(for: note)
    }

    func loadDrawing(for note: NoteRecord) throws -> PKDrawing {
        guard let fileName = note.drawingFileName, let expectedChecksum = note.drawingChecksum else {
            return PKDrawing()
        }
        guard note.drawingSchemaVersion == Self.drawingSchemaVersion else {
            throw NotePersistenceError.unsupportedDrawingSchema
        }
        let fileURL = try managedDrawingURL(fileName: fileName, note: note)
        let data = try fileSystem.readData(at: fileURL)
        guard data.sha256Hex == expectedChecksum else { throw NotePersistenceError.checksumMismatch }
        guard let drawing = try? PKDrawing(data: data) else { throw NotePersistenceError.invalidDrawingData }
        return drawing
    }

    @discardableResult
    func regenerateThumbnail(for note: NoteRecord, drawing: PKDrawing) throws -> URL {
        let directory = fileSystem.rootURL.appendingPathComponent("thumbnails", isDirectory: true)
        try fileSystem.createDirectory(at: directory)
        let url = directory.appendingPathComponent("\(note.id.uuidString).png")
        let image = drawing.image(from: CGRect(x: 0, y: 0, width: 1200, height: 900), scale: 1)
        guard let data = image.pngData() else { throw NotePersistenceError.invalidDrawingData }
        try fileSystem.writeAndFlush(data, to: url)
        return url
    }

    func thumbnailData(for note: NoteRecord) throws -> Data? {
        let url = fileSystem.rootURL
            .appendingPathComponent("thumbnails", isDirectory: true)
            .appendingPathComponent("\(note.id.uuidString).png")
        guard fileSystem.fileExists(at: url) else { return nil }
        return try fileSystem.readData(at: url)
    }

    func delete(note: NoteRecord) throws {
        modelContext.delete(note)
        do {
            try commitMetadata()
        } catch {
            modelContext.insert(note)
            throw NotePersistenceError.metadataCommitFailed
        }
        try fileSystem.removeItem(at: drawingsDirectory(for: note))
        try fileSystem.removeItem(at: fileSystem.rootURL.appendingPathComponent("thumbnails", isDirectory: true).appendingPathComponent("\(note.id.uuidString).png"))
    }

    func cleanupOrphans(for note: NoteRecord) {
        let directory = drawingsDirectory(for: note)
        guard let urls = try? fileSystem.contentsOfDirectory(at: directory) else { return }
        let activeName = note.drawingFileName?.split(separator: "/").last.map(String.init)
        for url in urls {
            let name = url.lastPathComponent
            let isManagedGeneration = name.hasSuffix(".drawing") && name.contains("-")
            let isTemporary = name.hasPrefix(".") && name.hasSuffix(".tmp")
            guard isManagedGeneration || isTemporary else { continue }
            guard name != activeName else { continue }
            try? fileSystem.removeItem(at: url)
        }
    }

    private func drawingsDirectory(for note: NoteRecord) -> URL {
        fileSystem.rootURL.appendingPathComponent("drawings", isDirectory: true).appendingPathComponent(note.id.uuidString, isDirectory: true)
    }

    private func relativePath(for url: URL) -> String {
        "drawings/\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
    }

    private func managedDrawingURL(fileName: String, note: NoteRecord) throws -> URL {
        let uppercasePrefix = "drawings/\(note.id.uuidString)/"
        let lowercasePrefix = "drawings/\(note.id.uuidString.lowercased())/"
        guard (fileName.hasPrefix(uppercasePrefix) || fileName.hasPrefix(lowercasePrefix)),
              !fileName.contains(".."),
              !fileName.contains("\\"),
              !fileName.contains("\0") else {
            throw NotePersistenceError.invalidDrawingPath
        }
        let components = fileName.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3, components[0] == "drawings", !components[1].isEmpty, !components[2].isEmpty else {
            throw NotePersistenceError.invalidDrawingPath
        }
        let url = fileSystem.rootURL.appendingPathComponent(fileName)
        let directory = url.deletingLastPathComponent().standardizedFileURL.path
        let expectedDirectory = fileSystem.rootURL
            .appendingPathComponent("drawings", isDirectory: true)
            .appendingPathComponent(components[1], isDirectory: true)
            .standardizedFileURL.path
        guard directory == expectedDirectory else {
            throw NotePersistenceError.invalidDrawingPath
        }
        return url
    }
}

private extension Data {
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
