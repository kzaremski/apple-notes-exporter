//
//  utilities.swift
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
import OSLog

func toFixed(_ number: Double, _ fractionDigits: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = fractionDigits
    formatter.maximumFractionDigits = fractionDigits
    
    return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
}

func timeRemainingFormatter(_ timeInterval: TimeInterval) -> String {
    // Time formatter (for the time remaining)
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = [.hour, .minute, .second]
    formatter.unitsStyle = .abbreviated
    return formatter.string(from: timeInterval)!
}

func sanitizeFileNameString(_ inputFilename: String) -> String {
    // Define CharacterSet of invalid characters which we will remove from the filenames
    let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        .union(.newlines)
        .union(.illegalCharacters)
        .union(.controlCharacters)
    // If we are exporting to markdown, then there are even more invalid characters
    //if outputFormat == "MD" {
    //    invalidCharacters = invalidCharacters.union(CharacterSet(charactersIn: "[#]^"))
    //}
    // Filter out the illegal characters
    return inputFilename.components(separatedBy: invalidCharacters).joined(separator: "")
}

func createDirectoryIfNotExists(location: URL) {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: location.path) {
        do {
            try fileManager.createDirectory(at: location, withIntermediateDirectories: false)
        } catch {
            Logger.noteExport.error("Error creating directory at \(location.absoluteString): \(error.localizedDescription)")
        }

    }
}

func zipDirectory(inputDirectory: URL, outputZipFile: URL) {
    // NSFileCoordinator
    let coordinator = NSFileCoordinator()
    let zipIntent = NSFileAccessIntent.readingIntent(with: inputDirectory, options: [.forUploading])
    // ZIP the input directory
    coordinator.coordinate(with: [zipIntent], queue: .main) { errorQ in
        if let error = errorQ {
            Logger.noteExport.error("Zip coordination error: \(error.localizedDescription)")
            return
        }
        // Get the location of the ZIP file to be copied
        let coordinatorOutputFile = zipIntent.url
        // Copy the output to the output ZIP file location
        do {
            if FileManager.default.fileExists(atPath: outputZipFile.path) {
                try FileManager.default.removeItem(at: outputZipFile)
            }
            try FileManager.default.copyItem(at: coordinatorOutputFile, to: outputZipFile)
        } catch (let error) {
            Logger.noteExport.error("Failed to copy \(coordinatorOutputFile) to \(outputZipFile): \(error.localizedDescription)")
        }
    }
}

func appleDateStringToDate(inputString: String) -> Date {
    // Possible date formats used by AppleScript/Apple Notes
    let dateFormats = [
        "EEEE, MMMM d, yyyy 'at' h:mm:ss a",  // Monday, June 21, 2021 at 10:40:09 PM
        "EEEE, MMM d, yyyy 'at' h:mm:ss a",   // Mon, Jun 21, 2021 at 10:40:09 PM
        "EEEE, MMM d, yyyy, h:mm:ss a",       // Mon, Jun 21, 2021, 10:40:09 PM
        "MMMM d, yyyy 'at' h:mm:ss a",        // June 21, 2021 at 10:40:09 PM
        "MMM d, yyyy 'at' h:mm:ss a",         // Jun 21, 2021 at 10:40:09 PM
        "MMMM d, yyyy, h:mm:ss a",            // June 21, 2021, 10:40:09 PM
        "MMM d, yyyy, h:mm:ss a"              // Jun 21, 2021, 10:40:09 PM
    ]

    // Attempt to parse the date using different formats and locales
    for format in dateFormats {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = format
        dateFormatter.locale = Locale(identifier: "en_US_POSIX") // POSIX locale for consistency
        dateFormatter.timeZone = TimeZone.current

        if let date = dateFormatter.date(from: inputString) {
            return date
        }
    }

    // Return current date if no format matched
    return Date()
}
