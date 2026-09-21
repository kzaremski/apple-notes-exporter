//
//  PaperVector.swift
//  Apple Notes Exporter
//
//  Copyright (C) 2026 Konstantin Zaremski
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import CoreGraphics
import SQLite3

// MARK: - Overview
//
// Apple Pencil handwriting written in Notes is stored as a `com.apple.paper`
// attachment. The pixels Notes hands out for that attachment -- the
// FallbackImage.png the rest of this exporter relies on -- are a low
// resolution flattening of it: a single strip a few hundred pixels wide for a
// canvas thousands of points tall. Scaled up to a page it is unreadable, and
// it is what every "export to PDF" path produced before this.
//
// The strokes themselves survive losslessly in the attachment's paper bundle:
//
//     ~/Library/Group Containers/group.com.apple.notes/Accounts/<account>/
//         Paper/Bundles/<attachment-uuid>.bundle/
//             Database/data.sqlite3    -- Coherence CRDT object store
//             Assets.bundle/<asset>    -- images placed on the canvas
//
// `data.sqlite3` holds one row per CRDT object in a `Reference` table keyed by
// a 17-byte id (a type byte followed by a UUID). Each row's `Data` is a
// protobuf message behind a `crdt` magic:
//
//     { f1: <document>, f6: <dictionary> }
//
// The dictionary carries that document's property names; the document
// references them by slot. Walking from the store's root gives the canvas, its
// drawing, and every stroke's ink, transform and path.
//
// PaperKit can parse all of this, but `PaperMarkup.draw(in:)` rasterises ink
// into an image XObject even when the destination is a PDF context, which
// would put us back where we started. So this file decodes the strokes and
// emits them as filled vector outlines instead. The output is resolution
// independent: it is sharp at any zoom and at any print size.

// MARK: - Minimal protobuf reader

/// Just enough protobuf to walk the CRDT records. A full generated-code
/// dependency would buy nothing here: the schema is Apple's, undocumented, and
/// we only ever read a handful of known field numbers out of it.
enum PaperProto {
    enum Value {
        case varint(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
        case fixed64(UInt64)

        var bytesValue: Data? { if case .bytes(let d) = self { return d }; return nil }
        var intValue: Int? { if case .varint(let v) = self { return Int(v) }; return nil }

        var floatValue: Float? {
            if case .fixed32(let v) = self { return Float(bitPattern: v) }
            return nil
        }

        var doubleValue: Double? {
            if case .fixed64(let v) = self { return Double(bitPattern: v) }
            return nil
        }
    }

    struct Field {
        let number: Int
        let value: Value
    }

    /// Decode one varint. Returns nil rather than trapping: these blobs come
    /// off disk and a truncated one must not take the export down.
    static func varint(_ data: Data, _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.count {
            let byte = data[data.startIndex + index]
            index += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    /// Flat list of the fields in one message, in encounter order. Repeated
    /// fields therefore appear repeatedly, which is what the CRDT records
    /// need: property entries and ordered-set items are both repeated.
    static func fields(_ data: Data) -> [Field] {
        var out: [Field] = []
        var i = 0
        while i < data.count {
            guard let key = varint(data, &i) else { break }
            let number = Int(key >> 3)
            let wire = Int(key & 7)
            if number == 0 { break }
            switch wire {
            case 0:
                guard let v = varint(data, &i) else { return out }
                out.append(Field(number: number, value: .varint(v)))
            case 1:
                guard i + 8 <= data.count else { return out }
                out.append(Field(number: number, value: .fixed64(data.littleEndianUInt64(at: i))))
                i += 8
            case 2:
                guard let length = varint(data, &i), i + Int(length) <= data.count else { return out }
                let sub = data.subdata(in: data.index(data.startIndex, offsetBy: i) ..< data.index(data.startIndex, offsetBy: i + Int(length)))
                out.append(Field(number: number, value: .bytes(sub)))
                i += Int(length)
            case 5:
                guard i + 4 <= data.count else { return out }
                out.append(Field(number: number, value: .fixed32(data.littleEndianUInt32(at: i))))
                i += 4
            default:
                return out
            }
        }
        return out
    }

    static func first(_ fields: [Field], _ number: Int) -> Value? {
        fields.first(where: { $0.number == number })?.value
    }

    static func firstBytes(_ fields: [Field], _ number: Int) -> Data? {
        first(fields, number)?.bytesValue
    }

    /// `first(fields(of:), n)` in one step, for the long single-child chains
    /// the CRDT wrappers are full of.
    static func descend(_ data: Data, _ path: [Int]) -> Data? {
        var current = data
        for number in path {
            guard let next = firstBytes(fields(current), number) else { return nil }
            current = next
        }
        return current
    }
}

private extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for k in (0..<4).reversed() { v = (v << 8) | UInt32(self[self.startIndex + offset + k]) }
        return v
    }

