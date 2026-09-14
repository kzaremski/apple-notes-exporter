//
//  EngineParityTests.swift
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

import XCTest
@testable import Apple_Notes_Exporter

/// Exports the same notes through the app's engine and the CLI's engine and
/// compares what lands on disk.
///
/// Every bug in this codebase's largest class had the same shape: two engines
/// implementing one behaviour, drifting apart, and nothing noticing. Those were
/// found by reading the two implementations side by side, which does not scale
/// and does not stay done. This does.
///
/// It runs against a generated legacy-schema database, so it needs no Notes
/// library and no Full Disk Access.
@MainActor
final class EngineParityTests: XCTestCase {

    // MARK: - Fixture

    /// The legacy (iOS 8) schema: four plain tables with raw-text bodies. The
    /// parser selects it when ZICNOTEDATA is absent, which avoids needing a
    /// protobuf generator just to have something to export.
    private static let fixtureSQL = """
    CREATE TABLE ZACCOUNT (Z_PK INTEGER PRIMARY KEY, ZACCOUNTIDENTIFIER TEXT, ZNAME TEXT);
    CREATE TABLE ZSTORE (Z_PK INTEGER PRIMARY KEY, ZNAME TEXT, ZACCOUNT INTEGER);
    CREATE TABLE ZNOTEBODY (Z_PK INTEGER PRIMARY KEY, ZCONTENT TEXT);
    CREATE TABLE ZNOTE (Z_PK INTEGER PRIMARY KEY, ZCREATIONDATE REAL,
                        ZMODIFICATIONDATE REAL, ZTITLE TEXT, ZBODY INTEGER, ZSTORE INTEGER);
    INSERT INTO ZACCOUNT VALUES (1, 'fixture-account-1', 'Fixture');
    INSERT INTO ZSTORE VALUES (1, 'Notes', 1);
    INSERT INTO ZSTORE VALUES (2, 'Work', 1);
    INSERT INTO ZNOTEBODY VALUES (1, 'Body with an ampersand & a <tag> and "quotes".');
    INSERT INTO ZNOTEBODY VALUES (2, 'Second note. Unicode: café — dash.');
    INSERT INTO ZNOTEBODY VALUES (3, 'Third note in the Work folder.');
    INSERT INTO ZNOTE VALUES (1, 727012800, 728559000, 'First Note', 1, 1);
    INSERT INTO ZNOTE VALUES (2, 727012800, 728559000, 'Second Note & Friends', 2, 1);
    INSERT INTO ZNOTE VALUES (3, 727012800, 728559000, 'Work Note', 3, 2);
    """

