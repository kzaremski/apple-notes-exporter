//
//  utilities.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/12/24.
//

import Foundation

func sanitizeFileNameString(inputFilename: String, outputFormat: String) -> String {
    // Define CharacterSet of invalid characters which we will remove from the filenames
    var invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        .union(.newlines)
        .union(.illegalCharacters)
        .union(.controlCharacters)
    // If we are exporting to markdown, then there are even more invalid characters
    if outputFormat == "MD" {
        invalidCharacters = invalidCharacters.union(CharacterSet(charactersIn: "[#]^"))
    }
    // Filter out the illegal characters
    let output = inputFilename.components(separatedBy: invalidCharacters).joined(separator: "")
    // Filter out Emojis for more reliable unzipping
    return output.unicodeScalars.filter { !($0.properties.isEmoji && $0.properties.isEmojiPresentation) }.map { String($0) }.joined()
}

func createDirectoryIfNotExists(location: URL) {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: location.path) {
        do {
            try fileManager.createDirectory(at: location, withIntermediateDirectories: false)
        } catch {
            print("Error creating directory at \(location.absoluteString)")
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
            print("Error: \(error)")
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
            print("Failed to copy \(coordinatorOutputFile) to \(outputZipFile): \(error)")
        }
    }
}