    func littleEndianUInt64(at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for k in (0..<8).reversed() { v = (v << 8) | UInt64(self[self.startIndex + offset + k]) }
        return v
    }

    /// Hand-packed value blobs inside the CRDT (rects, affine transforms) are
    /// big-endian, unlike the protobuf-native `fixed32`/`fixed64` scalars
    /// beside them, which the wire format defines as little-endian.
    func bigEndianDoubles() -> [Double] {
        guard count % 8 == 0 else { return [] }
        return (0 ..< count / 8).map { i in
            var v: UInt64 = 0
            for k in 0..<8 { v = (v << 8) | UInt64(self[self.startIndex + i * 8 + k]) }
            return Double(bitPattern: v)
        }
    }

    func littleEndianFloat(at offset: Int) -> Float {
        Float(bitPattern: littleEndianUInt32(at: offset))
    }
}

// MARK: - Decoded model

/// One sample along a stroke. `width` is the pen's diameter at that sample,
/// which is what gives Apple Pencil strokes their taper.
struct PaperStrokePoint {
    var x: Double
    var y: Double
    var width: Double
}

struct PaperStroke {
    var points: [PaperStrokePoint]
    /// Straight RGBA, as stored. Notes writes sRGB components.
    var color: (r: Double, g: Double, b: Double, a: Double)
    var inkIdentifier: String?
    /// Applied to the points before rendering; usually a translation that
    /// Notes accumulated while the canvas grew.
    var transform: CGAffineTransform

    var transformedPoints: [PaperStrokePoint] {
        guard transform != .identity else { return points }
        // A uniform scale in the transform has to reach the pen width too, or
        // scaled strokes come out the right shape at the wrong weight.
        let scale = (abs(transform.a * transform.d - transform.b * transform.c)).squareRoot()
        let widthScale = scale > 0 ? scale : 1
        return points.map { p in
            PaperStrokePoint(
                x: transform.a * p.x + transform.c * p.y + transform.tx,
                y: transform.b * p.x + transform.d * p.y + transform.ty,
                width: p.width * widthScale
            )
        }
    }
}

/// A photo or scan placed on the canvas. Inherently raster; embedded as-is so
/// the PDF keeps the original pixels rather than a re-encoded copy.
struct PaperImage {
    var frame: CGRect
    var data: Data
}

/// Everything one `com.apple.paper` attachment contains.
struct PaperDocument {
    /// The canvas Notes lays the strokes out on, in points.
    var bounds: CGRect
    var strokes: [PaperStroke]
    var images: [PaperImage]

    var isEmpty: Bool { strokes.isEmpty && images.isEmpty }

