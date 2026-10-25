import CryptoKit
import Foundation

enum BackupEnvelopeError: Error, Equatable, LocalizedError {
    case truncated
    case invalidMagic
    case unsupportedEnvelopeSchema(Int)
    case invalidManifest
    case nonCanonicalManifest
    case invalidUTF8
    case invalidPath(String)
    case unsupportedRecordType(UInt8)
    case invalidRecordOrder
    case duplicateRecordPath(String)
    case recordMismatch(String)
    case payloadSizeMismatch(String)
    case payloadHashMismatch(String)
    case footerHashMismatch
    case unsupportedAppDataSchema(Int)
    case invalidMetadata
    case unsupportedDrawingSchema(Int)
    case missingDrawingRecord(String)
    case unexpectedDrawingRecord(String)

    var errorDescription: String? {
        switch self {
        case .truncated: return "Backup envelope is truncated."
        case .invalidMagic: return "Backup envelope magic is invalid."
        case .unsupportedEnvelopeSchema(let value): return "Unsupported envelope schema: \(value)."
        case .invalidManifest: return "Backup manifest is invalid."
        case .nonCanonicalManifest: return "Backup manifest is not canonical JSON."
        case .invalidUTF8: return "Backup record path is not valid UTF-8."
        case .invalidPath(let path): return "Backup path is invalid: \(path)."
        case .unsupportedRecordType(let value): return "Unsupported backup record type: \(value)."
        case .invalidRecordOrder: return "Backup records are not in canonical order."
        case .duplicateRecordPath(let path): return "Backup record path is duplicated: \(path)."
        case .recordMismatch(let path): return "Backup record does not match its manifest entry: \(path)."
        case .payloadSizeMismatch(let path): return "Backup payload size does not match: \(path)."
        case .payloadHashMismatch(let path): return "Backup payload hash does not match: \(path)."
        case .footerHashMismatch: return "Backup envelope footer hash does not match."
        case .unsupportedAppDataSchema(let value): return "Unsupported app data schema: \(value)."
        case .invalidMetadata: return "Backup metadata is invalid."
        case .unsupportedDrawingSchema(let value): return "Unsupported drawing schema: \(value)."
        case .missingDrawingRecord(let path): return "Backup drawing record is missing: \(path)."
        case .unexpectedDrawingRecord(let path): return "Backup drawing record is not referenced by metadata: \(path)."
        }
    }
}

protocol BackupEnvelopeEncoder {
    func encode(
        metadata: BackupMetadata,
        drawings: [BackupDrawingRecord],
        createdAtUnixNanos: Int64
    ) throws -> Data
}

protocol BackupEnvelopeDecoder {
    func decode(_ data: Data) throws -> DecodedBackupEnvelope
}

struct BackupDrawingRecord: Equatable {
    let path: String
    let payload: Data

    init(path: String, payload: Data) {
        self.path = path
        self.payload = payload
    }
}

struct DecodedBackupEnvelope: Equatable {
    let manifest: BackupManifest
    let metadata: BackupMetadata
    let drawings: [BackupDrawingRecord]
}

struct BackupMetadata: Codable, Equatable {
    static let appDataSchema = 1

    let notes: [BackupMetadataNote]

    init(notes: [BackupMetadataNote]) {
        self.notes = notes.sorted { $0.id.uuidString.lowercased() < $1.id.uuidString.lowercased() }
    }

    init(noteRecords: [NoteRecord]) {
        self.init(notes: noteRecords.map { BackupMetadataNote(note: $0) })
    }

    private enum CodingKeys: String, CodingKey {
        case appDataSchema
        case notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(Int.self, forKey: .appDataSchema)
        guard schema == Self.appDataSchema else {
            throw BackupEnvelopeError.unsupportedAppDataSchema(schema)
        }
        self.init(notes: try container.decode([BackupMetadataNote].self, forKey: .notes))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.appDataSchema, forKey: .appDataSchema)
        try container.encode(notes, forKey: .notes)
    }
}

struct BackupMetadataNote: Codable, Equatable {
    let id: UUID
    let title: String
    let createdAtUnixNanos: Int64
    let updatedAtUnixNanos: Int64
    let drawingFileName: String?
    let drawingChecksum: String?
    let drawingSchemaVersion: Int

    init(
        id: UUID,
        title: String,
        createdAtUnixNanos: Int64,
        updatedAtUnixNanos: Int64,
        drawingFileName: String?,
        drawingChecksum: String?,
        drawingSchemaVersion: Int
    ) {
        self.id = id
        self.title = title
        self.createdAtUnixNanos = createdAtUnixNanos
        self.updatedAtUnixNanos = updatedAtUnixNanos
        self.drawingFileName = drawingFileName
        self.drawingChecksum = drawingChecksum
        self.drawingSchemaVersion = drawingSchemaVersion
    }

