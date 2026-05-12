//
//  Data+Compression.swift
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
import Compression
import zlib

// MARK: - Minimal ZIP Archive Writer

/// Builds a ZIP archive in memory from a list of named entries.
/// Supports STORE (no compression) and DEFLATE methods.
/// Compatible with PKZIP 2.0 / Info-ZIP format used by DOCX, ODT, and EPUB.
struct ZIPArchive {
    struct Entry {
        let path: String       // Relative path inside the archive (e.g. "word/document.xml")
        let data: Data         // Uncompressed content
        let compress: Bool     // true = DEFLATE, false = STORE
    }

    /// Build a complete ZIP file from the given entries and return the raw bytes.
    /// Microsoft Word rejects entries with epoch-zero timestamps; we always emit a
    /// real MS-DOS date/time computed from `now` so Word accepts the archive.
    static func build(entries: [Entry]) -> Data {
        var centralDirectory = Data()
        var fileData = Data()

        let (dosTime, dosDate) = currentDOSDateTime()

        for entry in entries {
            let localHeaderOffset = UInt32(fileData.count)
            let pathBytes = Array(entry.path.utf8)

            // Compress if requested
            let compressedData: Data
            let method: UInt16
            if entry.compress && !entry.data.isEmpty {
                if let deflated = deflate(entry.data) {
                    compressedData = deflated
                    method = 8  // DEFLATE
                } else {
                    compressedData = entry.data
                    method = 0  // STORE fallback
                }
            } else {
                compressedData = entry.data
                method = 0 // STORE
            }

            let crc = crc32Checksum(entry.data)
            let uncompressedSize = UInt32(entry.data.count)
            let compressedSize = UInt32(compressedData.count)

            // -- Local file header --
            fileData.appendUInt32(0x04034b50)           // Local file header signature
            fileData.appendUInt16(20)                    // Version needed (2.0)
            fileData.appendUInt16(0)                     // General purpose bit flag
            fileData.appendUInt16(method)                // Compression method
            fileData.appendUInt16(dosTime)               // Last mod file time
            fileData.appendUInt16(dosDate)               // Last mod file date
            fileData.appendUInt32(crc)                   // CRC-32
            fileData.appendUInt32(compressedSize)        // Compressed size
            fileData.appendUInt32(uncompressedSize)      // Uncompressed size
            fileData.appendUInt16(UInt16(pathBytes.count)) // File name length
            fileData.appendUInt16(0)                     // Extra field length
            fileData.append(contentsOf: pathBytes)       // File name
            fileData.append(compressedData)              // File data

            // -- Central directory header --
            centralDirectory.appendUInt32(0x02014b50)           // Central directory file header signature
            centralDirectory.appendUInt16(20)                    // Version made by
            centralDirectory.appendUInt16(20)                    // Version needed
            centralDirectory.appendUInt16(0)                     // General purpose bit flag
            centralDirectory.appendUInt16(method)                // Compression method
            centralDirectory.appendUInt16(dosTime)               // Last mod file time
            centralDirectory.appendUInt16(dosDate)               // Last mod file date
            centralDirectory.appendUInt32(crc)                   // CRC-32
            centralDirectory.appendUInt32(compressedSize)        // Compressed size
            centralDirectory.appendUInt32(uncompressedSize)      // Uncompressed size
            centralDirectory.appendUInt16(UInt16(pathBytes.count)) // File name length
            centralDirectory.appendUInt16(0)                     // Extra field length
            centralDirectory.appendUInt16(0)                     // File comment length
            centralDirectory.appendUInt16(0)                     // Disk number start
            centralDirectory.appendUInt16(0)                     // Internal file attributes
            centralDirectory.appendUInt32(0)                     // External file attributes
            centralDirectory.appendUInt32(localHeaderOffset)     // Relative offset of local header
            centralDirectory.append(contentsOf: pathBytes)       // File name
        }

        let centralDirOffset = UInt32(fileData.count)
        let centralDirSize = UInt32(centralDirectory.count)
        fileData.append(centralDirectory)

        // -- End of central directory record --
        fileData.appendUInt32(0x06054b50)                // End of central directory signature
        fileData.appendUInt16(0)                          // Number of this disk
        fileData.appendUInt16(0)                          // Disk where central directory starts
        fileData.appendUInt16(UInt16(entries.count))      // Number of central directory records on this disk
        fileData.appendUInt16(UInt16(entries.count))      // Total number of central directory records
        fileData.appendUInt32(centralDirSize)             // Size of central directory
        fileData.appendUInt32(centralDirOffset)           // Offset of start of central directory
        fileData.appendUInt16(0)                          // ZIP file comment length

        return fileData
    }

