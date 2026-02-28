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
