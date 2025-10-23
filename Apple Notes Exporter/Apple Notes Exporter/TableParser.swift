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
        Logger.noteQuery.info("TableParser: Starting to parse table with UUID \(uuid)")

        // Fetch the gzipped mergeable data from the database
        guard let gzippedData = fetchMergeableData(uuid: uuid) else {
            Logger.noteQuery.warning("TableParser: Failed to fetch mergeable data for table \(uuid) - database query returned no data")
            return nil
        }
        Logger.noteQuery.debug("TableParser: Successfully fetched \(gzippedData.count) bytes of gzipped data for table \(uuid)")

        // Decompress the gzipped data
        guard let mergeableData = decompressGzip(gzippedData) else {
            Logger.noteQuery.warning("TableParser: Failed to decompress gzipped data for table \(uuid) - gzip decompression failed")
            return nil
        }
        Logger.noteQuery.debug("TableParser: Successfully decompressed to \(mergeableData.count) bytes for table \(uuid)")

        // Parse the protobuf with partial: true to allow missing required fields
        // Tables in ZMERGEABLEDATA1 may not have all required fields populated
        let protoData: MergableDataProto
        do {
            protoData = try MergableDataProto(serializedBytes: mergeableData, extensions: nil, partial: true)
            Logger.noteQuery.debug("TableParser: Successfully parsed protobuf for table \(uuid)")
        } catch {
            Logger.noteQuery.error("TableParser: Failed to parse protobuf for table \(uuid) - Error: \(error.localizedDescription)")
            return nil
        }

        // Extract and build the table
        let result = buildTable(from: protoData)
        if result == nil {
            Logger.noteQuery.warning("TableParser: buildTable() returned nil for table \(uuid) - table structure may be invalid or empty")
        }
        return result
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

        Logger.noteQuery.debug("TableParser.buildTable: Found \(objects.count) objects, \(keyItems.count) keys, \(typeItems.count) types in protobuf")

        // Debug: Find all objects with OrderedSets
        var orderedSetIndices: [Int] = []
        for (index, obj) in objects.enumerated() {
            if obj.hasOrderedSet {
                orderedSetIndices.append(index)
                Logger.noteQuery.debug("TableParser.buildTable: Object[\(index)] has OrderedSet with \(obj.orderedSet.ordering.array.attachment.count) attachments")
            }
        }
        Logger.noteQuery.debug("TableParser.buildTable: Objects with OrderedSet: \(orderedSetIndices)")

        // Find the table object
        guard let tableObject = findTableObject(objects: objects, typeItems: typeItems) else {
            Logger.noteQuery.warning("TableParser.buildTable: No ICTable object found in protobuf - available types: \(typeItems.joined(separator: ", "))")
            return nil
        }
        Logger.noteQuery.debug("TableParser.buildTable: Found ICTable object with \(tableObject.customMap.mapEntry.count) map entries")

        // Parse rows and columns
        var rowIndices: [Int: Int] = [:]
        var columnIndices: [Int: Int] = [:]
        var totalRows = 0
        var totalColumns = 0

        // Parse the table structure
        Logger.noteQuery.debug("TableParser.buildTable: Processing \(tableObject.customMap.mapEntry.count) map entries")
        for mapEntry in tableObject.customMap.mapEntry {
            let keyIndex = Int(mapEntry.key) - 1
            guard keyIndex >= 0 && keyIndex < keyItems.count else {
                Logger.noteQuery.debug("TableParser.buildTable: Skipping entry with invalid key index \(keyIndex)")
                continue
            }
            let keyName = keyItems[keyIndex]
            Logger.noteQuery.debug("TableParser.buildTable: Processing key '\(keyName)'")

            // Use the mapEntry.value.objectIndex directly (like Ruby does)
            let objectIndex = Int(mapEntry.value.objectIndex)
            guard objectIndex >= 0 && objectIndex < objects.count else {
                Logger.noteQuery.debug("TableParser.buildTable: Skipping key '\(keyName)' with invalid object index \(objectIndex)")
                continue
            }
            let targetObject = objects[objectIndex]
            Logger.noteQuery.debug("TableParser.buildTable: Key '\(keyName)' points to object index \(objectIndex)")

            // Check if the target object or any object it references has an OrderedSet
            // This handles both old and new table formats
            var objectToCheck = targetObject
            var foundOrderedSet = false

            // Follow registerLatest if needed
            let regObjectIndex = Int(objectToCheck.registerLatest.contents.objectIndex)
            if regObjectIndex > 0 && regObjectIndex < objects.count && objects[regObjectIndex].hasOrderedSet {
                objectToCheck = objects[regObjectIndex]
                foundOrderedSet = true
            }

            switch keyName {
            case "crRows":
                if foundOrderedSet || objectToCheck.hasOrderedSet {
                    (rowIndices, totalRows) = parseRows(objectToCheck, uuidItems: uuidItems, objects: objects, keyItems: keyItems, typeItems: typeItems)
                    Logger.noteQuery.debug("TableParser.buildTable: Parsed \(totalRows) rows from OrderedSet")
                } else {
                    Logger.noteQuery.debug("TableParser.buildTable: crRows object has no OrderedSet, trying UUIDIndex fallback")
                }
            case "crColumns":
                if foundOrderedSet || objectToCheck.hasOrderedSet {
                    (columnIndices, totalColumns) = parseColumns(objectToCheck, uuidItems: uuidItems, objects: objects)
                    Logger.noteQuery.debug("TableParser.buildTable: Parsed \(totalColumns) columns from OrderedSet")
                } else {
                    Logger.noteQuery.debug("TableParser.buildTable: crColumns object has no OrderedSet")
                }
            case "UUIDIndex":
                // UUIDIndex might contain the actual row/column data in newer formats
                if objectToCheck.hasOrderedSet {
                    if totalRows == 0 {
                        Logger.noteQuery.debug("TableParser.buildTable: Trying UUIDIndex as rows (fallback)")
                        (rowIndices, totalRows) = parseRows(objectToCheck, uuidItems: uuidItems, objects: objects, keyItems: keyItems, typeItems: typeItems)
                    } else if totalColumns == 0 {
                        Logger.noteQuery.debug("TableParser.buildTable: Trying UUIDIndex as columns (fallback)")
                        (columnIndices, totalColumns) = parseColumns(objectToCheck, uuidItems: uuidItems, objects: objects)
                    }
                }
            case "self":
                // self might contain the actual data in some formats
                if objectToCheck.hasOrderedSet {
                    if totalRows == 0 {
                        Logger.noteQuery.debug("TableParser.buildTable: Trying self as rows (fallback)")
                        (rowIndices, totalRows) = parseRows(objectToCheck, uuidItems: uuidItems, objects: objects, keyItems: keyItems, typeItems: typeItems)
                    } else if totalColumns == 0 {
                        Logger.noteQuery.debug("TableParser.buildTable: Trying self as columns (fallback)")
                        (columnIndices, totalColumns) = parseColumns(objectToCheck, uuidItems: uuidItems, objects: objects)
                    }
                }
            default:
                Logger.noteQuery.debug("TableParser.buildTable: Skipping unknown key '\(keyName)'")
                break
            }
        }

        guard totalRows > 0 && totalColumns > 0 else {
            Logger.noteQuery.warning("TableParser.buildTable: Table has no rows or columns (rows: \(totalRows), columns: \(totalColumns))")
            return nil
        }
        Logger.noteQuery.debug("TableParser.buildTable: Creating table with \(totalRows) rows and \(totalColumns) columns")

        // Initialize empty table
        var table = Array(repeating: Array(repeating: "", count: totalColumns), count: totalRows)

        // Parse cell contents
        Logger.noteQuery.debug("TableParser.buildTable: Looking for cellColumns to populate table data")
        var foundCellColumns = false

        // In different macOS versions, cell data can be stored under different keys:
        // - "cellColumns" (older format)
        // - "identity" (some newer formats)
        // - "crColumns" (some newer formats)
        // We need to find any key that points to a Dictionary with the column->row->cell structure
        for mapEntry in tableObject.customMap.mapEntry {
            let keyIndex = Int(mapEntry.key) - 1
            guard keyIndex >= 0 && keyIndex < keyItems.count else { continue }
            let keyName = keyItems[keyIndex]

            let objectIndex = Int(mapEntry.value.objectIndex)
            guard objectIndex >= 0 && objectIndex < objects.count else { continue }
            let cellColumnsObject = objects[objectIndex]

            // Check if this object has a dictionary structure (which would contain the cell data)
            // We look for a dictionary that has multiple elements (one per column)
            if cellColumnsObject.hasDictionary && cellColumnsObject.dictionary.element.count > 0 {
                // Verify this looks like a cell columns structure by checking if the first element
                // points to another dictionary (which would be the row dictionary)
                let firstElement = cellColumnsObject.dictionary.element.first!
                let firstValueIndex = Int(firstElement.value.objectIndex)
                if firstValueIndex >= 0 && firstValueIndex < objects.count {
                    let firstValueObj = objects[firstValueIndex]
                    // If this is a dictionary, it's likely the row->cell mapping
                    if firstValueObj.hasDictionary {
                        foundCellColumns = true
                        Logger.noteQuery.debug("TableParser.buildTable: Found cell data under '\(keyName)' key at object index \(objectIndex)")
                        parseCellColumns(cellColumnsObject,
                                        into: &table,
                                        rowIndices: rowIndices,
                                        columnIndices: columnIndices,
                                        objects: objects,
                                        uuidItems: uuidItems)
                        break
                    }
                }
            }
        }

        if !foundCellColumns {
            Logger.noteQuery.warning("TableParser.buildTable: No cellColumns found in table - cells will be empty")
            let availableKeys = tableObject.customMap.mapEntry.map { entry -> String in
                let keyIndex = Int(entry.key) - 1
                if keyIndex >= 0 && keyIndex < keyItems.count {
                    return keyItems[keyIndex]
                } else {
                    return "unknown(\(entry.key))"
                }
            }
            Logger.noteQuery.debug("TableParser.buildTable: Available keys in ICTable: \(availableKeys)")

            // Let's explore ALL objects to find where cell data might be
            Logger.noteQuery.debug("TableParser.buildTable: Exploring all \(objects.count) objects to find cell data...")
            var dictionaryObjects: [Int] = []
            for (index, obj) in objects.enumerated() {
                if obj.hasNote {
                    Logger.noteQuery.debug("TableParser.buildTable: Object[\(index)] has Note with text: '\(obj.note.noteText)'")
                }
                if obj.hasDictionary && obj.dictionary.element.count > 0 {
                    dictionaryObjects.append(index)
                    Logger.noteQuery.debug("TableParser.buildTable: Object[\(index)] has Dictionary with \(obj.dictionary.element.count) elements")
                }
            }

            // Now explore the dictionary objects to understand their structure
            Logger.noteQuery.debug("TableParser.buildTable: Found \(dictionaryObjects.count) dictionary objects, examining their structure...")
            for dictIndex in dictionaryObjects {
                let dictObj = objects[dictIndex]
                Logger.noteQuery.debug("TableParser.buildTable: Dictionary[\(dictIndex)] has \(dictObj.dictionary.element.count) elements:")
                for (elemIdx, elem) in dictObj.dictionary.element.enumerated() {
                    let keyObjIndex = Int(elem.key.objectIndex)
                    let valueObjIndex = Int(elem.value.objectIndex)

                    var keyInfo = "obj[\(keyObjIndex)]"
                    if keyObjIndex < objects.count && objects[keyObjIndex].hasCustomMap {
                        let uuid = getTargetUUID(from: objects[keyObjIndex])
                        keyInfo += " UUID hash=\(uuid?.hashValue ?? -1)"
                    }

                    var valueInfo = "obj[\(valueObjIndex)]"
                    if valueObjIndex < objects.count {
                        if objects[valueObjIndex].hasNote {
                            valueInfo += " Note='\(objects[valueObjIndex].note.noteText)'"
                        } else if objects[valueObjIndex].hasDictionary {
                            valueInfo += " Dictionary[\(objects[valueObjIndex].dictionary.element.count)]"
                        }
                    }

                    Logger.noteQuery.debug("  Element[\(elemIdx)]: key=\(keyInfo) -> value=\(valueInfo)")
                }
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
    private func parseRows(_ object: MergeableDataObjectEntry, uuidItems: [Data], objects: [MergeableDataObjectEntry], keyItems: [String] = [], typeItems: [String] = []) -> ([Int: Int], Int) {
        var indices: [Int: Int] = [:]
        var count = 0

        Logger.noteQuery.debug("TableParser.parseRows: hasOrderedSet=\(object.hasOrderedSet), hasList=\(object.hasList), hasDictionary=\(object.hasDictionary), hasNote=\(object.hasNote), hasCustomMap=\(object.hasCustomMap), hasUnknownMessage=\(object.hasUnknownMessage)")

        // Check if we need to follow registerLatest.contents to find the actual data
        let actualObjectIndex = Int(object.registerLatest.contents.objectIndex)
        Logger.noteQuery.debug("TableParser.parseRows: registerLatest.contents points to object index \(actualObjectIndex)")

        if actualObjectIndex > 0 && actualObjectIndex < objects.count {
            let actualObject = objects[actualObjectIndex]
            Logger.noteQuery.debug("TableParser.parseRows: Actual object hasOrderedSet=\(actualObject.hasOrderedSet), hasList=\(actualObject.hasList), hasCustomMap=\(actualObject.hasCustomMap)")

            if actualObject.hasOrderedSet || actualObject.hasCustomMap {
                // Use the actual object from registerLatest (it might have OrderedSet or CustomMap)
                return parseRows(actualObject, uuidItems: uuidItems, objects: objects, keyItems: keyItems, typeItems: typeItems)
            }
        }

        // If the object has a customMap, we need to look inside it for the actual ordered set reference
        if object.hasCustomMap {
            let typeName = object.customMap.type < typeItems.count ? typeItems[Int(object.customMap.type)] : "unknown"
            Logger.noteQuery.debug("TableParser.parseRows: Object has customMap with type '\(typeName)' (index \(object.customMap.type)), \(object.customMap.mapEntry.count) entries")

            // Try all map entries, not just the first
            for (index, entry) in object.customMap.mapEntry.enumerated() {
                let keyIndex = Int(entry.key) - 1
                let keyName = keyIndex >= 0 && keyIndex < keyItems.count ? keyItems[keyIndex] : "unknown"
                let nestedObjectIndex = Int(entry.value.objectIndex)

                Logger.noteQuery.debug("TableParser.parseRows: CustomMap entry \(index): key='\(keyName)', points to object index \(nestedObjectIndex)")

                if nestedObjectIndex > 0 && nestedObjectIndex < objects.count {
                    let nestedObject = objects[nestedObjectIndex]
                    Logger.noteQuery.debug("TableParser.parseRows: Nested object[\(nestedObjectIndex)] hasOrderedSet=\(nestedObject.hasOrderedSet)")
                    if nestedObject.hasOrderedSet {
                        // Use the nested object instead
                        return parseRows(nestedObject, uuidItems: uuidItems, objects: objects, keyItems: keyItems, typeItems: typeItems)
                    }
                }
            }
        }

        guard object.hasOrderedSet else {
            Logger.noteQuery.debug("TableParser.parseRows: Object does not have ordered set")
            return (indices, count)
        }
        Logger.noteQuery.debug("TableParser.parseRows: Found ordered set with \(object.orderedSet.ordering.array.attachment.count) attachments")

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
        Logger.noteQuery.debug("TableParser.parseCellColumns: hasDictionary=\(object.hasDictionary), hasList=\(object.hasList), hasCustomMap=\(object.hasCustomMap)")

        guard object.hasDictionary else {
            Logger.noteQuery.warning("TableParser.parseCellColumns: Object does not have dictionary")
            return
        }

        Logger.noteQuery.debug("TableParser.parseCellColumns: Dictionary has \(object.dictionary.element.count) column elements")

        // Loop over each column
        var cellsFound = 0
        for (colIdx, columnElement) in object.dictionary.element.enumerated() {
            let columnObjectIndex = Int(columnElement.key.objectIndex)
            Logger.noteQuery.debug("TableParser.parseCellColumns: Column \(colIdx): key points to object index \(columnObjectIndex)")
            guard columnObjectIndex < objects.count else {
                Logger.noteQuery.warning("TableParser.parseCellColumns: Column object index \(columnObjectIndex) out of bounds")
                continue
            }

            let currentColumn = getTargetUUID(from: objects[columnObjectIndex])
            Logger.noteQuery.debug("TableParser.parseCellColumns: Column \(colIdx): UUID hash=\(currentColumn?.hashValue ?? -1), colIndex=\(currentColumn.flatMap { columnIndices[$0] } ?? -1)")
            guard let column = currentColumn, let colIndex = columnIndices[column] else {
                Logger.noteQuery.warning("TableParser.parseCellColumns: Could not map column UUID to column index")
                continue
            }

            let rowDictIndex = Int(columnElement.value.objectIndex)
            Logger.noteQuery.debug("TableParser.parseCellColumns: Column \(colIdx): value points to row dict at object index \(rowDictIndex)")
            guard rowDictIndex < objects.count else {
                Logger.noteQuery.warning("TableParser.parseCellColumns: Row dict index \(rowDictIndex) out of bounds")
                continue
            }
            let rowDict = objects[rowDictIndex]

            guard rowDict.hasDictionary else {
                Logger.noteQuery.warning("TableParser.parseCellColumns: Row dict object does not have dictionary")
                continue
            }

            Logger.noteQuery.debug("TableParser.parseCellColumns: Row dict has \(rowDict.dictionary.element.count) row elements")

            // Loop over each row in this column
            for (_, rowElement) in rowDict.dictionary.element.enumerated() {
                let rowObjectIndex = Int(rowElement.key.objectIndex)
                guard rowObjectIndex < objects.count else { continue }

                let currentRow = getTargetUUID(from: objects[rowObjectIndex])
                guard let row = currentRow, let rowIndex = rowIndices[row] else { continue }

                let cellObjectIndex = Int(rowElement.value.objectIndex)
                guard cellObjectIndex < objects.count else { continue }
                let cellObject = objects[cellObjectIndex]

                Logger.noteQuery.debug("TableParser.parseCellColumns: Cell[\(rowIndex),\(colIndex)]: object index \(cellObjectIndex), hasNote=\(cellObject.hasNote)")

                // Extract text from the cell Note object
                if cellObject.hasNote {
                    let cellText = cellObject.note.noteText
                    Logger.noteQuery.debug("TableParser.parseCellColumns: Cell[\(rowIndex),\(colIndex)]: text='\(cellText)'")
                    table[rowIndex][colIndex] = cellText
                    cellsFound += 1
                } else {
                    Logger.noteQuery.warning("TableParser.parseCellColumns: Cell object does not have note")
                }
            }
        }

        Logger.noteQuery.info("TableParser.parseCellColumns: Populated \(cellsFound) cells")
    }
}
