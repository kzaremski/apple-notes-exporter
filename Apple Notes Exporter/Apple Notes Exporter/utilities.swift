//
//  utilities.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 5/12/24.
//

import Foundation
import WebKit
import OSLog

class HTMLtoPDF: NSObject, WKNavigationDelegate {
    var webView: WKWebView!
    var htmlString: String
    var completion: ((Result<Data, Error>) -> Void)?
    var loadingTimeout: TimeInterval = 60 // Set a reasonable timeout interval
    var timeoutTimer: Timer?

    init(htmlString: String) {
        self.htmlString = htmlString
        self.webView = WKWebView()
    }

    func convert(completion: @escaping (Result<Data, Error>) -> Void) {
        self.webView.navigationDelegate = self
        self.completion = completion
        self.webView.loadHTMLString(htmlString, baseURL: nil)

        // Set a timeout to handle cases where loading takes too long
        timeoutTimer = Timer.scheduledTimer(timeInterval: loadingTimeout, target: self, selector: #selector(handleTimeout), userInfo: nil, repeats: false)
    }

    @objc func handleTimeout() {
        Logger.noteExport.error("HTML to PDF loading timeout")
        completion?(.failure(NSError(domain: "HTMLtoPDF", code: -1, userInfo: [NSLocalizedDescriptionKey: "Loading timed out"])))
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        createPDF()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Logger.noteExport.error("Failed loading HTML with error: \(error.localizedDescription)")
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        completion?(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Logger.noteExport.error("Failed provisional navigation with error: \(error.localizedDescription)")
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        completion?(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Logger.noteExport.error("Web content process terminated")
        completion?(.failure(NSError(domain: "HTMLtoPDF", code: -2, userInfo: [NSLocalizedDescriptionKey: "Web content process terminated"])))
    }

    func createPDF() {
        let pdfConfiguration = WKPDFConfiguration()
        let pageSize = CGSize(width: PAGE_US_LETTER.width, height: PAGE_US_LETTER.height)
        pdfConfiguration.rect = CGRect(origin: .zero, size: pageSize)
        
        // Auto paginate by setting the size of the contentRect
        webView.evaluateJavaScript("document.body.scrollHeight") { (result, error) in
            if let scrollHeight = result as? CGFloat {
                let contentHeight = scrollHeight
                // let pageCount = ceil(contentHeight / pageSize.height);
                
                // Adjust the configuration rect to cover the entire content
                pdfConfiguration.rect = CGRect(x: 0, y: 100, width: pageSize.width, height: contentHeight)
                
                // Create the PDF
                self.webView.createPDF(configuration: pdfConfiguration) { result in
                    switch result {
                    case .success(let data):
                        self.completion?(.success(data))
                    case .failure(let error):
                        self.completion?(.failure(error))
                    }
                }
            } else {
                self.completion?(.failure(error ?? NSError(domain: "HTMLtoPDF", code: -3, userInfo: [NSLocalizedDescriptionKey: "Unable to determine content height"])))
            }
        }
    }
}

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
