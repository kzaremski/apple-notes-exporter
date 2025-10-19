//
//  TableParser.swift
//  Apple Notes Exporter
//
//  Parses embedded tables from Apple Notes database
//  Tables are stored as gzipped protobuf data in ZMERGEABLEDATA1 column
//

import Foundation
import SwiftProtobuf
import Compression
import SQLite3
import zlib
import OSLog

/// Represents a parsed table with rows and columns
struct ParsedTable {
    let rows: [[String]]
    let rowCount: Int
    let columnCount: Int

    /// Convert table to plain text representation
    func toPlainText() -> String {
        var result = ""
        for row in rows {
            result += row.joined(separator: "\t") + "\n"
        }
        return result
    }

    /// Convert table to HTML representation
    func toHTML() -> String {
        var html = "<table border=\"1\" style=\"border-collapse: collapse; margin: 20px 0;\">\n"
        for row in rows {
            html += "  <tr>\n"
            for cell in row {
                let escapedCell = cell
                    .replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;")
                    .replacingOccurrences(of: ">", with: "&gt;")
                html += "    <td style=\"padding: 8px; border: 1px solid #ddd;\">\(escapedCell)</td>\n"
            }
            html += "  </tr>\n"
        }
        html += "</table>\n"
        return html
    }

    /// Convert table to Markdown representation
    func toMarkdown() -> String {
        guard rowCount > 0, columnCount > 0 else { return "" }

        var result = "\n"

        // Add header row (treat first row as header)
        if rowCount > 0 {
            result += "| " + rows[0].joined(separator: " | ") + " |\n"
            result += "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |\n"
        }

        // Add data rows
        for i in 1..<rowCount {
            result += "| " + rows[i].joined(separator: " | ") + " |\n"
        }

        result += "\n"
        return result
    }
}

/// Parses table data from Apple Notes database
class TableParser {
    private let db: OpaquePointer

    init(database: OpaquePointer) {
        self.db = database
    }

    /// Parse a table attachment by its UUID
    func parseTable(uuid: String) -> ParsedTable? {
        // Fetch the gzipped mergeable data from the database
        guard let gzippedData = fetchMergeableData(uuid: uuid) else {
            Logger.noteQuery.debug("Failed to fetch mergeable data for table \(uuid)")
            return nil
        }

        // Decompress the gzipped data
        guard let mergeableData = decompressGzip(gzippedData) else {
            Logger.noteQuery.debug("Failed to decompress gzipped data for table \(uuid)")
            return nil
        }

        // Parse the protobuf
        guard let protoData = try? MergableDataProto(serializedBytes: mergeableData) else {
            Logger.noteQuery.debug("Failed to parse protobuf for table \(uuid)")
            return nil
        }

        // Extract and build the table
        return buildTable(from: protoData)
    }