    private func makeFixtureDatabase() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-parity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let db = dir.appendingPathComponent("NoteStore.sqlite")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [db.path]
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        stdin.fileHandleForWriting.write(Data(Self.fixtureSQL.utf8))
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: db.path) else {
            throw XCTSkip("could not build the fixture database with /usr/bin/sqlite3")
        }
        return db.path
    }

    private func makeOutputDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ane-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Comparison

    /// Dates are stamped at export time and legitimately differ between two
    /// runs, so they are masked before comparing. Everything else must match.
    private func normalize(_ text: String) -> String {
        var result = text
        let datePatterns = [
            #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z"#,      // ISO 8601
            #"\d{8}T\d{6}Z"#,                                       // ENEX
            #"\w{3}, \d{2} \w{3} \d{4} \d{2}:\d{2}:\d{2} [+-]\d{4}"#, // RFC 822
            #"\w{3} \d{1,2}, \d{4} at \d{1,2}:\d{2}\s?[AP]M"#,      // medium/short
            #"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#,
        ]
        for pattern in datePatterns {
            result = result.replacingOccurrences(
                of: pattern, with: "<DATE>", options: .regularExpression)
        }
        return result
    }

    private func filesUnder(_ root: URL) -> [String: String] {
        var files: [String: String] = [:]
        // /var and /private/var are the same place; resolve so the relative
        // path strips cleanly whichever form the enumerator hands back.
        let base = root.resolvingSymlinksInPath().path
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            guard !isDirectory.boolValue, !url.lastPathComponent.hasPrefix(".") else { continue }
            let resolved = url.resolvingSymlinksInPath().path
            let relative = resolved.hasPrefix(base + "/")
                ? String(resolved.dropFirst(base.count + 1))
                : url.lastPathComponent
            files[relative] = (try? String(contentsOf: url, encoding: .utf8)) ?? "<binary>"
        }
        return files
    }

    // MARK: - Driving each engine

    private func exportViaApp(
        format: ExportFormat, db: String, to output: URL, configure: (inout ExportConfigurations) -> Void = { _ in }
    ) async throws {
        let repository = DatabaseNotesRepository(databasePath: db)
        let viewModel = ExportViewModel(repository: repository, databasePath: db)
        // Not ExportConfigurations.load(): that reads this machine's real
        // preferences and would make the comparison depend on them.
        var configs = ExportConfigurations.default
        configure(&configs)
        viewModel.configurations = configs

        let notes = try await repository.fetchNotes(includeDeleted: false)
        await viewModel.exportNotes(notes, toDirectory: output, format: format, includeAttachments: true)
    }

    private func exportViaCLI(
        format: ExportFormat, db: String, to output: URL, configure: (inout ExportConfigurations) -> Void = { _ in }
    ) async throws {
        var configs = ExportConfigurations.default
        configure(&configs)
        let engine = CLIExportEngine(databasePath: db, configurations: configs)
        let repository = DatabaseNotesRepository(databasePath: db)
        let notes = try await repository.fetchNotes(includeDeleted: false)
        _ = try await engine.exportNotes(
            notes, toDirectory: output, format: format,
            includeAttachments: true, verbose: false,
            allKnownNoteIds: Set(notes.map(\.id)),
            progressHandler: { _, _ in }
        )
    }

    // MARK: - Tests

    func test_appAndCLIProduceTheSameFilesForEveryTextFormat() async throws {
        let db = try makeFixtureDatabase()

        // The packaged formats carry timestamps and compressed streams, so they
        // never compare byte for byte; they are compared by structure in
        // test_appAndCLIProduceTheSamePackagedStructure.
        let formats = ExportFormat.allCases.filter { !$0.isBinaryFormat }

        var mismatches: [String] = []

        for format in formats {
            let appOut = try makeOutputDirectory()
            let cliOut = try makeOutputDirectory()

            try await exportViaApp(format: format, db: db, to: appOut)
            try await exportViaCLI(format: format, db: db, to: cliOut)

            let appFiles = filesUnder(appOut)
            let cliFiles = filesUnder(cliOut)

            if Set(appFiles.keys) != Set(cliFiles.keys) {
                let onlyApp = Set(appFiles.keys).subtracting(cliFiles.keys).sorted()
                let onlyCLI = Set(cliFiles.keys).subtracting(appFiles.keys).sorted()
                mismatches.append("\(format.rawValue): different files. app-only=\(onlyApp) cli-only=\(onlyCLI)")
                continue
            }

            for (path, appText) in appFiles.sorted(by: { $0.key < $1.key }) {
                let cliText = cliFiles[path] ?? ""
                if normalize(appText) != normalize(cliText) {
                    dump("\(format.rawValue)-\(path)", app: normalize(appText), cli: normalize(cliText))
                    mismatches.append("\(format.rawValue): \(path) differs\n"
                        + "  app: \(firstDifference(normalize(appText), normalize(cliText)))")
                }
            }
        }

        record(mismatches, as: "per-note")
        XCTAssertTrue(
            mismatches.isEmpty,
            "The app and the CLI disagree:\n" + mismatches.joined(separator: "\n")
        )
    }

    func test_appAndCLIAgreeOnSingleFileOutput() async throws {
        let db = try makeFixtureDatabase()
        var mismatches: [String] = []

        for format in ExportFormat.allCases where format.supportsConcatenation {
            let appOut = try makeOutputDirectory()
            let cliOut = try makeOutputDirectory()
            let single = { (c: inout ExportConfigurations) in c.concatenateOutput = true }

            try await exportViaApp(format: format, db: db, to: appOut, configure: single)
            try await exportViaCLI(format: format, db: db, to: cliOut, configure: single)

            let appFiles = filesUnder(appOut)
            let cliFiles = filesUnder(cliOut)

            guard appFiles.count == 1, cliFiles.count == 1 else {
                mismatches.append("\(format.rawValue): expected one file each, got app=\(appFiles.count) cli=\(cliFiles.count)")
                continue
            }
            let appText = normalize(appFiles.values.first ?? "")
            let cliText = normalize(cliFiles.values.first ?? "")
            if appText != cliText {
                dump("single-\(format.rawValue)", app: appText, cli: cliText)
                mismatches.append("\(format.rawValue): joined output differs\n  \(firstDifference(appText, cliText))")
            }
        }

        record(mismatches, as: "single-file")
        XCTAssertTrue(
            mismatches.isEmpty,
            "The app and the CLI disagree on Single File output:\n" + mismatches.joined(separator: "\n")
        )
    }

    /// A parity failure is a long report, and `xcodebuild`'s summary output
    /// truncates assertion messages. Write it somewhere readable too.
    /// DOCX, ODT and EPUB are zip containers whose bytes differ every run, so
    /// compare what is inside them instead: the same files, in the same places.
    ///
    /// PDF is left out. It renders through WebKit asynchronously, which makes
    /// it the one format whose output this test cannot compare cheaply — the
    /// export matrix covers it structurally instead.
    func test_appAndCLIProduceTheSamePackagedStructure() async throws {
        let db = try makeFixtureDatabase()
        var mismatches: [String] = []

        for format in ExportFormat.allCases where format.isBinaryFormat && format != .pdf {
            let appOut = try makeOutputDirectory()
            let cliOut = try makeOutputDirectory()

            try await exportViaApp(format: format, db: db, to: appOut)
            try await exportViaCLI(format: format, db: db, to: cliOut)

            let appFiles = Set(filesUnder(appOut).keys)
            let cliFiles = Set(filesUnder(cliOut).keys)
            guard appFiles == cliFiles else {
                mismatches.append("\(format.rawValue): different files. "
                    + "app-only=\(appFiles.subtracting(cliFiles).sorted()) "
                    + "cli-only=\(cliFiles.subtracting(appFiles).sorted())")
                continue
            }

            for relative in appFiles.sorted() {
                let appMembers = zipMembers(at: appOut.appendingPathComponent(relative))
                let cliMembers = zipMembers(at: cliOut.appendingPathComponent(relative))
                if appMembers.isEmpty {
                    mismatches.append("\(format.rawValue): \(relative) is not a readable zip container")
                } else if appMembers != cliMembers {
                    mismatches.append("\(format.rawValue): \(relative) holds different members. "
                        + "app-only=\(appMembers.subtracting(cliMembers).sorted()) "
                        + "cli-only=\(cliMembers.subtracting(appMembers).sorted())")
                }
            }
        }

        record(mismatches, as: "packaged")
        XCTAssertTrue(
            mismatches.isEmpty,
            "The app and the CLI disagree on packaged output:\n" + mismatches.joined(separator: "\n")
        )
    }

    /// The names of the files inside a zip container, or empty if it is not one.
    private func zipMembers(at url: URL) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return Set(String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init))
    }

    /// Write the two outputs side by side so a mismatch can be inspected with
    /// a real diff tool rather than read out of an assertion message.
    private func dump(_ label: String, app: String, cli: String) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ane-parity-dumps")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = label.replacingOccurrences(of: "/", with: "_")
        try? app.write(to: dir.appendingPathComponent("\(safe).app.txt"), atomically: true, encoding: .utf8)
        try? cli.write(to: dir.appendingPathComponent("\(safe).cli.txt"), atomically: true, encoding: .utf8)
    }

    private func record(_ mismatches: [String], as name: String) {
        guard !mismatches.isEmpty else { return }
        let report = mismatches.joined(separator: "\n")
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ane-parity-\(name).txt")
        try? report.write(to: url, atomically: true, encoding: .utf8)
        print("PARITY REPORT (\(name)) written to \(url.path); "
            + "the two outputs for each mismatch are in "
            + "\(URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ane-parity-dumps").path)"
            + "\n\(report)")
    }

    /// Describe how two outputs differ.
    ///
    /// Reports the lines present in one and not the other rather than a
    /// position-by-position diff: a single extra line near the top shifts
    /// everything below it and makes a positional diff read as total
    /// disagreement.
    private func firstDifference(_ a: String, _ b: String) -> String {
        let aLines = a.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let bLines = b.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let onlyApp = Array(Set(aLines).subtracting(bLines)).filter { !$0.isEmpty }.sorted()
        let onlyCLI = Array(Set(bLines).subtracting(aLines)).filter { !$0.isEmpty }.sorted()

        var parts: [String] = ["lines app=\(aLines.count) cli=\(bLines.count)"]
        if !onlyApp.isEmpty {
            parts.append("  only in app (\(onlyApp.count)): " + onlyApp.prefix(4).map { String($0.prefix(120)) }.joined(separator: " | "))
        }
        if !onlyCLI.isEmpty {
            parts.append("  only in cli (\(onlyCLI.count)): " + onlyCLI.prefix(4).map { String($0.prefix(120)) }.joined(separator: " | "))
        }
        if onlyApp.isEmpty && onlyCLI.isEmpty {
            parts.append("  same lines, different order or whitespace")
        }
        return parts.joined(separator: "\n")
    }
}
