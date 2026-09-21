//
//  PaperVectorPDF.swift
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
import CoreGraphics
import ImageIO

// Turns a decoded `PaperDocument` into a paginated, resolution-independent
// PDF. Every stroke becomes a filled outline, so the result stays sharp at any
// zoom and prints at the printer's resolution rather than the canvas
// thumbnail's. See PaperVector.swift for where the strokes come from and why
// PaperKit's own renderer is not used.

// MARK: - Options

struct PaperVectorPDFOptions {
    var pageSize: CGSize
    var margin: Double
    /// Scale the writing up until it spans the page's text width, instead of
    /// reproducing the canvas at its stored size. A Notes canvas is 768pt wide
    /// -- wider than a Letter page's text column -- so without this the
    /// handwriting comes out smaller on paper than it was on screen.
    var maximizeContent: Bool
    /// Trim the empty canvas around the writing before laying it out.
    var cropToContent: Bool
    /// Fill each page with as much writing as fits without ever cutting a
    /// stroke.
    var breakAtWhitespace: Bool
    /// Never magnify beyond this. Short notes would otherwise be blown up to
    /// absurd sizes on their single page.
    var maximumScale: Double
    /// Height-to-width ratio of one page's worth of canvas.
    ///
    /// nil fills each page with as much writing as it holds. Setting it makes
    /// every page show a fixed shape of canvas instead -- an iPad screen's
    /// worth, say -- which is letterboxed on the paper when the two shapes
    /// disagree. That is the point: the pages then read like the screen the
    /// note was written on rather than like the paper it is printed on.
    var sliceAspectRatio: Double?

    static let `default` = PaperVectorPDFOptions(
        pageSize: CGSize(width: 612, height: 792),
        margin: 28,
        maximizeContent: true,
        cropToContent: true,
        breakAtWhitespace: true,
        maximumScale: 4,
        sliceAspectRatio: nil
    )
}

enum PaperVectorPDFError: LocalizedError {
    case emptyDocument
    case cannotCreateContext(URL)

    var errorDescription: String? {
        switch self {
        case .emptyDocument:             return "The paper attachment contains no strokes or images."
        case .cannotCreateContext(let u): return "Could not create a PDF at \(u.path)."
        }
    }
}

// MARK: - Renderer

enum PaperVectorPDF {

    /// Render `document` to `url`. Returns the number of pages written.
    @discardableResult
    static func write(_ document: PaperDocument,
                      to url: URL,
                      title: String,
                      options: PaperVectorPDFOptions = .default) throws -> Int {
        try write([document], to: url, title: title, options: options)
    }

