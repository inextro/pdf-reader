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

    /// 인용 링크면 가리키는 참고문헌 항목을 찾아 미리보기로 보여 줄 쪽과 영역(쪽 좌표). 그 밖의 링크(그림·표·식·절)는 nil.
    /// 목적지 좌표는 단 맨 아래나 쪽 머리에 찍혀 있기 일쑤라 그대로 자르면 다른 항목이 보인다.
    /// 그래서 좌표는 가까운 곳을 고르는 데만 쓰고 항목 글자를 직접 찾는다: 번호 인용은 "[n]"·"n."으로 시작하는 줄,
    /// 저자-연도 인용은 저자 성이 든 줄. 찾은 항목 첫머리에 연도가 있어야 참고문헌으로 본다.
    public static func citationPreview(for link: PDFAnnotation, on page: PDFPage) -> (page: PDFPage, rect: CGRect)? {
        guard let destination = destination(of: link), let target = destination.page else { return nil }
        let text = (page.selection(for: link.bounds)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 링크 바로 앞 글자: "Figure 3"처럼 번호에만 걸린 링크를 가리고, 연도만 걸린 저자-연도 인용의 저자를 찾는다.
        let before = page.selection(for: CGRect(x: link.bounds.minX - 150, y: link.bounds.minY,
                                                width: 149, height: link.bounds.height))?.string ?? ""
        let lastWord = before.split { !$0.isLetter && $0 != "§" }.last.map { $0.lowercased() } ?? ""
        // "(5)"처럼 괄호 안 번호는 식 번호다.
        let inParentheses = before.last { !$0.isWhitespace } == "(" || text.hasPrefix("(")
        if inParentheses || nonCitationWords.contains(lastWord) || text.split(separator: " ").first.map({ nonCitationWords.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }) == true {
            return nil
        }
        let near = point(of: destination)
        if let number = citationNumber(text) {
            // 번호는 문서에서 하나뿐이라 목적지 쪽, 다음 쪽(단 끝에 찍힌 목적지), 앞 쪽 순으로 찾는다.
            for candidate in [target] + neighbors(of: target) {
                let lines = Self.lines(of: candidate).filter { startsEntry($0.text, number: number) }
                for line in closest(lines, to: candidate === target ? near : nil) {
                    // "[n]"으로 시작하면 그것만으로 충분하다. "n."은 번호 목록일 수도 있어서 연도를 본다.
                    let bracketed = line.text.drop { $0.isWhitespace }.hasPrefix("[\(number)]")
                    if let found = entry(on: candidate, line: line, requireYear: !bracketed) { return found }
                }
            }
            return nil
        }
        guard let surname = surname(in: text, last: false) ?? surname(in: before, last: true) else { return nil }
        let year = text.range(of: #"(19|20)\d{2}"#, options: .regularExpression).map { String(text[$0]) }
        // 인용한 본문 줄도 저자 이름과 연도를 담고 있으므로 링크가 걸린 줄은 뺀다.
        let lines = Self.lines(of: target).filter {
            $0.text.prefix(60).contains(surname) && !(target === page && $0.bounds.intersects(link.bounds))
        }
        for line in closest(lines, to: near).prefix(3) {
            // "Mudigere, D., …"처럼 성으로 시작하는 줄은 항목 첫 줄이다. 이름이 앞에 오는 형식은 연도로 확인한다.
            let startsWithSurname = line.text.drop { $0.isWhitespace }.hasPrefix(surname)
            if let found = entry(on: target, line: line, requireYear: !startsWithSurname, year: year) { return found }
        }
        return nil
    }

    /// 쪽 좌표 point(항목 첫 줄 왼쪽 위)에서 아래로 몇 줄. 두 단이면 그 단 너비로, 한 단이면 본문 너비로 자른다.
    public static func previewRect(on page: PDFPage, at point: CGPoint) -> CGRect {
        let box = page.bounds(for: .cropBox)
        let top = min(point.y, box.maxY)
        let height = min(80, top - box.minY)
        // 두 단이면 쪽 가운데가 단 사이 여백이라 비어 있다. 첫 줄 길이로는 짧은 항목에서 틀려서 여백 자리를 본다.
        // 가운데 찍힌 쪽 번호·머리말에 걸리지 않게 위아래 8%는 빼고 본다.
        let margin = box.height * 0.08
        let gutter = CGRect(x: box.midX - 4, y: top - height, width: 8, height: height)
            .intersection(box.insetBy(dx: 0, dy: margin))
        let twoColumns = gutter.isNull || gutter.height < 1
            || (page.selection(for: gutter)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let left = max(point.x - 6, box.minX)
        let right: CGFloat
        if point.x > box.midX - 10 {
            right = box.maxX                                 // 오른쪽 단(한 단 본문은 쪽 오른쪽 절반에서 시작하지 않는다)
        } else if twoColumns {
            right = box.midX + 2                             // 왼쪽 단
        } else {
            right = min(box.maxX, box.maxX - (point.x - box.minX) + 6)   // 한 단: 왼쪽 여백만큼 오른쪽도 비운다
        }
        return CGRect(x: left, y: top - height, width: right - left, height: height)
    }

    /// 앞 낱말이 이것이면 번호 링크는 인용이 아니다.
    static let nonCitationWords: Set<String> = [
        "figure", "figures", "fig", "figs", "table", "tables", "tab", "section", "sections", "sec", "sect", "§",
        "eq", "eqs", "equation", "equations", "appendix", "appendices", "app", "algorithm", "alg", "line", "lines",
        "theorem", "thm", "lemma", "definition", "def", "proposition", "prop", "corollary", "remark", "example",
        "assumption", "step", "chapter", "part", "listing", "footnote",
    ]
    /// 저자 성으로 보지 않는 대문자 낱말.
    private static let notSurnames: Set<String> = ["Et", "Al", "And", "In", "See", "The", "Also", "Cf", "E", "G", "Ie", "Eg"]

    /// "12", "[12]", "12," 같은 번호 인용의 번호. 연도(네 자리)나 글자가 섞이면 nil.
    public static func citationNumber(_ text: String) -> Int? {
        guard !text.contains(where: \.isLetter) else { return nil }
        let digits = text.drop { !$0.isNumber }.prefix { $0.isNumber }
        guard (1...3).contains(digits.count) else { return nil }
        return Int(digits)
    }

    private static func surname(in text: String, last: Bool) -> String? {
        let words = text.split { !$0.isLetter && $0 != "-" }.map(String.init)
            .filter { $0.count >= 2 && $0.first!.isUppercase && !notSurnames.contains($0) && !nonCitationWords.contains($0.lowercased()) }
        return last ? words.last : words.first
    }

    /// 번호 인용 항목의 첫 줄: "[12] …", "12. …", "12 Author…".
    public static func startsEntry(_ line: String, number: Int) -> Bool {
        let t = line.drop { $0.isWhitespace }
        if t.hasPrefix("[\(number)]") { return true }
        guard t.hasPrefix("\(number)") else { return false }
        let rest = t.dropFirst("\(number)".count)
        if rest.hasPrefix(".") { return rest.dropFirst().first?.isWhitespace ?? false }
        return rest.first?.isWhitespace == true && rest.drop { $0.isWhitespace }.first?.isUppercase == true
    }

    private struct Line { let text: String; let bounds: CGRect }

    private static func lines(of page: PDFPage) -> [Line] {
        (page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []).compactMap { line in
            guard let text = line.string, !text.isEmpty else { return nil }
            return Line(text: text, bounds: line.bounds(for: page))
        }
    }

    private static func neighbors(of page: PDFPage) -> [PDFPage] {
        guard let document = page.document else { return [] }
        let index = document.index(for: page)
        return [index + 1, index - 1].filter { $0 >= 0 && $0 < document.pageCount }.compactMap { document.page(at: $0) }
    }

    /// 목적지에서 가까운 순서. 목적지보다 아래(뒤)에 있는 줄을 먼저 본다.
    private static func closest(_ lines: [Line], to point: CGPoint?) -> [Line] {
        guard let point else { return lines }
        func score(_ line: Line) -> CGFloat {
            let dy = point.y - line.bounds.maxY
            return (dy >= -6 ? dy : 1000 - dy) + abs(line.bounds.minX - point.x) * 0.5
        }
        return lines.sorted { score($0) < score($1) }
    }

    /// 항목 첫 줄에서 자른 영역. requireYear면 보이는 영역에 연도(year를 주면 그 연도)가 있어야 참고문헌 항목으로 본다.
    private static func entry(on page: PDFPage, line: Line, requireYear: Bool, year: String? = nil) -> (page: PDFPage, rect: CGRect)? {
        let rect = previewRect(on: page, at: CGPoint(x: line.bounds.minX, y: line.bounds.maxY + 1))
        guard requireYear else { return (page, rect) }
        let text = page.selection(for: rect)?.string ?? ""
        let matched = year.map { text.contains($0) } ?? (text.range(of: #"(19|20)\d{2}"#, options: .regularExpression) != nil)
        return matched ? (page, rect) : nil
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
