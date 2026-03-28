//
//  CLIOutput.swift
//  Apple Notes Exporter CLI
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

// MARK: - Output Helpers

enum CLIOutput {

    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()

    /// Write an Encodable value as pretty-printed JSON to stdout.
    static func writeJSON<T: Encodable>(_ value: T) {
        do {
            let data = try encoder.encode(value)
            print(String(data: data, encoding: .utf8) ?? "{}")
        } catch {
            writeError(CLIError.repositoryError("JSON encoding failed: \(error.localizedDescription)"))
        }
    }

    /// Write a structured JSON error object to stderr and exit.
    static func writeError(_ error: CLIError) {
        let payload: [String: String] = [
            "error": error.errorCode,
            "message": error.message
        ]
        if let data = try? encoder.encode(payload),
           let str = String(data: data, encoding: .utf8) {
            fputs(str + "\n", stderr)
        }
    }

    /// Write a plain-text progress line to stderr (visible but not captured by JSON consumers).
    static func writeProgress(_ current: Int, _ total: Int, note: String? = nil) {
        if let note = note {
            fputs("[\(current)/\(total)] \(note)\n", stderr)
        } else {
            fputs("[\(current)/\(total)]\n", stderr)
        }
    }

    /// Write an arbitrary message to stderr.
    static func writeStderr(_ message: String) {
        fputs(message + "\n", stderr)
    }
}

// MARK: - ExportFormat CLI Extension

extension ExportFormat {
    /// Initialize from a CLI string (case-insensitive, accepts aliases).
    init?(cliString: String) {
        switch cliString.lowercased() {
        case "html":             self = .html
        case "md", "markdown":   self = .markdown
        case "rtf":              self = .rtf
        case "txt", "text":      self = .txt
        case "tex", "latex":     self = .tex
        case "pdf":              self = .pdf
        default:                 return nil
        }
    }
}