    /// Encode "now" as an (MS-DOS time, MS-DOS date) pair.
    /// DOS time: hours<<11 | minutes<<5 | (seconds/2)
    /// DOS date: (year-1980)<<9 | month<<5 | day
    /// Used so DOCX/ODT/EPUB archives don't carry epoch-zero timestamps,
    /// which some consumers (notably Microsoft Word) treat as corruption.
    private static func currentDOSDateTime() -> (time: UInt16, date: UInt16) {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let year = max(1980, comps.year ?? 1980)
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0
        let date = UInt16(((year - 1980) & 0x7F) << 9 | (month & 0x0F) << 5 | (day & 0x1F))
        let time = UInt16((hour & 0x1F) << 11 | (minute & 0x3F) << 5 | ((second / 2) & 0x1F))
        return (time, date)
    }

    /// Compute CRC-32 checksum using zlib
    private static func crc32Checksum(_ data: Data) -> UInt32 {
        return data.withUnsafeBytes { buffer -> UInt32 in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return UInt32(zlib.crc32(0, baseAddress.assumingMemoryBound(to: Bytef.self), uInt(data.count)))
        }
    }

    /// Deflate (raw) compress data using zlib
    private static func deflate(_ data: Data) -> Data? {
        var stream = z_stream()
        // windowBits = -15 for raw deflate (no zlib/gzip header)
        let initResult = deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else { return nil }

        let bufferSize = data.count + 512
        var outputBuffer = Data(count: bufferSize)

        let result: Int32 = data.withUnsafeBytes { srcPtr in
            outputBuffer.withUnsafeMutableBytes { destPtr in
                stream.next_in = UnsafeMutablePointer(mutating: srcPtr.baseAddress!.assumingMemoryBound(to: Bytef.self))
                stream.avail_in = uInt(data.count)
                stream.next_out = destPtr.baseAddress!.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(bufferSize)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }

        deflateEnd(&stream)

        guard result == Z_STREAM_END else { return nil }
        return outputBuffer.prefix(Int(stream.total_out))
    }
}

// MARK: - Data Helpers for ZIP Binary Writing

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 2))
    }
    mutating func appendUInt32(_ value: UInt32) {
        var le = value.littleEndian
        append(Data(bytes: &le, count: 4))
    }
}

// MARK: - Data Extension for Gzip

extension Data {
    /// Decompress gzip-compressed data by stripping the gzip header and using DEFLATE
    func gunzipped() -> Data? {
        guard self.count > 2 && self[0] == 0x1f && self[1] == 0x8b else {
            return nil  // Not gzip
        }

        // Parse gzip header to find where the compressed data starts
        // Gzip format: 2 bytes magic + 1 byte compression method + 1 byte flags + 6 bytes (time, xfl, os)
        // = 10 bytes minimum header
        guard self.count >= 10 else { return nil }

        var headerSize = 10
        let flags = self[3]

        // FEXTRA flag (bit 2)
        if (flags & 0x04) != 0 {
            guard self.count >= headerSize + 2 else { return nil }
            let xlen = Int(self[headerSize]) + (Int(self[headerSize + 1]) << 8)
            headerSize += 2 + xlen
        }

        // FNAME flag (bit 3) - original filename, null-terminated
        if (flags & 0x08) != 0 {
            while headerSize < self.count && self[headerSize] != 0 {
                headerSize += 1
            }
            headerSize += 1  // Skip null terminator
        }

        // FCOMMENT flag (bit 4) - comment, null-terminated
        if (flags & 0x10) != 0 {
            while headerSize < self.count && self[headerSize] != 0 {
                headerSize += 1
            }
            headerSize += 1  // Skip null terminator
        }

        // FHCRC flag (bit 1) - header CRC
        if (flags & 0x02) != 0 {
            headerSize += 2
        }

        // The last 8 bytes are CRC32 and original size, remove them
        guard headerSize < self.count - 8 else { return nil }

        // Extract the deflate stream (between header and footer)
        let deflateData = self.subdata(in: headerSize..<(self.count - 8))

        // Now decompress using COMPRESSION_ZLIB on the raw deflate stream
        let sourceBuffer = [UInt8](deflateData)
        let destinationBufferSize = sourceBuffer.count * 10  // Assume 10x expansion

        var destinationBuffer = [UInt8](repeating: 0, count: destinationBufferSize)

        let decodedCount = destinationBuffer.withUnsafeMutableBytes { destPtr in
            sourceBuffer.withUnsafeBytes { srcPtr in
                compression_decode_buffer(
                    destPtr.baseAddress!,
                    destinationBufferSize,
                    srcPtr.baseAddress!,
                    sourceBuffer.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard decodedCount > 0 else {
            return nil
        }

        return Data(destinationBuffer.prefix(decodedCount))
    }
}
