//
//  CLIError.swift
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

// MARK: - CLI Errors

enum CLIError: Error {
    case databaseUnavailable
    case noNotesFound
    case invalidOutputDirectory(String)
    case unsupportedFormat(ExportFormat)
    case repositoryError(String)
    case fileSystemError(String)

    var exitCode: Int32 {
        switch self {
        case .databaseUnavailable:    return 2
        case .noNotesFound:           return 0   // not an error — empty result
        case .invalidOutputDirectory: return 2
        case .unsupportedFormat:      return 2
        case .repositoryError:        return 2
        case .fileSystemError:        return 1
        }
    }

    var errorCode: String {
        switch self {
        case .databaseUnavailable:       return "databaseUnavailable"
        case .noNotesFound:              return "noNotesFound"
        case .invalidOutputDirectory:    return "invalidOutputDirectory"
        case .unsupportedFormat:         return "unsupportedFormat"
        case .repositoryError:           return "repositoryError"
        case .fileSystemError:           return "fileSystemError"
        }
    }

    var message: String {
        switch self {
        case .databaseUnavailable:
            return "Cannot read the Notes database. Grant Full Disk Access to Terminal in System Settings → Privacy & Security → Full Disk Access."
        case .noNotesFound:
            return "No notes found matching the specified criteria."
        case .invalidOutputDirectory(let path):
            return "Invalid or inaccessible output directory: \(path)"
        case .unsupportedFormat(let format):
            return "Format '\(format.rawValue)' is not supported in the CLI. Supported formats: html, markdown, rtf, txt, tex. For PDF, export as HTML and convert using a PDF printer or pandoc."
        case .repositoryError(let detail):
            return "Repository error: \(detail)"
        case .fileSystemError(let detail):
            return "File system error: \(detail)"
        }
    }
}
