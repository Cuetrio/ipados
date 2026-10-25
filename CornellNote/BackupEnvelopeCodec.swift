import Foundation

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
