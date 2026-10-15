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
            PlacedHighlight(page: page, annotation: annotation(rects: rectsByPage[ObjectIdentifier(page)]!,
                                                                color: color, author: author))
        }
    }

    /// 줄 사각형들(페이지 좌표)로 /Highlight 주석 하나를 만든다.
    static func annotation(rects: [CGRect], color: NSColor, author: String?) -> PDFAnnotation {
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
        return annotation
    }

    /// 새 형광펜을 이미 있는 형광펜과 합친다. 겹치거나 같은 줄에서 맞닿는 기존 형광펜은
    /// 지우고, 새 형광펜과 합친 주석 하나(새 색)로 바꾼다. 그래서 겹친 곳도 한 겹으로 칠해진다.
    public static func merge(_ new: [PlacedHighlight], color: NSColor, author: String? = nil)
        -> (added: [PlacedHighlight], removed: [PlacedHighlight]) {
        var added: [PlacedHighlight] = [], removed: [PlacedHighlight] = []
        for h in new {
            var area = rects(of: h.annotation)
            var others = h.page.annotations.filter(isHighlight)
            var absorbed: [PDFAnnotation] = []
            // 합친 영역이 커지면 다른 형광펜과 새로 닿을 수 있어 더 없을 때까지 반복한다.
            while let i = others.firstIndex(where: { other in
                rects(of: other).contains { o in area.contains { touches(o, $0) } }
            }) {
                let other = others.remove(at: i)
                absorbed.append(other)
                area += rects(of: other)
            }
            guard !absorbed.isEmpty else { added.append(h); continue }
            let merged = annotation(rects: joinLines(area), color: color, author: author)
            let notes = absorbed.compactMap(\.contents).filter { !$0.isEmpty }
            if !notes.isEmpty { merged.contents = notes.joined(separator: "\n") }
            removed += absorbed.map { PlacedHighlight(page: h.page, annotation: $0) }
            added.append(PlacedHighlight(page: h.page, annotation: merged))
        }
        return (added, removed)
    }

    /// 같은 줄(세로로 절반 이상 겹침)에 있고 가로로 겹치거나 1pt 안으로 붙어 있으면 맞닿은 것으로 본다.
    static func touches(_ a: CGRect, _ b: CGRect) -> Bool {
        let vertical = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        guard vertical >= 0.5 * min(a.height, b.height) else { return false }
        return a.minX <= b.maxX + 1 && b.minX <= a.maxX + 1
    }

    /// 맞닿은 사각형을 줄마다 하나로 합치고 위에서 아래, 왼쪽에서 오른쪽 순서로 정렬한다.
    static func joinLines(_ rects: [CGRect]) -> [CGRect] {
        var lines: [CGRect] = []
        for r in rects {
            var current = r
            while let i = lines.firstIndex(where: { touches($0, current) }) {
                current = current.union(lines.remove(at: i))
            }
            lines.append(current)
        }
        return lines.sorted { abs($0.midY - $1.midY) > 1 ? $0.midY > $1.midY : $0.minX < $1.minX }
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

/// 형광펜 말고도 PDF Expert 등에서 만든 사용자 주석(밑줄, 취소선, 펜, 메모, 도형 등)을 다룬다.
public enum Markups {
    /// 줄 단위 QuadPoints로 칠하는 텍스트 주석.
    static let textMarkupTypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "Squiggly"]
    /// 사용자가 만든 주석이 아닌 것(링크, 폼 필드, 메모의 팝업 창).
    static let systemTypes: Set<String> = ["Link", "Widget", "Popup"]

    public static func type(of annotation: PDFAnnotation) -> String {
        (annotation.type ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func isUserMarkup(_ annotation: PDFAnnotation) -> Bool {
        !systemTypes.contains(type(of: annotation))
    }

    /// 색을 바꿀 수 있는 주석. 텍스트 상자는 /C가 배경색이라 제외한다.
    public static func isRecolorable(_ annotation: PDFAnnotation) -> Bool {
        isUserMarkup(annotation) && !["FreeText", "Stamp"].contains(type(of: annotation))
    }

    /// 우클릭 메뉴에 쓸 이름.
    public static func displayName(of annotation: PDFAnnotation) -> String {
        switch type(of: annotation) {
        case "Highlight": "Highlight"
        case "Underline": "Underline"
        case "StrikeOut": "Strikethrough"
        case "Squiggly": "Squiggly Underline"
        case "Ink": "Drawing"
        case "Text": "Note"
        case "FreeText": "Text Box"
        case "Square", "Circle", "Line", "Polygon", "PolyLine": "Shape"
        default: "Annotation"
        }
    }

    /// 점이 주석 위에 있는지(페이지 좌표). 텍스트 주석은 줄 사각형, 펜은 실제 선 근처, 나머지는 bounds.
    public static func hit(_ annotation: PDFAnnotation, at point: CGPoint) -> Bool {
        let kind = type(of: annotation)
        if textMarkupTypes.contains(kind) { return Highlights.hit(annotation, at: point) }
        if kind == "Ink", let paths = annotation.paths, !paths.isEmpty {
            // 펜 경로는 주석 bounds 원점 기준 좌표다. 선 두께에 여유를 더해 판정한다.
            let local = CGPoint(x: point.x - annotation.bounds.minX, y: point.y - annotation.bounds.minY)
            let width = max(annotation.border?.lineWidth ?? 1, 1) + 6
            return paths.contains {
                $0.cgPath.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
                    .contains(local)
            }
        }
        return annotation.bounds.insetBy(dx: -1, dy: -1).contains(point)
    }

    /// 점 위에 있는 사용자 주석 중 가장 위(나중에 붙은) 것.
    public static func markup(on page: PDFPage, at point: CGPoint) -> PDFAnnotation? {
        page.annotations.last { isUserMarkup($0) && hit($0, at: point) }
    }

    /// 지울 때 함께 지울 주석들: 주석 자신과, 같은 페이지에 붙은 메모 팝업 창.
    public static func removalSet(for annotation: PDFAnnotation, on page: PDFPage) -> [PlacedHighlight] {
        var result = [PlacedHighlight(page: page, annotation: annotation)]
        if let popup = annotation.popup, page.annotations.contains(where: { $0 === popup }) {
            result.append(PlacedHighlight(page: page, annotation: popup))
        }
        return result
    }
}