    /// Tight box around everything drawn, pen width included.
    var contentBounds: CGRect {
        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude
        for stroke in strokes {
            for p in stroke.transformedPoints {
                let r = max(p.width, 0) / 2
                minX = min(minX, p.x - r); maxX = max(maxX, p.x + r)
                minY = min(minY, p.y - r); maxY = max(maxY, p.y + r)
            }
        }
        for image in images {
            minX = min(minX, image.frame.minX); maxX = max(maxX, image.frame.maxX)
            minY = min(minY, image.frame.minY); maxY = max(maxY, image.frame.maxY)
        }
        guard minX <= maxX, minY <= maxY else { return bounds }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - Bundle location

enum PaperBundleLocator {
    /// Root of the Notes group container, which holds one directory per account.
    static func notesContainerPath() -> String {
        resolvedFilePath(userHomeDirectoryPath() + "/Library/Group Containers/group.com.apple.notes")
    }

    /// The paper bundle for an attachment, searched across every account
    /// directory. The attachment table does not record which account holds the
    /// bundle, and a machine can have several.
    static func bundleURL(forAttachmentID attachmentID: String,
                          containerPath: String = notesContainerPath()) -> URL? {
        let accountsURL = URL(fileURLWithPath: containerPath).appendingPathComponent("Accounts")
        let accounts = (try? FileManager.default.contentsOfDirectory(
            at: accountsURL, includingPropertiesForKeys: nil)) ?? []
        // Attachment UUIDs are upper-cased in the database and on disk, but a
        // caller may hand us either case.
        let candidates = [attachmentID, attachmentID.uppercased(), attachmentID.lowercased()]
        for account in accounts {
            for name in candidates {
                let url = account
                    .appendingPathComponent("Paper/Bundles")
                    .appendingPathComponent("\(name).bundle")
                if FileManager.default.fileExists(atPath: url.appendingPathComponent("Database/data.sqlite3").path) {
                    return url
                }
            }
        }
        return nil
    }
}

// MARK: - Bundle reader

enum PaperBundleError: LocalizedError {
    case cannotOpenDatabase(String)
    case missingRoot
    case notAPaperDrawing

    var errorDescription: String? {
        switch self {
        case .cannotOpenDatabase(let path): return "Could not open the paper bundle database at \(path)."
        case .missingRoot:                  return "The paper bundle has no root object."
        case .notAPaperDrawing:             return "The paper bundle contains no drawing."
        }
    }
}

/// Reads one `<uuid>.bundle` and decodes it into a `PaperDocument`.
final class PaperBundleReader {
    private let bundleURL: URL
    private var db: OpaquePointer?
    private var snapshotDirectory: URL?
    private var cache: [Data: Data] = [:]

    init(bundleURL: URL) throws {
        self.bundleURL = bundleURL
        try openDatabase()
    }

    deinit {
        if let db { sqlite3_close(db) }
        if let snapshotDirectory { try? FileManager.default.removeItem(at: snapshotDirectory) }
    }

    // MARK: Database

    /// Notes keeps these bundles open, so the live file usually has an
    /// uncheckpointed WAL beside it that a read-only handle cannot replay.
    /// Back it up into a private snapshot first, the same way the main
    /// NoteStore reader does, and fall back to the live file if that fails.
    private func openDatabase() throws {
        let livePath = bundleURL.appendingPathComponent("Database/data.sqlite3").path

        var live: OpaquePointer?
        let readOnly = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        guard sqlite3_open_v2(livePath, &live, readOnly, nil) == SQLITE_OK, live != nil else {
            if live != nil { sqlite3_close(live) }
            throw PaperBundleError.cannotOpenDatabase(livePath)
        }
        sqlite3_busy_timeout(live, 5000)

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-paper-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)) != nil else {
            db = live
            return
        }
        let snapshotPath = tempDirectory.appendingPathComponent("paper.sqlite3").path

        var snapshot: OpaquePointer?
        let readWrite = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(snapshotPath, &snapshot, readWrite, nil) == SQLITE_OK, snapshot != nil,
              let backup = sqlite3_backup_init(snapshot, "main", live, "main") else {
            if snapshot != nil { sqlite3_close(snapshot) }
            try? FileManager.default.removeItem(at: tempDirectory)
            db = live
            return
        }

        var rc: Int32 = SQLITE_OK
        var attempts = 0
        repeat {
            rc = sqlite3_backup_step(backup, -1)
            if rc == SQLITE_BUSY || rc == SQLITE_LOCKED {
                sqlite3_sleep(100)
                attempts += 1
            }
        } while (rc == SQLITE_BUSY || rc == SQLITE_LOCKED) && attempts < 50
        sqlite3_backup_finish(backup)

        guard rc == SQLITE_DONE else {
            sqlite3_close(snapshot)
            try? FileManager.default.removeItem(at: tempDirectory)
            db = live
            return
        }

        sqlite3_close(live)
        sqlite3_busy_timeout(snapshot, 5000)
        db = snapshot
        snapshotDirectory = tempDirectory
    }

    /// The `Data` column of one CRDT object, with its `crdt` + version header
    /// stripped so callers see the protobuf directly.
    private func object(_ id: Data) -> Data? {
        if let hit = cache[id] { return hit }
        guard let db else { return nil }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT Data FROM Reference WHERE Id = ?", -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        _ = id.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, 1, buffer.baseAddress, Int32(id.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let blob = sqlite3_column_blob(statement, 0) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, 0))
        let raw = Data(bytes: blob, count: length)
        // Root context row ("\xff") carries no magic; object rows do.
        let payload: Data
        if raw.count > 8, raw.prefix(4) == Data("crdt".utf8) {
            payload = raw.subdata(in: raw.index(raw.startIndex, offsetBy: 8) ..< raw.endIndex)
        } else {
            payload = raw
        }
        cache[id] = payload
        return payload
    }

