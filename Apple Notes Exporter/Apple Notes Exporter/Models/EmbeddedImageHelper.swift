//
//  EmbeddedImageHelper.swift
//  Apple Notes Exporter
//
//  Copyright (C) 2026 Konstantin Zaremski
//  Licensed under GPL v3.
//
//  Pulls inline base64 <img> tags out of generated HTML and packages them
//  for binary archive formats (DOCX, ODT). The HTML pipeline already
//  embeds image attachments as data: URIs when `embedImagesInline` is
//  true, so we can decode them straight out of the HTML body without
//  re-fetching from the Notes DB.
//

import Foundation

/// One image extracted from the HTML body, ready to be packaged into
/// `word/media/` or `Pictures/`.
struct EmbeddedImageRef {
    /// Unique relationship-id slot, e.g. "rId100". Caller picks the prefix.
    let rId: String
    /// File extension without the dot ("jpg", "png", "gif", "pdf", ...).
    let ext: String
    /// Raw image bytes.
    let data: Data
    /// Pixel dimensions if we could read them from the file header.
    let widthPx: Int?
    let heightPx: Int?
}

enum EmbeddedImageExtractor {

    /// Scan `html` for `<img src="data:...">` tags, decode each one, replace
    /// the tag with a self-closing `<imgref id="rId<N>"/>` marker that the
    /// DOCX/ODT parsers can recognise. Returns the rewritten HTML plus the
    /// collected images.
    ///
    /// Non-data `<img>` tags (relative-path URLs) are left alone so the
    /// existing `[Image]` placeholder logic handles them — embedding those
    /// would require knowing the export directory, out of scope here.
    static func extract(html: String, startingRId: Int = 100) -> (html: String, images: [EmbeddedImageRef]) {
        var out = ""
        var images: [EmbeddedImageRef] = []
        var nextRId = startingRId

        let chars = Array(html)
        var i = 0
        while i < chars.count {
            if chars[i] == "<",
               i + 4 < chars.count,
               (chars[i+1] == "i" || chars[i+1] == "I"),
               (chars[i+2] == "m" || chars[i+2] == "M"),
               (chars[i+3] == "g" || chars[i+3] == "G"),
               (chars[i+4] == " " || chars[i+4] == "\t" || chars[i+4] == "\n" || chars[i+4] == "/" || chars[i+4] == ">") {

                // Find matching '>' (no nested tags inside attrs)
                var j = i
                while j < chars.count && chars[j] != ">" { j += 1 }
                if j >= chars.count { out.append(chars[i]); i += 1; continue }

                let tagText = String(chars[i...j])
                if let imgRef = parseDataURIImg(tagText: tagText, rId: "rId\(nextRId)") {
                    images.append(imgRef)
                    out.append("<imgref id=\"\(imgRef.rId)\"/>")
                    nextRId += 1
                } else {
                    // Not a data: URI img (or unparseable). Leave the tag verbatim.
                    out.append(tagText)
                }
                i = j + 1
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return (out, images)
    }

    // MARK: - Tag parsing

    private static func parseDataURIImg(tagText: String, rId: String) -> EmbeddedImageRef? {
        // Look for src="data:<mime>;base64,<payload>"
        guard let srcRange = tagText.range(of: "src=\"data:", options: .caseInsensitive) else { return nil }
        let afterSrc = tagText[srcRange.upperBound...]
        guard let closeQuote = afterSrc.firstIndex(of: "\"") else { return nil }
        let dataURI = String(afterSrc[..<closeQuote])  // "<mime>;base64,<payload>"

        guard let commaIdx = dataURI.firstIndex(of: ",") else { return nil }
        let prefix = dataURI[..<commaIdx]
        let payload = String(dataURI[dataURI.index(after: commaIdx)...])

        // prefix looks like: "image/jpeg;base64"
        guard prefix.lowercased().contains(";base64") else { return nil }
        let mime = String(prefix[..<(prefix.firstIndex(of: ";") ?? prefix.endIndex)])

        // Strip any whitespace the renderer might have wrapped in.
        let cleaned = payload.filter { !$0.isWhitespace }
        guard let bytes = Data(base64Encoded: cleaned) else { return nil }

        // Prefer magic-byte detection (more reliable than the MIME hint).
        let extByMagic = detectFileExtension(from: bytes)
        let extByMime = extensionForMime(mime)
        let ext = extByMagic ?? extByMime ?? "bin"

        let dims = imageDimensions(data: bytes, ext: ext)

        return EmbeddedImageRef(
            rId: rId,
            ext: ext,
            data: bytes,
            widthPx: dims?.w,
            heightPx: dims?.h
        )
    }

    private static func extensionForMime(_ mime: String) -> String? {
        switch mime.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/tiff": return "tiff"
        case "image/webp": return "webp"
        case "image/bmp": return "bmp"
        case "image/svg+xml": return "svg"
        case "application/pdf": return "pdf"
        default: return nil
        }
    }

    // MARK: - Dimension parsing

    /// Return pixel dimensions for the supported image types. Used to size
    /// the DrawingML extent box; if unknown, callers fall back to a default.
    static func imageDimensions(data: Data, ext: String) -> (w: Int, h: Int)? {
        switch ext.lowercased() {
        case "png":  return pngDimensions(data)
        case "jpg", "jpeg": return jpegDimensions(data)
        case "gif":  return gifDimensions(data)
        default: return nil
        }
    }

    private static func pngDimensions(_ data: Data) -> (w: Int, h: Int)? {
        // IHDR chunk lives at offset 16..23: width (BE u32), height (BE u32).
        guard data.count >= 24 else { return nil }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 else { return nil }
        let w = (Int(bytes[16]) << 24) | (Int(bytes[17]) << 16) | (Int(bytes[18]) << 8) | Int(bytes[19])
        let h = (Int(bytes[20]) << 24) | (Int(bytes[21]) << 16) | (Int(bytes[22]) << 8) | Int(bytes[23])
        return (w, h)
    }

    private static func jpegDimensions(_ data: Data) -> (w: Int, h: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var i = 2
        while i + 8 < bytes.count {
            guard bytes[i] == 0xFF else { return nil }
            // Skip fill bytes
            var marker = bytes[i + 1]
            i += 2
            while marker == 0xFF && i < bytes.count {
                marker = bytes[i]; i += 1
            }
            // SOFn markers (Start Of Frame) hold the dimensions.
            // 0xC0-0xCF except 0xC4 (DHT), 0xC8 (JPG), 0xCC (DAC).
            if marker >= 0xC0 && marker <= 0xCF && marker != 0xC4 && marker != 0xC8 && marker != 0xCC {
                guard i + 7 < bytes.count else { return nil }
                let h = (Int(bytes[i + 3]) << 8) | Int(bytes[i + 4])
                let w = (Int(bytes[i + 5]) << 8) | Int(bytes[i + 6])
                return (w, h)
            }
            // Otherwise skip this segment using its length.
            guard i + 1 < bytes.count else { return nil }
            let segLen = (Int(bytes[i]) << 8) | Int(bytes[i + 1])
            if segLen < 2 { return nil }
            i += segLen
        }
        return nil
    }

    private static func gifDimensions(_ data: Data) -> (w: Int, h: Int)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 10,
              bytes[0] == 0x47, bytes[1] == 0x49, bytes[2] == 0x46 else { return nil }
        let w = Int(bytes[6]) | (Int(bytes[7]) << 8)  // little-endian
        let h = Int(bytes[8]) | (Int(bytes[9]) << 8)
        return (w, h)
    }
}

