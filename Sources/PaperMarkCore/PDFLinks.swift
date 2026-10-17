import PDFKit

/// 문서 안을 가리키는 링크(인용 번호, 그림·식 참조)와 목차 항목의 목적지.
public enum PDFLinks {
    /// 문서 안 다른 곳으로 가는 링크면 그 목적지. 웹 주소 링크는 nil.
    public static func destination(of annotation: PDFAnnotation) -> PDFDestination? {
        guard annotation.type == "Link" else { return nil }
        return valid(annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination)
    }

    public static func destination(of item: PDFOutline) -> PDFDestination? {
        valid(item.destination ?? (item.action as? PDFActionGoTo)?.destination)
    }

    private static func valid(_ destination: PDFDestination?) -> PDFDestination? {
        destination?.page == nil ? nil : destination
    }

    /// 목적지 좌표. 정하지 않은 값(kPDFDestinationUnspecifiedValue)은 쪽 왼쪽 위로 본다.
    public static func point(of destination: PDFDestination) -> CGPoint {
        let box = destination.page?.bounds(for: .cropBox) ?? .zero
        let p = destination.point
        let unspecified = CGFloat(kPDFDestinationUnspecifiedValue)
        return CGPoint(x: p.x >= unspecified ? box.minX : min(max(p.x, box.minX), box.maxX),
                       y: p.y >= unspecified ? box.maxY : min(max(p.y, box.minY), box.maxY))
    }

    /// 미리보기로 보여 줄 목적지 주변(쪽 좌표). 목적지 바로 아래에 글자가 있으면(참고문헌 항목, 절 제목, 식)
    /// 그 단의 너비로 몇 줄만, 없으면(그림) 쪽 너비로 크게 자른다.
    public static func previewRect(for destination: PDFDestination) -> CGRect? {
        guard let page = destination.page else { return nil }
        let box = page.bounds(for: .cropBox)
        let point = point(of: destination)
        let top = point.y
        let probe = CGRect(x: point.x, y: point.y - 24, width: min(40, box.maxX - point.x), height: 24)
        guard let found = page.selection(for: probe), !(found.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            let height = min(box.height * 0.45, top - box.minY)
            return CGRect(x: box.minX, y: top - height, width: box.width, height: height)
        }
        let height = min(80, top - box.minY)
        // 두 단이면 쪽 가운데가 단 사이 여백이라 비어 있다. 첫 줄 길이로는 짧은 항목에서 틀려서 여백 자리를 본다.
        let gutter = CGRect(x: box.midX - 4, y: top - height, width: 8, height: height)
        let twoColumns = (page.selection(for: gutter)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let left = max(point.x - 6, box.minX)
        let right: CGFloat
        if twoColumns, point.x > box.midX - 10 {
            right = box.maxX                                 // 오른쪽 단
        } else if twoColumns {
            right = box.midX + 2                             // 왼쪽 단
        } else {
            right = min(box.maxX, box.maxX - (point.x - box.minX) + 6)   // 한 단: 왼쪽 여백만큼 오른쪽도 비운다
        }
        return CGRect(x: left, y: top - height, width: right - left, height: height)
    }
}

/// 목차에서 지금 읽는 곳의 항목을 찾는다.
public enum PDFContents {
    /// 쪽 번호와 쪽 안의 높이(PDF 좌표라 위로 갈수록 크다).
    public struct Position: Equatable {
        public let page: Int
        public let y: CGFloat
        public init(page: Int, y: CGFloat) { self.page = page; self.y = y }
    }

    /// 목차 순서대로 놓인 항목 위치 중 at을 지난(앞 쪽에 있거나 같은 쪽에서 at보다 위에 있는) 마지막 항목.
    /// 두 단 논문은 오른쪽 단 위의 절이 왼쪽 단 아래 절보다 높아서 순서를 따지지 않고 목차 순서의 마지막을 고른다.
    public static func current(in positions: [Position], at: Position) -> Int? {
        positions.lastIndex { $0.page < at.page || ($0.page == at.page && $0.y >= at.y) }
    }
}