    // MARK: CRDT record helpers

    /// A reference is stored as a nested single-child wrapper ending in a
    /// length-delimited id. Finding that id by structure would mean knowing
    /// every wrapper shape Coherence uses, so match the two bytes that
    /// introduce it instead: field 2, length 17.
    private static func referenceID(in value: Data) -> Data? {
        let marker: [UInt8] = [0x12, 0x11, 0x02]
        let bytes = [UInt8](value)
        guard bytes.count >= 19 else { return nil }
        for i in 0 ... (bytes.count - 19) where Array(bytes[i ..< i + 3]) == marker {
            return Data(bytes[i + 2 ..< i + 19])
        }
        return nil
    }

    /// A record document's properties, resolved to their names.
    ///
    /// Layout: `{ f1: { f4: { f1: <name indices>, f2: <entry>... } },
    ///            f6: { f1: <ids>, f2: <name>... } }`. An entry is either
    /// `{ f1: { f1: <write timestamp>, f2: <value> } }` for a plain property,
    /// or a bare `f9` ordered set.
    ///
    /// Which name an entry carries is decided by its **position**: the nth
    /// entry is named by `names[indices[n]]`. The submessage that looks like a
    /// key is the CRDT timestamp of the write, and only coincides with the
    /// position when a document's properties were written in dictionary
    /// order -- which is why reading it as the key worked on most canvases and
    /// silently lost the drawing on others.
    private struct Record {
        var properties: [String: Data] = [:]
        var orderedSets: [String: Data] = [:]
    }

    private func record(_ id: Data) -> Record? {
        guard let payload = object(id) else { return nil }
        let top = PaperProto.fields(payload)
        guard let document = PaperProto.firstBytes(top, 1),
              let body = PaperProto.firstBytes(PaperProto.fields(document), 4) else { return nil }

        var names: [String] = []
        if let dictionary = PaperProto.firstBytes(top, 6) {
            names = PaperProto.fields(dictionary).compactMap { field in
                guard field.number == 2, let raw = field.value.bytesValue else { return nil }
                return String(data: raw, encoding: .utf8)
            }
        }

        let bodyFields = PaperProto.fields(body)
        let indices = PaperProto.firstBytes(bodyFields, 1).map { [UInt8]($0) } ?? []

        var result = Record()
        var position = 0
        for field in bodyFields where field.number == 2 {
            defer { position += 1 }
            guard let entry = field.value.bytesValue else { continue }
            // Resolve the name first: an entry we cannot read still occupies
            // its position, so skipping it must not shift the ones after it.
            guard position < indices.count else { continue }
            let nameIndex = Int(indices[position])
            guard nameIndex < names.count else { continue }
            let name = names[nameIndex]

            let entryFields = PaperProto.fields(entry)
            if let orderedSet = PaperProto.firstBytes(entryFields, 9) {
                result.orderedSets[name] = orderedSet
            } else if let inner = PaperProto.firstBytes(entryFields, 1),
                      let value = PaperProto.firstBytes(PaperProto.fields(inner), 2) {
                result.properties[name] = value
            }
        }
        return result
    }

    /// Items of an ordered set, in document order, as the reference ids they
    /// point at. The set's CRDT bookkeeping (f2/f3 siblings) is ignored: we
    /// only ever read the store, never merge into it.
    private func orderedSetReferences(_ orderedSet: Data) -> [Data] {
        guard let payload = PaperProto.firstBytes(PaperProto.fields(orderedSet), 1) else { return [] }
        return PaperProto.fields(payload).compactMap { field in
            guard field.number == 4, let item = field.value.bytesValue,
                  let wrapper = PaperProto.firstBytes(PaperProto.fields(item), 1) else { return nil }
            return Self.referenceID(in: wrapper)
        }
    }

    private static func rect(_ value: Data) -> CGRect? {
        guard let packed = PaperProto.firstBytes(PaperProto.fields(value), 4) else { return nil }
        let d = packed.bigEndianDoubles()
        guard d.count == 4, d.allSatisfy({ $0.isFinite }) else { return nil }
        return CGRect(x: d[0], y: d[1], width: d[2], height: d[3])
    }