// MARK: - Hyperlinks

/// One hyperlink lifted out of the HTML body. DOCX needs a Relationship
/// entry under `word/_rels/document.xml.rels`; ODT inlines the href on
/// `<text:a xlink:href="…"/>` directly, but both use the same rId as a
/// lookup key in the parser's dictionary.
struct HyperlinkRef {
    let rId: String
    let href: String
}

enum HyperlinkExtractor {

    /// Walk the HTML, replace each `<a href="X">...</a>` pair with
    /// `<hrefopen id="rIdN"/>...<hrefclose/>` marker pairs that the DOCX
    /// and ODT parsers can recognise. Anchors without an href (or
    /// non-text targets like javascript:) are left untouched so the
    /// existing underline fallback still applies.
    static func extract(html: String, startingRId: Int = 500) -> (html: String, links: [HyperlinkRef]) {
        var result = ""
        var links: [HyperlinkRef] = []
        var nextRId = startingRId
        let chars = Array(html)
        var i = 0
        while i < chars.count {
            if chars[i] == "<",
               i + 2 < chars.count,
               (chars[i+1] == "a" || chars[i+1] == "A"),
               (chars[i+2] == " " || chars[i+2] == "\t" || chars[i+2] == "\n") {
                // Find closing '>' for this opening tag
                var j = i
                while j < chars.count && chars[j] != ">" { j += 1 }
                if j >= chars.count { result.append(chars[i]); i += 1; continue }
                let tag = String(chars[i...j])
                if let href = extractHref(tag), isSupportedHref(href) {
                    let rId = "rId\(nextRId)"
                    nextRId += 1
                    links.append(HyperlinkRef(rId: rId, href: href))
                    result.append("<hrefopen id=\"\(rId)\"/>")
                    i = j + 1
                    continue
                }
                // No usable href; leave the tag verbatim.
                result.append(tag)
                i = j + 1
                continue
            }
            // Closing </a>
            if chars[i] == "<",
               i + 3 < chars.count,
               chars[i+1] == "/",
               (chars[i+2] == "a" || chars[i+2] == "A"),
               chars[i+3] == ">" {
                result.append("<hrefclose/>")
                i += 4
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return (result, links)
    }

    private static func extractHref(_ tag: String) -> String? {
        guard let r = tag.range(of: "href=\"", options: .caseInsensitive) else { return nil }
        let after = tag[r.upperBound...]
        guard let end = after.firstIndex(of: "\"") else { return nil }
        let raw = String(after[..<end])
        // Decode the common XML entities so the URL is usable.
        return raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }

    /// Skip schemes that don't make sense outside the browser (javascript:),
    /// or anchors with no target.
    private static func isSupportedHref(_ href: String) -> Bool {
        let trimmed = href.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return false }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("javascript:") { return false }
        return true
    }
}