    init(note: NoteRecord) {
        self.init(
            id: note.id,
            title: note.title,
            createdAtUnixNanos: BackupTimestamp.unixNanos(note.createdAt),
            updatedAtUnixNanos: BackupTimestamp.unixNanos(note.updatedAt),
            drawingFileName: note.drawingFileName.map(BackupPathValidator.canonicalDrawingPath),
            drawingChecksum: note.drawingChecksum,
            drawingSchemaVersion: note.drawingSchemaVersion
        )
    }

    private enum CodingKeys: String, CodingKey {
        case createdAtUnixNanos
        case drawingChecksum
        case drawingFileName
        case drawingSchemaVersion
        case id
        case title
        case updatedAtUnixNanos
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let idString = try container.decode(String.self, forKey: .id)
        guard let id = UUID(uuidString: idString), idString == id.uuidString.lowercased() else {
            throw BackupEnvelopeError.invalidMetadata
        }
        self.init(
            id: id,
            title: try container.decode(String.self, forKey: .title),
            createdAtUnixNanos: try container.decode(Int64.self, forKey: .createdAtUnixNanos),
            updatedAtUnixNanos: try container.decode(Int64.self, forKey: .updatedAtUnixNanos),
            drawingFileName: try container.decodeIfPresent(String.self, forKey: .drawingFileName),
            drawingChecksum: try container.decodeIfPresent(String.self, forKey: .drawingChecksum),
            drawingSchemaVersion: try container.decode(Int.self, forKey: .drawingSchemaVersion)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(createdAtUnixNanos, forKey: .createdAtUnixNanos)
        try container.encodeIfPresent(drawingChecksum, forKey: .drawingChecksum)
        try container.encodeIfPresent(drawingFileName, forKey: .drawingFileName)
        try container.encode(drawingSchemaVersion, forKey: .drawingSchemaVersion)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(updatedAtUnixNanos, forKey: .updatedAtUnixNanos)
    }

    func makeNote() -> NoteRecord {
        let note = NoteRecord(title: title, now: BackupTimestamp.date(from: createdAtUnixNanos))
        note.id = id
        note.updatedAt = BackupTimestamp.date(from: updatedAtUnixNanos)
        note.drawingFileName = drawingFileName
        note.drawingChecksum = drawingChecksum
        note.drawingSchemaVersion = drawingSchemaVersion
        return note
    }
}

struct BackupManifestRecord: Codable, Equatable {
    let path: String
    let type: String
    let size: UInt64
    let sha256: String
}

struct BackupManifest: Codable, Equatable {
    static let envelopeSchema = 1

    let envelopeSchema: Int
    let appDataSchema: Int
    let createdAtUnixNanos: Int64
    let noteCount: Int
    let records: [BackupManifestRecord]
}

enum BackupPathValidator {
    static func canonicalDrawingPath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3,
              components[0] == "drawings",
              let id = UUID(uuidString: components[1]) else {
            return path
        }
        return "drawings/\(id.uuidString.lowercased())/\(components[2])"
    }

    static func validate(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0"),
              path.precomposedStringWithCanonicalMapping.utf8.elementsEqual(path.utf8) else {
            throw BackupEnvelopeError.invalidPath(path)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw BackupEnvelopeError.invalidPath(path)
        }

        if path == "metadata.json" {
            return
        }

        guard components.count == 3, components[0] == "drawings",
              let uuid = UUID(uuidString: components[1]),
              components[1] == uuid.uuidString.lowercased() else {
            throw BackupEnvelopeError.invalidPath(path)
        }

        let filename = components[2]
        guard filename.hasSuffix(".drawing") else {
            throw BackupEnvelopeError.invalidPath(path)
        }
        let stem = String(filename.dropLast(".drawing".count))
        guard let separator = stem.lastIndex(of: "-"), separator != stem.startIndex else {
            throw BackupEnvelopeError.invalidPath(path)
        }
        let checksum = String(stem[stem.index(after: separator)...])
        guard isLowercaseHex(checksum) else {
            throw BackupEnvelopeError.invalidPath(path)
        }
    }

    static func isLowercaseHex(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    static func drawingNoteID(_ path: String) throws -> UUID {
        try validate(path)
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3, components[0] == "drawings", let id = UUID(uuidString: components[1]) else {
            throw BackupEnvelopeError.invalidPath(path)
        }
        return id
    }

    static func drawingChecksum(_ path: String) throws -> String {
        try validate(path)
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count == 3 else { throw BackupEnvelopeError.invalidPath(path) }
        let stem = String(components[2].dropLast(".drawing".count))
        guard let separator = stem.lastIndex(of: "-") else { throw BackupEnvelopeError.invalidPath(path) }
        return String(stem[stem.index(after: separator)...])
    }
}

enum BackupCanonicalJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

protocol ManifestHasher {
    func sha256Hex(_ data: Data) -> String
    func digest(_ data: Data) -> Data
}

struct CryptoKitManifestHasher: ManifestHasher {
    func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func digest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

enum BackupTimestamp {
    static func unixNanos(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000_000_000
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value.rounded())
    }

    static func date(from unixNanos: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(unixNanos) / 1_000_000_000)
    }
}

extension Data {
    var backupSHA256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
