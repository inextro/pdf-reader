import PDFKit

/// 페이지에 붙은(또는 붙일) 형광펜 주석 하나.
public struct PlacedHighlight {
    public let page: PDFPage
    public let annotation: PDFAnnotation

    public init(page: PDFPage, annotation: PDFAnnotation) {
        self.page = page
        self.annotation = annotation
    }
}

public enum Highlights {
    public static func isHighlight(_ annotation: PDFAnnotation) -> Bool {
        (annotation.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Highlight"
    }

    /// 선택 영역을 페이지마다 표준 /Highlight 주석 하나로 만든다.
    /// 줄마다 QuadPoints 사각형 하나를 넣어 PDF Expert 등 다른 리더에서도 한 덩어리로 보이게 한다.
    public static func make(from selection: PDFSelection, color: NSColor, author: String? = nil) -> [PlacedHighlight] {
        var pages: [PDFPage] = []
        var rectsByPage: [ObjectIdentifier: [CGRect]] = [:]
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let r = line.bounds(for: page)
                guard r.width > 0.5, r.height > 0.5 else { continue }
                let key = ObjectIdentifier(page)
                if rectsByPage[key] == nil { pages.append(page) }
                rectsByPage[key, default: []].append(r)
            }
        }
        return pages.map { page in
            let rects = rectsByPage[ObjectIdentifier(page)]!
            let bounds = rects.dropFirst().reduce(rects[0]) { $0.union($1) }
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = color
            // PDFKit의 quadrilateralPoints는 주석 bounds 원점 기준 좌표다.
            annotation.quadrilateralPoints = rects.flatMap { r -> [NSValue] in
                [NSPoint(x: r.minX, y: r.maxY), NSPoint(x: r.maxX, y: r.maxY),
                 NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY)]
                    .map { NSValue(point: NSPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)) }
            }
            if let author { annotation.userName = author }
            annotation.modificationDate = Date()
            return PlacedHighlight(page: page, annotation: annotation)
        }
    }

    /// 주석이 실제로 칠한 사각형들(페이지 좌표). QuadPoints가 없으면 bounds 하나.
    public static func rects(of annotation: PDFAnnotation) -> [CGRect] {
        let origin = annotation.bounds.origin
        let points = (annotation.quadrilateralPoints ?? []).map { $0.pointValue }
        guard points.count >= 4, points.count % 4 == 0 else { return [annotation.bounds] }
        return stride(from: 0, to: points.count, by: 4).map { i in
            let quad = points[i..<i + 4]
            let xs = quad.map(\.x), ys = quad.map(\.y)
            return CGRect(x: xs.min()! + origin.x, y: ys.min()! + origin.y,
                          width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    public static func hit(_ annotation: PDFAnnotation, at point: CGPoint) -> Bool {
        rects(of: annotation).contains { $0.insetBy(dx: -1, dy: -1).contains(point) }
    }

    /// 페이지 좌표의 점 위에 있는 형광펜 중 가장 위(나중에 붙은) 것.
    public static func highlight(on page: PDFPage, at point: CGPoint) -> PDFAnnotation? {
        page.annotations.last { isHighlight($0) && hit($0, at: point) }
    }
}