    /// Fetch ZMERGEABLEDATA1 from database for a given UUID
    private func fetchMergeableData(uuid: String) -> Data? {
        let query = """
        SELECT ZMERGEABLEDATA1
        FROM ZICCLOUDSYNCINGOBJECT
        WHERE ZIDENTIFIER = ?
        AND (ZMARKEDFORDELETION = 0 OR ZMARKEDFORDELETION IS NULL);
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            Logger.noteQuery.error("Failed to prepare query for mergeable data")
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (uuid as NSString).utf8String, -1, nil)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            Logger.noteQuery.debug("No mergeable data found for UUID \(uuid)")
            return nil
        }

        // Get the blob data
        if let blob = sqlite3_column_blob(statement, 0) {
            let size = sqlite3_column_bytes(statement, 0)
            return Data(bytes: blob, count: Int(size))
        }

        return nil
    }

    /// Decompress gzipped data
    private func decompressGzip(_ data: Data) -> Data? {
        let bufferSize = 8192
        var decompressed = Data()

        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let baseAddress = bytes.baseAddress else { return }

            var stream = z_stream()
            stream.next_in = UnsafeMutablePointer<UInt8>(mutating: baseAddress.assumingMemoryBound(to: UInt8.self))
            stream.avail_in = UInt32(data.count)

            // Initialize with gzip window bits (16 + MAX_WBITS)
            guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                Logger.noteQuery.error("Failed to initialize zlib inflation")
                return
            }
            defer { inflateEnd(&stream) }

            var buffer = [UInt8](repeating: 0, count: bufferSize)

            repeat {
                buffer.withUnsafeMutableBytes { bufferPtr in
                    stream.next_out = bufferPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
                }
                stream.avail_out = UInt32(bufferSize)

                let status = inflate(&stream, Z_NO_FLUSH)

                if status == Z_STREAM_END || status == Z_OK {
                    let decompressedSize = bufferSize - Int(stream.avail_out)
                    decompressed.append(buffer, count: decompressedSize)
                } else if status != Z_BUF_ERROR {
                    Logger.noteQuery.error("Zlib error during decompression: \(status)")
                    return
                }

            } while stream.avail_out == 0
        }

        return decompressed.isEmpty ? nil : decompressed
    }

    /// Build table structure from parsed protobuf
    private func buildTable(from proto: MergableDataProto) -> ParsedTable? {
        let objectData = proto.mergableDataObject.mergeableDataObjectData

        // Build indices for lookups
        let keyItems = objectData.mergeableDataObjectKeyItem
        let typeItems = objectData.mergeableDataObjectTypeItem
        let uuidItems = objectData.mergeableDataObjectUuidItem
        let objects = objectData.mergeableDataObjectEntry

        // Find the table object
        guard let tableObject = findTableObject(objects: objects, typeItems: typeItems) else {
            Logger.noteQuery.debug("No ICTable object found in protobuf")
            return nil
        }

        // Parse rows and columns
        var rowIndices: [Int: Int] = [:]
        var columnIndices: [Int: Int] = [:]
        var totalRows = 0
        var totalColumns = 0

        // Parse the table structure
        for mapEntry in tableObject.customMap.mapEntry {
            let keyIndex = Int(mapEntry.key) - 1
            guard keyIndex >= 0 && keyIndex < keyItems.count else { continue }
            let keyName = keyItems[keyIndex]

            let objectIndex = Int(mapEntry.value.objectIndex)
            guard objectIndex >= 0 && objectIndex < objects.count else { continue }
            let targetObject = objects[objectIndex]

            switch keyName {
            case "crRows":
                (rowIndices, totalRows) = parseRows(targetObject, uuidItems: uuidItems, objects: objects)
            case "crColumns":
                (columnIndices, totalColumns) = parseColumns(targetObject, uuidItems: uuidItems, objects: objects)
            default:
                break
            }
        }

        guard totalRows > 0 && totalColumns > 0 else {
            Logger.noteQuery.debug("Table has no rows or columns")
            return nil
        }

        // Initialize empty table
        var table = Array(repeating: Array(repeating: "", count: totalColumns), count: totalRows)

        // Parse cell contents
        for mapEntry in tableObject.customMap.mapEntry {
            let keyIndex = Int(mapEntry.key) - 1
            guard keyIndex >= 0 && keyIndex < keyItems.count else { continue }
            let keyName = keyItems[keyIndex]

            if keyName == "cellColumns" {
                let objectIndex = Int(mapEntry.value.objectIndex)
                guard objectIndex >= 0 && objectIndex < objects.count else { continue }
                let cellColumnsObject = objects[objectIndex]

                parseCellColumns(cellColumnsObject,
                                into: &table,
                                rowIndices: rowIndices,
                                columnIndices: columnIndices,
                                objects: objects,
                                uuidItems: uuidItems)
            }
        }

        return ParsedTable(rows: table, rowCount: totalRows, columnCount: totalColumns)
    }

    /// Find the ICTable object in the protobuf entries
    private func findTableObject(objects: [MergeableDataObjectEntry], typeItems: [String]) -> MergeableDataObjectEntry? {
        for object in objects {
            if object.hasCustomMap {
                let typeIndex = Int(object.customMap.type)
                if typeIndex >= 0 && typeIndex < typeItems.count {
                    if typeItems[typeIndex] == "com.apple.notes.ICTable" {
                        return object
                    }
                }
            }
        }
        return nil
    }

    /// Parse row structure from ordered set
    private func parseRows(_ object: MergeableDataObjectEntry, uuidItems: [Data], objects: [MergeableDataObjectEntry]) -> ([Int: Int], Int) {
        var indices: [Int: Int] = [:]
        var count = 0

        guard object.hasOrderedSet else { return (indices, count) }

        let ordering = object.orderedSet.ordering
        for attachment in ordering.array.attachment {
            if let uuidIndex = uuidItems.firstIndex(of: attachment.uuid) {
                indices[uuidIndex] = count
                count += 1
            }
        }

        // Handle contents mapping
        for element in ordering.contents.element {
            let keyObjectIndex = Int(element.key.objectIndex)
            let valueObjectIndex = Int(element.value.objectIndex)

            if keyObjectIndex < objects.count && valueObjectIndex < objects.count {
                if let keyUUID = getTargetUUID(from: objects[keyObjectIndex]),
                   let valueUUID = getTargetUUID(from: objects[valueObjectIndex]),
                   let keyIndex = indices[keyUUID] {
                    indices[valueUUID] = keyIndex
                }
            }
        }

        return (indices, count)
    }

    /// Parse column structure from ordered set
    private func parseColumns(_ object: MergeableDataObjectEntry, uuidItems: [Data], objects: [MergeableDataObjectEntry]) -> ([Int: Int], Int) {
        // Same logic as parseRows
        return parseRows(object, uuidItems: uuidItems, objects: objects)
    }

    /// Get target UUID index from object entry
    private func getTargetUUID(from object: MergeableDataObjectEntry) -> Int? {
        guard object.hasCustomMap else { return nil }
        guard let firstEntry = object.customMap.mapEntry.first else { return nil }
        return Int(firstEntry.value.unsignedIntegerValue)
    }

    /// Parse cell contents from cellColumns dictionary
    private func parseCellColumns(_ object: MergeableDataObjectEntry,
                                   into table: inout [[String]],
                                   rowIndices: [Int: Int],
                                   columnIndices: [Int: Int],
                                   objects: [MergeableDataObjectEntry],
                                   uuidItems: [Data]) {
        guard object.hasDictionary else { return }

        // Loop over each column
        for columnElement in object.dictionary.element {
            let columnObjectIndex = Int(columnElement.key.objectIndex)
            guard columnObjectIndex < objects.count else { continue }

            let currentColumn = getTargetUUID(from: objects[columnObjectIndex])
            guard let column = currentColumn, let colIndex = columnIndices[column] else { continue }

            let rowDictIndex = Int(columnElement.value.objectIndex)
            guard rowDictIndex < objects.count else { continue }
            let rowDict = objects[rowDictIndex]

            guard rowDict.hasDictionary else { continue }

            // Loop over each row in this column
            for rowElement in rowDict.dictionary.element {
                let rowObjectIndex = Int(rowElement.key.objectIndex)
                guard rowObjectIndex < objects.count else { continue }

                let currentRow = getTargetUUID(from: objects[rowObjectIndex])
                guard let row = currentRow, let rowIndex = rowIndices[row] else { continue }

                let cellObjectIndex = Int(rowElement.value.objectIndex)
                guard cellObjectIndex < objects.count else { continue }
                let cellObject = objects[cellObjectIndex]

                // Extract text from the cell Note object
                if cellObject.hasNote {
                    let cellText = cellObject.note.noteText
                    table[rowIndex][colIndex] = cellText
                }
            }
        }
    }
}
