//
//  utilities.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/12/24.
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
