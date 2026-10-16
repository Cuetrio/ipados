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
              path.precomposedStringWithCanonicalMapping == path else {
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

struct BackupEnvelopeCodec: BackupEnvelopeEncoder, BackupEnvelopeDecoder {
    static let prefixMagic = Data("CORNELLNOTE-BKP\0".utf8)
    static let footerMagic = Data("CNBFOOT1".utf8)
    static let version = 1
    static let footerLength = 8 + 32

    private let hasher: ManifestHasher

    init(hasher: ManifestHasher = CryptoKitManifestHasher()) {
        self.hasher = hasher
    }

    func encode(
        metadata: BackupMetadata,
        drawings: [BackupDrawingRecord],
        createdAtUnixNanos: Int64
    ) throws -> Data {
        try validateMetadata(metadata)

        var drawingByPath: [String: BackupDrawingRecord] = [:]
        for drawing in drawings {
            try BackupPathValidator.validate(drawing.path)
            guard drawing.path != "metadata.json" else {
                throw BackupEnvelopeError.invalidPath(drawing.path)
            }
            guard try BackupPathValidator.drawingChecksum(drawing.path) == hasher.sha256Hex(drawing.payload) else {
                throw BackupEnvelopeError.payloadHashMismatch(drawing.path)
            }
            guard drawingByPath.updateValue(drawing, forKey: drawing.path) == nil else {
                throw BackupEnvelopeError.duplicateRecordPath(drawing.path)
            }
        }

        let referencedDrawingPaths = Set(metadata.notes.compactMap(\.drawingFileName))
        for path in referencedDrawingPaths where drawingByPath[path] == nil {
            throw BackupEnvelopeError.missingDrawingRecord(path)
        }
        for path in drawingByPath.keys where !referencedDrawingPaths.contains(path) {
            throw BackupEnvelopeError.unexpectedDrawingRecord(path)
        }

        for note in metadata.notes {
            guard let path = note.drawingFileName, let checksum = note.drawingChecksum else { continue }
            guard let drawing = drawingByPath[path], hasher.sha256Hex(drawing.payload) == checksum else {
                throw BackupEnvelopeError.payloadHashMismatch(path)
            }
        }

        let metadataPayload = try BackupCanonicalJSON.encode(BackupMetadataPayload(metadata: metadata))
        var manifestRecords = [BackupManifestRecord(
            path: "metadata.json",
            type: "metadata",
            size: UInt64(metadataPayload.count),
            sha256: hasher.sha256Hex(metadataPayload)
        )]
        manifestRecords.append(contentsOf: drawingByPath.keys.sorted().compactMap { path in
            guard let drawing = drawingByPath[path] else { return nil }
            return BackupManifestRecord(
                path: path,
                type: "drawing",
                size: UInt64(drawing.payload.count),
                sha256: hasher.sha256Hex(drawing.payload)
            )
        })
        let manifest = BackupManifest(
            envelopeSchema: Self.version,
            appDataSchema: BackupMetadata.appDataSchema,
            createdAtUnixNanos: createdAtUnixNanos,
            noteCount: metadata.notes.count,
            records: manifestRecords
        )
        let manifestData = try BackupCanonicalJSON.encode(manifest)

        var body = Data()
        body.append(Self.prefixMagic)
        body.append(contentsOf: UInt32(Self.version).littleEndianBytes)
        body.append(contentsOf: UInt32(manifestData.count).littleEndianBytes)
        body.append(manifestData)
        appendRecord(type: 0, path: "metadata.json", payload: metadataPayload, to: &body)
        for path in drawingByPath.keys.sorted() {
            guard let drawing = drawingByPath[path] else { continue }
            appendRecord(type: 1, path: path, payload: drawing.payload, to: &body)
        }

        let envelopeHash = hasher.digest(body)
        body.append(Self.footerMagic)
        body.append(contentsOf: envelopeHash)
        return body
    }

    func decode(_ data: Data) throws -> DecodedBackupEnvelope {
        guard data.count >= Self.prefixMagic.count + 8 + Self.footerLength else {
            throw BackupEnvelopeError.truncated
        }

        var reader = BackupByteReader(data: data)
        guard try reader.readData(count: Self.prefixMagic.count) == Self.prefixMagic else {
            throw BackupEnvelopeError.invalidMagic
        }
        let version = try reader.readUInt32()
        guard version == UInt32(Self.version) else {
            throw BackupEnvelopeError.unsupportedEnvelopeSchema(Int(version))
        }
        let manifestLength = Int(try reader.readUInt32())
        guard manifestLength >= 0, reader.remaining >= manifestLength + Self.footerLength else {
            throw BackupEnvelopeError.truncated
        }
        let manifestData = try reader.readData(count: manifestLength)
        let manifest: BackupManifest
        do {
            manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData)
        } catch let error as BackupEnvelopeError {
            throw error
        } catch {
            throw BackupEnvelopeError.invalidManifest
        }
        guard try BackupCanonicalJSON.encode(manifest) == manifestData else {
            throw BackupEnvelopeError.nonCanonicalManifest
        }
        guard manifest.envelopeSchema == Self.version else {
            throw BackupEnvelopeError.unsupportedEnvelopeSchema(manifest.envelopeSchema)
        }
        guard manifest.appDataSchema == BackupMetadata.appDataSchema else {
            throw BackupEnvelopeError.unsupportedAppDataSchema(manifest.appDataSchema)
        }
        try validateManifest(manifest)

        var parsedRecords: [(type: UInt8, path: String, payload: Data)] = []
        for expected in manifest.records {
            let type = try reader.readUInt8()
            guard type == 0 || type == 1 else { throw BackupEnvelopeError.unsupportedRecordType(type) }
            let pathLength = Int(try reader.readUInt32())
            guard pathLength <= reader.remaining - Self.footerLength else { throw BackupEnvelopeError.truncated }
            let pathData = try reader.readData(count: pathLength)
            guard let path = String(data: pathData, encoding: .utf8) else {
                throw BackupEnvelopeError.invalidUTF8
            }
            try BackupPathValidator.validate(path)
            let payloadLength = try reader.readUInt64()
            guard payloadLength <= UInt64(Int.max), Int(payloadLength) <= reader.remaining - Self.footerLength else {
                throw BackupEnvelopeError.truncated
            }
            let payload = try reader.readData(count: Int(payloadLength))

            let expectedType = expected.type == "metadata" ? UInt8(0) : expected.type == "drawing" ? UInt8(1) : nil
            guard expectedType != nil, expectedType == type, expected.path == path else {
                throw BackupEnvelopeError.recordMismatch(path)
            }
            guard expected.size == payloadLength else {
                throw BackupEnvelopeError.payloadSizeMismatch(path)
            }
            guard expected.sha256 == hasher.sha256Hex(payload) else {
                throw BackupEnvelopeError.payloadHashMismatch(path)
            }
            if type == 1 {
                guard try BackupPathValidator.drawingChecksum(path) == hasher.sha256Hex(payload) else {
                    throw BackupEnvelopeError.payloadHashMismatch(path)
                }
            }
            parsedRecords.append((type, path, payload))
        }

        guard reader.remaining == Self.footerLength else { throw BackupEnvelopeError.truncated }
        guard try reader.readData(count: Self.footerMagic.count) == Self.footerMagic else {
            throw BackupEnvelopeError.invalidMagic
        }
        let footerHash = try reader.readData(count: 32)
        let body = data.dropLast(Self.footerLength)
        guard hasher.digest(Data(body)) == footerHash else {
            throw BackupEnvelopeError.footerHashMismatch
        }

        guard let metadataPayload = parsedRecords.first(where: { $0.path == "metadata.json" })?.payload else {
            throw BackupEnvelopeError.invalidMetadata
        }
        let metadata: BackupMetadata
        do {
            let payload = try JSONDecoder().decode(BackupMetadataPayload.self, from: metadataPayload)
            guard try BackupCanonicalJSON.encode(payload) == metadataPayload else {
                throw BackupEnvelopeError.invalidMetadata
            }
            let incomingIDs = payload.notes.map { $0.id.uuidString.lowercased() }
            guard incomingIDs == incomingIDs.sorted(), Set(incomingIDs).count == incomingIDs.count else {
                throw BackupEnvelopeError.invalidMetadata
            }
            metadata = payload.metadata
        } catch let error as BackupEnvelopeError {
            throw error
        } catch {
            throw BackupEnvelopeError.invalidMetadata
        }
        try validateMetadata(metadata)
        guard manifest.noteCount == metadata.notes.count else { throw BackupEnvelopeError.invalidMetadata }

        let drawings = parsedRecords.filter { $0.type == 1 }.map {
            BackupDrawingRecord(path: $0.path, payload: $0.payload)
        }
        let decoded = DecodedBackupEnvelope(manifest: manifest, metadata: metadata, drawings: drawings)
        _ = try encode(metadata: metadata, drawings: drawings, createdAtUnixNanos: manifest.createdAtUnixNanos)
        return decoded
    }

    private func validateManifest(_ manifest: BackupManifest) throws {
        guard !manifest.records.isEmpty, manifest.records[0].path == "metadata.json", manifest.records[0].type == "metadata" else {
            throw BackupEnvelopeError.invalidRecordOrder
        }
        var seen = Set<String>()
        for (index, record) in manifest.records.enumerated() {
            try BackupPathValidator.validate(record.path)
            guard seen.insert(record.path).inserted else {
                throw BackupEnvelopeError.duplicateRecordPath(record.path)
            }
            guard BackupPathValidator.isLowercaseHex(record.sha256) else {
                throw BackupEnvelopeError.invalidManifest
            }
            if index > 0 {
                guard record.type == "drawing" else { throw BackupEnvelopeError.invalidRecordOrder }
            }
        }
        let drawingPaths = manifest.records.dropFirst().map(\.path)
        guard drawingPaths == drawingPaths.sorted() else { throw BackupEnvelopeError.invalidRecordOrder }
    }

    private func validateMetadata(_ metadata: BackupMetadata) throws {
        let ids = metadata.notes.map { $0.id.uuidString.lowercased() }
        guard ids == ids.sorted(), Set(ids).count == ids.count else { throw BackupEnvelopeError.invalidMetadata }
        for note in metadata.notes {
            guard note.drawingSchemaVersion == NotePersistenceController.drawingSchemaVersion else {
                throw BackupEnvelopeError.unsupportedDrawingSchema(note.drawingSchemaVersion)
            }
            if let path = note.drawingFileName {
                try BackupPathValidator.validate(path)
                guard try BackupPathValidator.drawingNoteID(path) == note.id,
                      let checksum = note.drawingChecksum,
                      try BackupPathValidator.drawingChecksum(path) == checksum,
                      BackupPathValidator.isLowercaseHex(checksum) else {
                    throw BackupEnvelopeError.invalidMetadata
                }
            } else if note.drawingChecksum != nil {
                throw BackupEnvelopeError.invalidMetadata
            }
        }
    }

    private func appendRecord(type: UInt8, path: String, payload: Data, to data: inout Data) {
        data.append(type)
        data.append(contentsOf: UInt32(path.utf8.count).littleEndianBytes)
        data.append(contentsOf: path.utf8)
        data.append(contentsOf: UInt64(payload.count).littleEndianBytes)
        data.append(payload)
    }
}

private struct BackupMetadataPayload: Codable, Equatable {
    let appDataSchema: Int
    let notes: [BackupMetadataNote]

    init(metadata: BackupMetadata) {
        self.appDataSchema = BackupMetadata.appDataSchema
        self.notes = metadata.notes
    }

    var metadata: BackupMetadata {
        BackupMetadata(notes: notes)
    }
}

private struct BackupByteReader {
    let data: Data
    var offset = 0

    var remaining: Int { data.count - offset }

    mutating func readUInt8() throws -> UInt8 {
        guard remaining >= 1 else { throw BackupEnvelopeError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.enumerated().reduce(UInt32(0)) { result, item in
            result | (UInt32(item.element) << UInt32(item.offset * 8))
        }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return bytes.enumerated().reduce(UInt64(0)) { result, item in
            result | (UInt64(item.element) << UInt64(item.offset * 8))
        }
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw BackupEnvelopeError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}

private extension FixedWidthInteger {
    var littleEndianBytes: [UInt8] {
        withUnsafeBytes(of: littleEndian) { Array($0) }
    }
}

private extension Digest {
    var data: Data { Data(self) }
}

extension Data {
    var backupSHA256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