    /// Render several canvases into one PDF, each starting on a fresh page. A
    /// note can hold more than one handwriting attachment; they are separate
    /// canvases with their own sizes, so each is laid out on its own terms.
    @discardableResult
    static func write(_ documents: [PaperDocument],
                      to url: URL,
                      title: String,
                      options: PaperVectorPDFOptions = .default) throws -> Int {
        let drawable = documents.filter { !$0.isEmpty }
        guard !drawable.isEmpty else { throw PaperVectorPDFError.emptyDocument }

        var mediaBox = CGRect(origin: .zero, size: options.pageSize)
        let info: [String: Any] = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "Apple Notes Exporter"
        ]
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw PaperVectorPDFError.cannotCreateContext(url)
        }

        let contentWidth = options.pageSize.width - 2 * options.margin
        let contentHeight = options.pageSize.height - 2 * options.margin
        var pageCount = 0

        for document in drawable {
            let strokes = document.strokes.map { ($0.transformedPoints, $0.color) }
            let images = document.images.map { ($0.frame, cgImage(from: $0.data)) }
            let layout = Layout(document: document, strokeGeometry: strokes.map { $0.0 }, options: options)

            for page in layout.pages {
                context.beginPDFPage(nil)
                context.saveGState()
                // Nothing may bleed into the margins, whatever the page holds.
                context.clip(to: CGRect(x: options.margin, y: options.margin,
                                        width: contentWidth, height: contentHeight))
                // Canvas coordinates grow downward from the top left; PDF user
                // space grows upward from the bottom left.
                context.translateBy(x: options.margin + layout.insetX(for: page, contentWidth: contentWidth),
                                    y: options.pageSize.height - options.margin)
                context.scaleBy(x: page.scale, y: -page.scale)
                context.translateBy(x: -layout.originX, y: -page.top)

                for index in page.imageIndices {
                    let (frame, image) = images[index]
                    guard let image else { continue }
                    context.saveGState()
                    // Flip back for the image, which CoreGraphics draws bottom-up.
                    context.translateBy(x: frame.minX, y: frame.minY + frame.height)
                    context.scaleBy(x: 1, y: -1)
                    context.draw(image, in: CGRect(origin: .zero, size: frame.size))
                    context.restoreGState()
                }

                for index in page.strokeIndices {
                    let (points, color) = strokes[index]
                    context.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: color.a)
                    addOutline(of: points, to: context)
                    context.fillPath()
                }

                context.restoreGState()
                context.endPDFPage()
                pageCount += 1
            }
        }

        context.closePDF()
        return pageCount
    }

    // MARK: Pagination

    private struct Page {
        /// Canvas Y drawn at the top margin of this page.
        var top: Double
        /// Usually the layout's scale; smaller only when one indivisible
        /// element is taller than a page on its own.
        var scale: Double
        var strokeIndices: [Int] = []
        var imageIndices: [Int] = []
    }

    /// One thing that has to land whole on a single page.
    private struct Element {
        enum Kind { case stroke, image }
        var kind: Kind
        var index: Int
        var box: CGRect
    }

    private struct Layout {
        var originX: Double
        /// Canvas width every page draws, before scaling.
        var areaWidth: Double = 0
        /// Whether a page narrower than the text column is centred rather than
        /// left-aligned. Only a fixed slice shape leaves that gap.
        var centersHorizontally = false
        var pages: [Page]

        /// Left inset that centres this page's content in the text column.
        func insetX(for page: Page, contentWidth: Double) -> Double {
            guard centersHorizontally else { return 0 }
            return max(0, (contentWidth - areaWidth * page.scale) / 2)
        }

        init(document: PaperDocument, strokeGeometry: [[PaperStrokePoint]], options: PaperVectorPDFOptions) {
            let contentWidth = options.pageSize.width - 2 * options.margin
            let contentHeight = options.pageSize.height - 2 * options.margin

            let content = document.contentBounds
            let padding: Double = 6
            let area: CGRect
            if options.cropToContent {
                area = content.insetBy(dx: -padding, dy: -padding)
            } else {
                area = CGRect(x: document.bounds.minX, y: content.minY - padding,
                              width: max(document.bounds.width, content.width),
                              height: content.height + 2 * padding)
            }
            originX = area.minX
            areaWidth = area.width

            let fitScale = area.width > 0 ? contentWidth / area.width : 1
            var scale: Double
            var sliceHeight: Double
            if let ratio = options.sliceAspectRatio, ratio > 0, area.width > 0 {
                // Each page carries a fixed shape of canvas, so the scale is
                // whatever makes that whole shape fit the paper.
                sliceHeight = area.width * ratio
                scale = min(fitScale, contentHeight / sliceHeight)
                if !options.maximizeContent { scale = min(scale, 1) }
                scale = min(scale, options.maximumScale)
                centersHorizontally = true
            } else {
                // Never wider than the page, whether or not we are maximising.
                scale = options.maximizeContent ? min(fitScale, options.maximumScale) : min(fitScale, 1)
                sliceHeight = scale > 0 ? contentHeight / scale : contentHeight
            }

            var elements: [Element] = []
            for (i, points) in strokeGeometry.enumerated() {
                guard let box = PaperVectorPDF.boundingBox(points) else { continue }
                elements.append(Element(kind: .stroke, index: i, box: box))
            }
            for (i, image) in document.images.enumerated() {
                elements.append(Element(kind: .image, index: i, box: image.frame))
            }
            guard !elements.isEmpty else {
                pages = [Page(top: area.minY, scale: scale)]
                return
            }
            // Top edge order, so pages come out in reading order.
            elements.sort { $0.box.minY < $1.box.minY }

            if options.breakAtWhitespace {
                pages = Layout.pack(elements, sliceHeight: sliceHeight, scale: scale,
                                    contentHeight: contentHeight, padding: padding)
            } else {
                pages = Layout.band(elements, from: area.minY, to: area.maxY,
                                    sliceHeight: sliceHeight, scale: scale)
            }
        }

        /// Fill each page with consecutive elements until the next one would
        /// not fit whole, then start the next page at that element.
        static func pack(_ elements: [Element], sliceHeight: Double, scale: Double,
                         contentHeight: Double, padding: Double) -> [Page] {
            var pages: [Page] = []
            var current: Page?
            var currentBottom = 0.0

            func close() {
                guard var page = current else { return }
                // An element taller than a page on its own cannot be split, so
                // shrink just that page until it fits.
                let needed = currentBottom - page.top
                if needed > sliceHeight, needed > 0 {
                    page.scale = min(scale, contentHeight / needed)
                }
                // Elements were visited in top-edge order to pack them;
                // restore drawing order so overlapping ink stacks the way
                // Notes stacks it.
                page.strokeIndices.sort()
                page.imageIndices.sort()
                pages.append(page)
                current = nil
            }

            for element in elements {
                if current == nil {
                    current = Page(top: element.box.minY - padding, scale: scale)
                    currentBottom = element.box.maxY + padding
                } else if element.box.maxY + padding - current!.top > sliceHeight {
                    close()
                    current = Page(top: element.box.minY - padding, scale: scale)
                    currentBottom = element.box.maxY + padding
                } else {
                    currentBottom = max(currentBottom, element.box.maxY + padding)
                }
                switch element.kind {
                case .stroke: current!.strokeIndices.append(element.index)
                case .image:  current!.imageIndices.append(element.index)
                }
            }
            close()
            return pages
        }

        /// Fixed page-tall bands. Each element still draws exactly once, on
        /// the page its top edge falls in, so the only cost of a bad cut is
        /// that the element overhangs and gets clipped.
        static func band(_ elements: [Element], from top: Double, to bottom: Double,
                         sliceHeight: Double, scale: Double) -> [Page] {
            guard sliceHeight > 0 else { return [Page(top: top, scale: scale)] }
            let count = max(1, Int(((bottom - top) / sliceHeight).rounded(.up)))
            var pages = (0 ..< count).map { Page(top: top + Double($0) * sliceHeight, scale: scale) }
            for element in elements {
                let index = min(count - 1, max(0, Int((element.box.minY - top) / sliceHeight)))
                switch element.kind {
                case .stroke: pages[index].strokeIndices.append(element.index)
                case .image:  pages[index].imageIndices.append(element.index)
                }
            }
            return pages
        }
    }

    // MARK: Stroke geometry

    private static func boundingBox(_ points: [PaperStrokePoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points {
            let r = max(p.width, 0) / 2
            minX = min(minX, p.x - r); maxX = max(maxX, p.x + r)
            minY = min(minY, p.y - r); maxY = max(maxY, p.y + r)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Apple Pencil strokes are stored as sparse control points; Notes draws a
    /// Catmull-Rom spline through them. Resample that spline, then walk it
    /// once up each side offsetting by half the pen width, and close the loop.
    /// Filling that outline reproduces the taper exactly, in vector.
    static func addOutline(of controlPoints: [PaperStrokePoint], to context: CGContext) {
        let points = resample(controlPoints)
        guard points.count >= 2 else {
            if let p = points.first ?? controlPoints.first {
                let r = max(p.width, 0.3) / 2
                context.addEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
            }
            return
        }

        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(points.count)
        right.reserveCapacity(points.count)
        for (i, p) in points.enumerated() {
            let dx: Double, dy: Double
            if i == 0 {
                dx = points[1].x - p.x; dy = points[1].y - p.y
            } else if i == points.count - 1 {
                dx = p.x - points[i - 1].x; dy = p.y - points[i - 1].y
            } else {
                dx = points[i + 1].x - points[i - 1].x; dy = points[i + 1].y - points[i - 1].y
            }
            let length = (dx * dx + dy * dy).squareRoot()
            let nx = length > 0 ? -dy / length : 0
            let ny = length > 0 ? dx / length : 0
            let r = max(p.width, 0.25) / 2
            left.append(CGPoint(x: p.x + nx * r, y: p.y + ny * r))
            right.append(CGPoint(x: p.x - nx * r, y: p.y - ny * r))
        }

        context.move(to: left[0])
        for point in left.dropFirst() { context.addLine(to: point) }
        // Round the far end, then come back down the other side.
        if let last = points.last {
            addCap(around: last, startingAt: angle(from: last, to: left[left.count - 1]), to: context)
        }
        for point in right.reversed() { context.addLine(to: point) }
        if let start = points.first {
            addCap(around: start, startingAt: angle(from: start, to: right[0]), to: context)
        }
        context.closePath()
    }

    /// Half-circle from the side we arrived on, around the tip, to the other
    /// side -- the round end of a pen stroke.
    ///
    /// Emitted as explicit points rather than `CGContext.addArc`, whose
    /// `clockwise` flag is read relative to the current transform. This
    /// context is y-flipped to put the canvas the right way up, which inverts
    /// that flag's meaning, and getting it backwards sweeps the arc through
    /// the body of the stroke instead of past its tip: the fill then cancels
    /// along the overlap and bites a crescent out of both ends of every
    /// stroke.
    ///
    /// Sweeping by -pi always passes through the tip: the side we arrive on
    /// sits a quarter turn from the tangent, so half a turn in the direction
    /// of the tangent lands on the opposite side.
    private static func addCap(around point: PaperStrokePoint,
                               startingAt startAngle: CGFloat,
                               to context: CGContext) {
        let radius = max(point.width, 0.25) / 2
        let steps = 10
        for step in 1 ... steps {
            let angle = startAngle - .pi * CGFloat(step) / CGFloat(steps)
            context.addLine(to: CGPoint(x: point.x + cos(angle) * radius,
                                        y: point.y + sin(angle) * radius))
        }
    }

    private static func angle(from p: PaperStrokePoint, to q: CGPoint) -> CGFloat {
        atan2(q.y - p.y, q.x - p.x)
    }

    /// Catmull-Rom resampling. The step is tied to segment length so long
    /// sweeps get enough samples to stay smooth while dense scribbles do not
    /// explode the page's path count.
    private static func resample(_ input: [PaperStrokePoint]) -> [PaperStrokePoint] {
        // Duplicate control points make the tangent undefined; drop them.
        var points: [PaperStrokePoint] = []
        for p in input {
            if let last = points.last, abs(last.x - p.x) < 1e-4, abs(last.y - p.y) < 1e-4 { continue }
            points.append(p)
        }
        guard points.count >= 2 else { return points }

        var out: [PaperStrokePoint] = []
        out.reserveCapacity(points.count * 6)
        for i in 0 ..< points.count - 1 {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            let length = ((p2.x - p1.x) * (p2.x - p1.x) + (p2.y - p1.y) * (p2.y - p1.y)).squareRoot()
            let steps = max(2, min(24, Int(length / 0.7) + 2))
            for k in 0 ..< steps {
                out.append(interpolate(p0, p1, p2, p3, Double(k) / Double(steps)))
            }
        }
        out.append(points[points.count - 1])
        return out
    }

    private static func interpolate(_ p0: PaperStrokePoint, _ p1: PaperStrokePoint,
                                    _ p2: PaperStrokePoint, _ p3: PaperStrokePoint,
                                    _ t: Double) -> PaperStrokePoint {
        let t2 = t * t
        let t3 = t2 * t
        func axis(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
            0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
        }
        return PaperStrokePoint(
            x: axis(p0.x, p1.x, p2.x, p3.x),
            y: axis(p0.y, p1.y, p2.y, p3.y),
            // Width is linear between the bracketing control points: the
            // spline overshoots on sharp pressure changes and a negative
            // radius inverts the outline.
            width: p1.width + (p2.width - p1.width) * t
        )
    }

    private static func cgImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
