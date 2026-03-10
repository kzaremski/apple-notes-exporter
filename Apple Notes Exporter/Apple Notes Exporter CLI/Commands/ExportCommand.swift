//
//  ExportCommand.swift
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

import ArgumentParser
import Foundation

// MARK: - export

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export notes to files.",
        discussion: "PDF is not supported in the CLI. Export as HTML and convert with a PDF printer or pandoc."
    )

    // Required
    @Option(name: .shortAndLong, help: "Output directory (will be created if it does not exist).")
    var output: String

    @Option(name: .shortAndLong, help: "Export format: html, markdown (md), rtf, txt, tex.")
    var format: String = "markdown"

    // Note selection filters
    @Option(name: .long, help: "Export only these note IDs (comma-separated).")
    var notes: String?

    @Option(name: .long, help: "Filter by account name (partial match, case-insensitive).")
    var account: String?

    @Option(name: .long, help: "Filter by folder name (partial match, case-insensitive).")
    var folder: String?

    @Option(name: .long, help: "Filter notes whose title contains this string (case-insensitive).")
    var titleContains: String?

    @Option(name: .long, help: "Include notes modified after this ISO 8601 date.")
    var modifiedAfter: String?

    @Option(name: .long, help: "Include notes modified before this ISO 8601 date.")
    var modifiedBefore: String?

    // Export options
    @Flag(name: .long, help: "Skip exporting attachments.")
    var noAttachments: Bool = false

    @Flag(name: .long, help: "Add creation date prefix to filenames.")
    var addDatePrefix: Bool = false

    @Option(name: .long, help: "Date format for prefix: iso (yyyy-MM-dd), us (MM-dd-yyyy), eu (dd-MM-yyyy).")
    var dateFormat: String = "iso"

    @Flag(name: .long, help: "Concatenate all notes into a single output file.")
    var concatenate: Bool = false

    @Flag(name: .long, help: "Incremental sync: only export new or changed notes.")
    var incremental: Bool = false

    @Flag(name: .long, help: "Delete the sync manifest before exporting, forcing a full re-export. Only effective with --incremental.")
    var resetSync: Bool = false

    // HTML/content styling
    @Option(name: .long, help: "Font family: system (default), serif, sans-serif, monospace.")
    var fontFamily: String = "system"

    @Option(name: .long, help: "Font size in points (default: 14).")
    var fontSize: Double = 14.0

    // Output control
    @Flag(name: .shortAndLong, help: "Print per-note progress to stderr.")
    var verbose: Bool = false

    @OptionGroup var dbOptions: DatabaseOptions

    func run() async throws {
        // Validate format
        guard let exportFormat = ExportFormat(cliString: format) else {
            CLIOutput.writeError(.repositoryError("Unknown format '\(format)'. Valid formats: html, markdown, rtf, txt, tex."))
            throw ExitCode(2)
        }

        guard exportFormat != .pdf else {
            CLIOutput.writeError(.unsupportedFormat(.pdf))
            throw ExitCode(2)
        }

        // Resolve and create output directory
        let outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        } catch {
            CLIOutput.writeError(.invalidOutputDirectory(output))
            throw ExitCode(2)
        }

        // Build configurations
        var configs = ExportConfigurations.default
        configs.includeAttachments = !noAttachments
        configs.addDateToFilename = addDatePrefix
        configs.concatenateOutput = concatenate
        configs.incrementalSync = incremental

        // Delete sync manifest when --reset-sync is requested (must happen before engine loads it)
        if resetSync {
            let manifestURL = outputURL.appendingPathComponent(SyncManifest.filename)
            try? FileManager.default.removeItem(at: manifestURL)
            if verbose { CLIOutput.writeStderr("Sync manifest deleted; next export will be a full re-export.") }
        }

        // Map date format
        switch dateFormat.lowercased() {
        case "us":   configs.filenameDateFormat = .usDate
        case "eu":   configs.filenameDateFormat = .euDate
        default:     configs.filenameDateFormat = .iso
        }

        // Map font family (handle hyphenated names like "sans-serif" → "Sans-Serif")
        let normalizedFontFamily = fontFamily.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: "-")
        if let ff = HTMLConfiguration.FontFamily(rawValue: normalizedFontFamily) {
            configs.html = HTMLConfiguration(
                fontSizePoints: fontSize,
                fontFamily: ff,
                marginSize: configs.html.marginSize,
                marginUnit: configs.html.marginUnit,
                embedImagesInline: configs.html.embedImagesInline,
                linkEmbeddedImages: configs.html.linkEmbeddedImages
            )
        } else {
            configs.html = HTMLConfiguration(
                fontSizePoints: fontSize,
                fontFamily: .system,
                marginSize: configs.html.marginSize,
                marginUnit: configs.html.marginUnit,
                embedImagesInline: configs.html.embedImagesInline,
                linkEmbeddedImages: configs.html.linkEmbeddedImages
            )
        }

        let engine = CLIExportEngine(databasePath: dbOptions.db, configurations: configs)

        // Fetch all notes then apply filters
        let (accounts, folders, allNotes): ([NotesAccount], [NotesFolder], [NotesNote])
        do {
            async let a = engine.fetchAccounts()
            async let f = engine.fetchFolders()
            async let n = engine.fetchNotes()
            (accounts, folders, allNotes) = try await (a, f, n)
        } catch {
            CLIOutput.writeError(.databaseUnavailable)
            throw ExitCode(CLIError.databaseUnavailable.exitCode)
        }

        var filtered = allNotes

        // Filter by explicit note IDs
        if let noteIdsStr = notes {
            let ids = Set(noteIdsStr.split(separator: ",").map { String($0.trimmingCharacters(in: .whitespaces)) })
            filtered = filtered.filter { ids.contains($0.id) }
        }

        if let accountFilter = account?.lowercased() {
            let matchingIds = accounts.filter { $0.name.lowercased().contains(accountFilter) }.map { $0.id }
            filtered = filtered.filter { matchingIds.contains($0.accountId) }
        }

        if let folderFilter = folder?.lowercased() {
            let matchingIds = folders.filter { $0.name.lowercased().contains(folderFilter) }.map { $0.id }
            filtered = filtered.filter { matchingIds.contains($0.folderId) }
        }

        if let tc = titleContains?.lowercased() {
            filtered = filtered.filter { $0.title.lowercased().contains(tc) }
        }

        if let dateStr = modifiedAfter, let date = parseDate(dateStr) {
            filtered = filtered.filter { $0.modificationDate > date }
        }
        if let dateStr = modifiedBefore, let date = parseDate(dateStr) {
            filtered = filtered.filter { $0.modificationDate < date }
        }

        if filtered.isEmpty {
            CLIOutput.writeJSON(
                CLIExportEngine.ExportResult(
                    success: true,
                    exported: 0,
                    skipped: 0,
                    failed: 0,
                    failedAttachments: 0,
                    outputDirectory: outputURL.path,
                    format: exportFormat.fileExtension,
                    durationSeconds: 0.0
                )
            )
            return
        }

        if verbose { CLIOutput.writeStderr("Exporting \(filtered.count) notes as \(exportFormat.rawValue) to \(outputURL.path)") }

        do {
            let result = try await engine.exportNotes(
                filtered,
                toDirectory: outputURL,
                format: exportFormat,
                includeAttachments: !noAttachments,
                verbose: verbose,
                progressHandler: { current, total in
                    CLIOutput.writeProgress(current, total)
                }
            )
            CLIOutput.writeJSON(result)
            if result.failed > 0 {
                throw ExitCode(1)
            }
        } catch let error as CLIError {
            CLIOutput.writeError(error)
            throw ExitCode(error.exitCode)
        }
    }

    // MARK: - Date Parsing

    private func parseDate(_ string: String) -> Date? {
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFull.date(from: string) { return date }

        let isoBasic = ISO8601DateFormatter()
        if let date = isoBasic.date(from: string) { return date }

        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        dateOnly.timeZone = TimeZone(identifier: "UTC")
        return dateOnly.date(from: string)
    }
}