    private static func affineTransform(_ value: Data) -> CGAffineTransform? {
        guard let packed = PaperProto.firstBytes(PaperProto.fields(value), 4) else { return nil }
        let d = packed.bigEndianDoubles()
        guard d.count == 6, d.allSatisfy({ $0.isFinite }) else { return nil }
        return CGAffineTransform(a: d[0], b: d[1], c: d[2], d: d[3], tx: d[4], ty: d[5])
    }

    // MARK: Decoding

    func read() throws -> PaperDocument {
        // The context row names the store's root object.
        guard let context = object(Data([0xff])),
              let rootWrapper = PaperProto.descend(context, [3, 5]),
              let rootID = PaperProto.firstBytes(PaperProto.fields(rootWrapper), 2) else {
            throw PaperBundleError.missingRoot
        }
        guard let root = record(rootID) else { throw PaperBundleError.missingRoot }

        let canvas = root.properties["bounds"].flatMap(Self.rect) ?? .zero
        guard let drawingValue = root.properties["drawing"],
              let drawingID = Self.referenceID(in: drawingValue),
              let drawing = record(drawingID) else {
            throw PaperBundleError.notAPaperDrawing
        }

        var strokes: [PaperStroke] = []
        if let strokeSet = drawing.orderedSets["strokes"] {
            for entryID in orderedSetReferences(strokeSet) {
                if let stroke = decodeStroke(entryID) { strokes.append(stroke) }
            }
        }

        var images: [PaperImage] = []
        if let subelements = root.orderedSets["subelements"] {
            for id in orderedSetReferences(subelements) {
                if let image = decodeImage(id) { images.append(image) }
            }
        }

        return PaperDocument(bounds: canvas, strokes: strokes, images: images)
    }

    /// A stroke reaches its data through two hops: the ordered-set item points
    /// at an indirection object, which points at the stroke's property record.
    private func decodeStroke(_ entryID: Data) -> PaperStroke? {
        guard let entry = object(entryID),
              let propertiesID = Self.referenceID(in: entry),
              let properties = record(propertiesID) else { return nil }

        var color = (r: 0.0, g: 0.0, b: 0.0, a: 1.0)
        var inkIdentifier: String?
        var transform = CGAffineTransform.identity
        if let inherited = properties.properties["inherited"],
           let inkID = Self.referenceID(in: inherited),
           let inkRecord = record(inkID) {
            if let ink = inkRecord.properties["ink"],
               let descriptor = PaperProto.descend(ink, [9, 1, 4]) {
                let fields = PaperProto.fields(descriptor)
                if let rgba = PaperProto.firstBytes(fields, 1) {
                    let components = PaperProto.fields(rgba)
                    func component(_ number: Int, default fallback: Double) -> Double {
                        guard let value = PaperProto.first(components, number)?.floatValue else { return fallback }
                        return Double(value)
                    }
                    color = (component(1, default: 0), component(2, default: 0),
                             component(3, default: 0), component(4, default: 1))
                }
                if let identifier = PaperProto.firstBytes(fields, 2) {
                    inkIdentifier = String(data: identifier, encoding: .utf8)
                }
            }
            if let value = inkRecord.properties["transform"],
               let decoded = Self.affineTransform(value) {
                transform = decoded
            }
        }

        // The path lives behind the record's `properties` tuple; its fields are
        // positional, so take whichever one resolves to an object we can read
        // as a point stream.
        var points: [PaperStrokePoint] = []
        if let tuple = properties.properties["properties"],
           let record = PaperProto.firstBytes(PaperProto.fields(tuple), 14) {
            for field in PaperProto.fields(record) where field.number == 2 {
                guard let value = field.value.bytesValue,
                      let pathID = Self.referenceID(in: value) else { continue }
                if let decoded = decodePoints(pathID), !decoded.isEmpty {
                    points = decoded
                    break
                }
            }
        }
        guard !points.isEmpty else { return nil }
        return PaperStroke(points: points, color: color, inkIdentifier: inkIdentifier, transform: transform)
    }

    /// Per-point attributes of a stroke path.
    ///
    /// The path object stores a point count, a bitmask of the attributes that
    /// vary per point, a second bitmask of those that are constant for the
    /// whole stroke, the constants themselves, and a fixed-stride blob of the
    /// varying ones. Both blobs pack their attributes in bit order at these
    /// widths, so where any one attribute sits is derived, never assumed.
    ///
    /// The widths were solved from every stroke in a real library: each
    /// (mask, stride) and (constant mask, constants length) pair is a linear
    /// equation over them, and the 45 distinct combinations present over-
    /// determine the 12 unknowns and agree exactly.
    ///
    /// Only 0 (location) and 2 (size) are read. The rest -- time, pressure,
    /// tilt, and whatever Apple adds next -- are measured so the stride comes
    /// out right, which is the whole job: a stroke whose width is constant
    /// stores it in the second blob, and misreading the layout renders it as
    /// a hairline or drops it entirely.
    enum PointAttribute {
        static let location = 0
        static let size = 2
        /// Byte width of each attribute, indexed by bit.
        static let widths = [8, 4, 4, 2, 2, 2, 2, 2, 2, 4, 2, 4]
    }

    /// Byte offset of each present attribute in the per-point and constant
    /// blobs, plus the per-point stride.
    static func layout(mask: Int, constantMask: Int) -> (perPoint: [Int: Int], constant: [Int: Int], stride: Int) {
        var perPoint: [Int: Int] = [:]
        var constant: [Int: Int] = [:]
        var stride = 0
        var constantOffset = 0
        for bit in 0 ..< PointAttribute.widths.count {
            let width = PointAttribute.widths[bit]
            if mask & (1 << bit) != 0 {
                perPoint[bit] = stride
                stride += width
            } else if constantMask & (1 << bit) != 0 {
                constant[bit] = constantOffset
                constantOffset += width
            }
        }
        return (perPoint, constant, stride)
    }

    private func decodePoints(_ pathID: Data) -> [PaperStrokePoint]? {
        guard let payload = object(pathID),
              let body = PaperProto.descend(payload, [1, 10, 1, 2]) else { return nil }
        let fields = PaperProto.fields(body)
        guard let count = PaperProto.first(fields, 3)?.intValue, count > 0,
              let mask = PaperProto.first(fields, 4)?.intValue,
              let blob = PaperProto.firstBytes(fields, 7), !blob.isEmpty else { return nil }
        let constantMask = PaperProto.first(fields, 5)?.intValue ?? 0
        let constants = PaperProto.firstBytes(fields, 6) ?? Data()

        let (perPoint, constant, stride) = Self.layout(mask: mask, constantMask: constantMask)
        guard stride > 0, blob.count == stride * count,
              let locationOffset = perPoint[PointAttribute.location] else { return nil }

        var constantWidth: Double?
        if let offset = constant[PointAttribute.size], offset + 4 <= constants.count {
            let value = Double(constants.littleEndianFloat(at: offset))
            if value.isFinite, value > 0.01, value < 500 { constantWidth = value }
        }

        var points: [PaperStrokePoint] = []
        points.reserveCapacity(count)
        for i in 0 ..< count {
            let base = i * stride
            let x = Double(blob.littleEndianFloat(at: base + locationOffset))
            let y = Double(blob.littleEndianFloat(at: base + locationOffset + 4))
            let width: Double
            if let sizeOffset = perPoint[PointAttribute.size] {
                width = Double(blob.littleEndianFloat(at: base + sizeOffset))
            } else {
                width = constantWidth ?? 0
            }
            guard x.isFinite, y.isFinite else { continue }
            points.append(PaperStrokePoint(x: x, y: y, width: width.isFinite ? width : 0))
        }
        return points
    }

    /// Photos and scans dropped onto the canvas. The pixels live in
    /// `Assets.bundle` under the Base64 of the SHA-256 the record names.
    private func decodeImage(_ id: Data) -> PaperImage? {
        guard let element = record(id),
              let frame = element.properties["frame"].flatMap(Self.rect),
              let imageValue = element.properties["image"],
              let descriptor = PaperProto.descend(imageValue, [9, 1, 13]),
              let digest = PaperProto.firstBytes(PaperProto.fields(descriptor), 2),
              digest.count == 32 else { return nil }
        let assetName = digest.base64EncodedString()
        let assetURL = bundleURL.appendingPathComponent("Assets.bundle").appendingPathComponent(assetName)
        guard let data = try? Data(contentsOf: assetURL) else { return nil }
        return PaperImage(frame: frame, data: data)
    }
}
