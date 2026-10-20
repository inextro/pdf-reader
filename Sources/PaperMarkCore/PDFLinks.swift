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

    /// 미리보기로 보여 줄 쪽과 그 쪽의 영역(쪽 좌표). omittedBefore면 앞 영역과의 사이에서 줄을 건너뛰었다(저자가 너무 많은 항목).
    public struct Region {
        public let page: PDFPage
        public let rect: CGRect
        public let omittedBefore: Bool
    }

    /// 인용 링크면 가리키는 참고문헌 항목을 찾아 미리보기로 보여 줄 영역들. 그 밖의 링크(그림·표·식·절)는 nil.
    /// 항목이 단 끝에서 끊겨 다음 단이나 다음 쪽으로 이어지면 영역이 둘이고, 위에서부터 차례로 붙여 보여 준다.
    /// 목적지 좌표는 단 맨 아래나 쪽 머리에 찍혀 있기 일쑤라 그대로 자르면 다른 항목이 보인다.
    /// 그래서 좌표는 가까운 곳을 고르는 데만 쓰고 항목 글자를 직접 찾는다: 번호 인용은 "[n]"·"n."으로 시작하는 줄,
    /// 저자-연도 인용은 저자 성이 든 줄. 찾은 항목 첫머리에 연도가 있어야 참고문헌으로 본다.
    public static func citationPreview(for link: PDFAnnotation, on page: PDFPage) -> [Region]? {
        guard let destination = destination(of: link), let target = destination.page else { return nil }
        let text = (page.selection(for: link.bounds)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 링크 바로 앞 글자: "Figure 3"처럼 번호에만 걸린 링크를 가리고, 연도만 걸린 저자-연도 인용의 저자를 찾는다.
        let before = page.selection(for: CGRect(x: link.bounds.minX - 150, y: link.bounds.minY,
                                                width: 149, height: link.bounds.height))?.string ?? ""
        // 링크 앞 글자를 글자 순서로도 읽는다. 위 좌표로 자른 글자에는 링크에 바짝 붙은 "["·"("가 빠지기도 하고,
        // 줄 맨 앞에 연도만 걸린 인용은 저자가 윗줄 끝에 있다.
        let preceding: String = {
            guard let selection = page.selection(for: link.bounds), selection.numberOfTextRanges(on: page) > 0,
                  let text = page.string as NSString? else { return "" }
            let index = selection.range(at: 0, on: page).location
            guard index != NSNotFound, index > 0 else { return "" }
            let start = max(0, index - 60)
            return text.substring(with: NSRange(location: start, length: min(index, text.length) - start))
        }()
        let opener = (preceding.last { !$0.isWhitespace } ?? before.last { !$0.isWhitespace }).map(String.init) ?? ""
        let number = citationNumber(text)
        // "[10]"처럼 대괄호 안 번호는 앞 낱말과 상관없이 인용이다("Theorem [10]", "Appendix [13]").
        let bracketed = text.hasPrefix("[") || opener == "["
        // "Figure 3", "Appendix D", "Eq. (5)"처럼 낱말 바로 뒤에 붙은 번호·글자는 그림·식·부록 참조다.
        // "Theorem (Williams, 1992)"처럼 사람 이름(대문자로 시작하고 소문자가 섞인 낱말)이 든 링크에는 따지지 않는다.
        let lastWord = before.range(of: #"[A-Za-z§]+\.?\s*\(?$"#, options: .regularExpression)
            .map { before[$0].filter { $0.isLetter || $0 == "§" }.lowercased() } ?? ""
        // "(5)"처럼 괄호 안 번호는 식 번호다. "(Li et al., 2023)"처럼 괄호까지 링크에 든 저자-연도 인용은 아니다.
        let inParentheses = number != nil && (opener == "(" || text.hasPrefix("("))
        // "A.11", "9.7.11", "D.6.4"처럼 점으로 이은 번호는 절·식·부록 번호다.
        let dotted = text.range(of: #"(\d|^[A-Z])\.\d"#, options: .regularExpression) != nil
        let firstWord = text.split(separator: " ").first.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
        let named = text.range(of: #"\p{Lu}\p{Ll}"#, options: .regularExpression) != nil
        if !bracketed && (inParentheses || dotted || !named && nonCitationWords.contains(lastWord))
            || nonCitationWords.contains(firstWord) {
            return nil
        }
        let near = point(of: destination)
        if let number {
            // 번호는 문서에서 하나뿐이라 목적지 쪽, 다음 쪽(단 끝에 찍힌 목적지), 앞 쪽 순으로 찾는다.
            for candidate in [target] + neighbors(of: target) {
                let all = Self.lines(of: candidate)
                for line in closest(all.filter { startsEntry($0.text, number: number) }, to: candidate === target ? near : nil) {
                    // "[n]"으로 시작하면 그것만으로 충분하다. "n."은 번호 목록일 수도 있어서 연도를 본다.
                    let bracketed = line.text.drop { $0.isWhitespace }.hasPrefix("[\(number)]")
                    if let found = entry(on: candidate, line: line, requireYear: !bracketed, lines: all) { return found }
                }
            }
            return nil
        }
        let parts = joinedLinks(of: link, on: page, to: destination)
        // 줄 끝 하이픈은 "Schul-"/"man"처럼 낱말을 끊은 것이면 지우고, "Sohl-"/"Dickstein"처럼 이름에 든 것이면 둔다.
        let whole = parts.map { plain(page.selection(for: $0.bounds)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            .reduce("") { joined, part in
                guard joined.hasSuffix("-") else { return joined.isEmpty ? part : joined + " " + part }
                return part.first?.isUppercase == true ? joined + part : joined.dropLast() + part
            }
        // 연도나 "et al."만 줄 맨 앞에 걸려 있으면 저자는 윗줄 끝에 있어서, 글자 순서로 앞쪽을 읽는다.
        // 부록 "J" 같은 링크에서 앞 문장의 낱말을 집지 않게, 인용의 뒷부분(연도, "et al.", "2026b"의 "b")처럼 보일 때만 본다.
        let tailOfCitation = whole.range(of: #"(19|20)\d{2}|et al|^[^A-Za-z0-9]*[a-z][^A-Za-z0-9]*$"#, options: .regularExpression) != nil
        let earlier = tailOfCitation ? preceding : ""
        guard let surname = surname(in: whole, last: false) ?? surname(in: plain(before), last: true)
                ?? surname(in: plain(earlier), last: true) ?? surname(sharing: destination, near: page) else { return nil }
        let year = whole.range(of: #"(19|20)\d{2}"#, options: .regularExpression).map { String(whole[$0]) }
        // 인용한 본문 줄도 저자 이름과 연도를 담고 있으므로 링크(나뉜 조각까지)가 걸린 줄은 뺀다.
        let all = Self.lines(of: target)
        // 줄 끝 하이픈을 살린 "Type-Safe"가 참고문헌에는 "TypeSafe"로 적혀 있기도 하다.
        let names = surname.contains("-") ? [surname, surname.replacingOccurrences(of: "-", with: "")] : [surname]
        // 쪽 머리말 자리(위 6%)의 줄은 참고문헌 항목이 아니다.
        let header = target.bounds(for: .cropBox).maxY - target.bounds(for: .cropBox).height * 0.06
        let lines = all.filter { line in
            guard line.bounds.minY < header else { return false }
            let head = plain(line.text).prefix(60)
            return names.contains { head.contains($0) } && !(target === page && parts.contains { $0.bounds.intersects(line.bounds) })
        }
        for line in closest(lines, to: near).prefix(3) {
            // "Mudigere, D., …"처럼 성으로 시작하는 줄은 항목 첫 줄이다. 목적지 바로 아래 줄도 그렇다(연도 없는 항목도 있다).
            // 다만 "2.3 Closing Remarks" 같은 목차 링크나 "DDIM" 같은 약어는 제목 줄을 가리키므로 뺀다.
            // 이름이 앞에 오는 형식은 연도로 확인한다.
            let startsWithSurname = names.contains { plain(line.text).drop { $0.isWhitespace }.hasPrefix($0) }
            let atDestination = (0...12).contains(near.y - line.bounds.maxY) && surname.contains(where: \.isLowercase)
                && whole.range(of: #"^([A-Z]\.)?\d"#, options: .regularExpression) == nil
            if let found = entry(on: target, line: line, requireYear: !startsWithSurname && !atDestination, year: year, lines: all) {
                return found
            }
        }
        return nil
    }

    /// 같은 곳을 가리키는 다른 링크에 든 저자 성. 인용이 단이나 쪽을 넘어 나뉘면 "(Liu" / "et al., 2023b)"의
    /// 뒤쪽에는 저자가 없는데, 목적지가 같으면 같은 참고문헌이라 이 쪽이나 앞 쪽의 다른 링크에서 가져와도 된다.
    private static func surname(sharing destination: PDFDestination, near page: PDFPage) -> String? {
        let pages = [page] + (page.document.flatMap { document in
            let index = document.index(for: page)
            return index > 0 ? document.page(at: index - 1) : nil
        }.map { [$0] } ?? [])
        for candidate in pages {
            for other in candidate.annotations {
                // 인용처럼 생긴 짧은 링크만 본다(쪽 머리말에 걸친 링크의 "Published as …"를 성으로 집지 않게).
                guard let d = Self.destination(of: other), d.page === destination.page, d.point == destination.point,
                      let text = candidate.selection(for: other.bounds)?.string, text.count <= 40,
                      text.range(of: #"(19|20)\d{2}|et al|&"#, options: .regularExpression) != nil,
                      let name = surname(in: plain(text), last: false) else { continue }
                return name
            }
        }
        return nil
    }

    /// 링크와, 같은 곳을 가리키는 바로 위아래 줄의 링크들(읽는 순서).
    /// 인용이 줄을 넘으면 링크가 "Schul-" / "man et al., 2017", "Anil et al.," / "2023"처럼 나뉘어 한쪽에는 저자나 연도가 없다.
    private static func joinedLinks(of link: PDFAnnotation, on page: PDFPage, to destination: PDFDestination) -> [PDFAnnotation] {
        let band = link.bounds.insetBy(dx: -page.bounds(for: .cropBox).width, dy: -link.bounds.height * 1.5)
        return ([link] + page.annotations.filter { other in
            guard other !== link, other.bounds.intersects(band), let d = Self.destination(of: other) else { return false }
            return d.page === destination.page && d.point == destination.point
        })
        .sorted { abs($0.bounds.midY - $1.bounds.midY) > 2 ? $0.bounds.midY > $1.bounds.midY : $0.bounds.minX < $1.bounds.minX }
    }

    /// 쪽 좌표 point(항목 첫 줄 왼쪽 위)에서 아래로 height만큼. 두 단이면 그 단 너비로, 한 단이면 본문 너비로 자른다.
    public static func previewRect(on page: PDFPage, at point: CGPoint, height: CGFloat = 80) -> CGRect {
        let box = page.bounds(for: .cropBox)
        let top = min(point.y, box.maxY)
        let height = min(height, top - box.minY)
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
        let words = text.split { !$0.isLetter && $0 != "-" }
            // 글자 사이 공백이 사라진 PDF는 "Ouyangetal"처럼 et al.이 성에 붙는다.
            .map { $0.count > 6 && $0.hasSuffix("etal") ? String($0.dropLast(4)) : String($0) }
            .filter { $0.count >= 2 && $0.first!.isUppercase && !notSurnames.contains($0) && !nonCitationWords.contains($0.lowercased()) }
        return last ? words.last : words.first
    }

    /// 발음 기호를 뗀 글자. "H¨ubotter"처럼 기호가 따로 떨어져 나오거나 "Hübotter"로 붙어 나오는 것을 같게 본다.
    private static func plain(_ text: String) -> String {
        text.folding(options: .diacriticInsensitive, locale: nil).filter { !"¨´`ˆ˜¸˚".contains($0) }
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

    private struct Line {
        let text: String, bounds: CGRect, selection: PDFSelection
        /// 첫 글자의 크기. 줄 상자 높이는 글자보다 훨씬 낮게 잡히기도 한다(ACM 참고문헌은 7pt 글자에 3pt).
        var fontSize: CGFloat {
            (selection.attributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
        }
    }

    private static func lines(of page: PDFPage) -> [Line] {
        (page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []).compactMap { line in
            guard let text = line.string, !text.isEmpty else { return nil }
            return Line(text: text, bounds: line.bounds(for: page), selection: line)
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

    /// 미리보기 높이의 한도(10pt 글자로 14줄쯤). 보통 항목은 대부분 이 안에 든다(90%가 55pt 이하).
    /// 이보다 길면 저자가 아주 많은 항목이라 앞 headRows줄과 끝 tailRows줄(제목·학회·연도)만 보여 주고 가운데는 건너뛴다.
    static let maxPreviewHeight: CGFloat = 160, headRows = 3, tailRows = 5

    /// 항목 하나만 담은 영역들. 항목 끝을 모르면(lines에서 첫 줄을 못 찾으면) 첫 줄부터 몇 줄을 자른다.
    /// requireYear면 항목 글자에 연도(year를 주면 그 연도)가 있어야 참고문헌 항목으로 본다.
    private static func entry(on page: PDFPage, line: Line, requireYear: Bool, year: String? = nil,
                              lines: [Line] = []) -> [Region]? {
        let top = line.bounds.maxY + 1
        let column = previewRect(on: page, at: CGPoint(x: line.bounds.minX, y: top))
        // 번호를 오른쪽에 맞춰 찍으면 "[10]"이 "[9]"보다 왼쪽에서 시작하니 조금 넉넉히 잡는다.
        let rows = inColumn(lines, on: page, from: line.bounds.minX - max(4, line.fontSize * 1.5), to: column.maxX)
        let found = continuation(of: line, in: rows)
        // 단 끝까지 이어졌으면 다음 단 위쪽에 남은 부분이 있을 수 있다. 줄이 모두 같은 자리에서 시작하는 형식은
        // 다음 단 첫 줄이 이어지는 줄인지 새 항목인지 알 수 없어서 내어쓰기 형식만 본다.
        let spilled = found.reachedEnd && found.hanging != 0
            ? spill(after: page, column: column, first: line, hanging: found.hanging, lines: lines) : nil
        if requireYear {
            let text = ([line] + found.lines + (spilled?.lines ?? [])).map(\.text).joined(separator: " ")
            let matched = year.map { text.contains($0) } ?? (text.range(of: #"(19|20)\d{2}"#, options: .regularExpression) != nil)
            guard matched else { return nil }
        }
        guard rows.contains(where: { $0.bounds == line.bounds }) else { return [Region(page: page, rect: column, omittedBefore: false)] }
        // 항목을 이루는 줄들을 쪽마다. 다음 단으로 이어졌으면 둘이다.
        var parts = [(page: page, x: line.bounds.minX, rows: rowBounds([line] + found.lines))]
        if let spilled { parts.append((spilled.page, spilled.edge, rowBounds(spilled.lines))) }
        let flat = parts.indices.flatMap { part in parts[part].rows.indices.map { (part: part, row: $0) } }
        let height = parts.map { $0.rows.first!.maxY - $0.rows.last!.minY + 3 }.reduce(0, +)
        // 보여 줄 줄 묶음(쪽 하나 안에서 이어진 줄들)과, 그 앞에서 줄을 건너뛰었는지.
        var pieces: [(part: Int, rows: Range<Int>, omitted: Bool)] = []
        let shown = height <= maxPreviewHeight || flat.count <= headRows + tailRows
            ? [(flat[...], false)]
            : [(flat.prefix(headRows), false), (flat.suffix(tailRows), true)]
        for (slice, omitted) in shown {
            for (n, part) in Set(slice.map(\.part)).sorted().enumerated() {
                let indices = slice.filter { $0.part == part }.map(\.row)
                pieces.append((part, indices.min()!..<indices.max()! + 1, omitted && n == 0))
            }
        }
        return pieces.map { piece in
            let (page, x, all) = parts[piece.part]
            let rows = all[piece.rows]
            let top = rows.first!.maxY + 1
            var bottom = rows.last!.minY - 2
            // 줄 상자가 아래 줄과 살짝 겹치기도 해서, 다음 항목 첫 줄의 위쪽은 넘지 않는다.
            if spilled == nil, piece.rows.upperBound == all.count, let next = found.below?.bounds.maxY,
               next > bottom, next < rows.last!.minY + 1 {
                bottom = next - 0.5
            }
            return Region(page: page, rect: previewRect(on: page, at: CGPoint(x: x, y: top), height: top - bottom),
                          omittedBefore: piece.omitted)
        }
    }

    /// 같은 높이의 조각을 한 줄로 묶은 줄 상자들(위에서 아래로).
    private static func rowBounds(_ lines: [Line]) -> [CGRect] {
        var rows: [CGRect] = []
        for line in lines {
            if let last = rows.last, line.bounds.midY > last.minY, line.bounds.midY < last.maxY {
                rows[rows.count - 1] = last.union(line.bounds)
            } else {
                rows.append(line.bounds)
            }
        }
        return rows
    }

    /// 쪽의 한 단(가로 left..<right에서 시작하는 줄)을 화면 순서로: 위에서 아래로, 같은 높이의 조각은 왼쪽부터.
    /// PDF에 든 글자 순서는 화면 순서와 다르기도 하다(번호 "[74]"들만 따로 모여 있거나 두 단이 높이 순으로 섞인다).
    /// 쪽 머리(위 6%)와 쪽 번호는 뺀다.
    private static func inColumn(_ lines: [Line], on page: PDFPage, from left: CGFloat, to right: CGFloat) -> [Line] {
        let box = page.bounds(for: .cropBox)
        let kept = lines.filter { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return line.bounds.minX >= left && line.bounds.minX < right - 10 && line.bounds.maxY < box.maxY - box.height * 0.06
                && !(text.count <= 4 && text.allSatisfy(\.isNumber))
        }
        .sorted { $0.bounds.midY > $1.bounds.midY }
        var rows: [[Line]] = []
        for line in kept {
            if let first = rows.last?.first, first.bounds.midY - line.bounds.midY < 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
    }

    /// 항목 첫 줄 다음에 같은 항목으로 이어지는 줄들(inColumn 순서).
    /// 내어쓰기 형식이면 첫 줄 자리로 돌아온 줄에서 끝난다. 모든 줄이 같은 자리에서 시작하는 형식이면
    /// 번호로 시작하는 줄이나 줄 사이가 더 벌어진 곳에서 끝나고, 항목 경계를 알 수 없으니 몇 줄까지만 본다.
    /// 어느 형식이든 줄 사이가 한 줄 넘게 벌어지면(제목 아래 본문) 같은 항목이 아니다.
    /// 한 줄이 "[65] " / "Xiang Wang, …"처럼 여러 조각으로 나뉘어 오기도 하고, 조각 높이가 글자보다 낮게 잡히기도 한다.
    /// below는 항목 다음에 오는 줄, reachedEnd는 단 끝까지 이어졌는지, hanging은 내어쓴 폭(내어쓰기 형식이 아니면 0, 한 줄뿐이면 nil).
    private static func continuation(of first: Line, in lines: [Line]) -> (lines: [Line], below: Line?, reachedEnd: Bool, hanging: CGFloat?) {
        guard let start = lines.firstIndex(where: { $0.bounds == first.bounds }) else { return ([], nil, false, nil) }
        var result: [Line] = [], row = first.bounds, rows = 1
        var hanging: CGFloat?, firstGap: CGFloat?
        for next in lines[(start + 1)...] {
            if sameRow(next, row) {
                result.append(next)
                row = row.union(next.bounds)
                continue
            }
            let indent = next.bounds.minX - first.bounds.minX, gap = row.minY - next.bounds.maxY
            guard rows < 80, continues(next, after: row), !startsLabeledEntry(next) else { return (result, next, false, hanging) }
            let indented = indent > 2 && indent < 40, flush = abs(indent) <= 2
            if hanging == nil {
                guard indented || flush else { return (result, next, false, hanging) }
                hanging = indented ? indent : 0
            }
            if hanging != 0 {
                guard indented else { return (result, next, false, hanging) }
            } else {
                guard flush, rows < 5, gap < (firstGap ?? gap) + 1.5,
                      next.text.range(of: #"^\s*(\[\d{1,3}\]|\d{1,3}\.\s)"#, options: .regularExpression) == nil
                else { return (result, next, false, hanging) }
            }
            firstGap = firstGap ?? gap
            result.append(next)
            row = next.bounds
            rows += 1
        }
        return (result, nil, true, hanging)
    }

    /// 단 끝에서 끊긴 항목이 이어지는 다음 단(같은 쪽 오른쪽 단, 또는 다음 쪽 첫 단) 맨 위의 내어쓴 줄들.
    /// edge는 그 단에서 항목이 시작하는 자리. 이어지는 줄은 그보다 안쪽에서 시작하고 글자 크기가 같다.
    /// 마지막 항목처럼 단에 이어지는 줄만 있으면 그 단만 보고는 edge를 모르니, 지금 쪽의 단 배치로 어림한다.
    /// hanging은 앞 단에서 본 내어쓴 폭으로, 알면 이어지는 줄도 그만큼 들여 쓰여 있어야 한다.
    private static func spill(after page: PDFPage, column: CGRect, first: Line, hanging: CGFloat?,
                              lines: [Line]) -> (page: PDFPage, lines: [Line], edge: CGFloat)? {
        let box = page.bounds(for: .cropBox)
        let next: PDFPage, left: CGFloat, right: CGFloat, expected: CGFloat
        if column.maxX < box.midX + 10 {
            // 왼쪽 단 → 같은 쪽 오른쪽 단. 두 단의 좌우 여백은 대칭이다.
            let columnRight = lines.filter { $0.bounds.minX < box.midX - 10 && $0.bounds.maxX < box.midX + 10 }.map(\.bounds.maxX).max()
            (next, left, right) = (page, box.midX - 4, box.maxX)
            expected = box.minX + box.maxX - (columnRight ?? box.midX)
        } else if let document = page.document, document.index(for: page) + 1 < document.pageCount,
                  let following = document.page(at: document.index(for: page) + 1) {
            // 오른쪽 단에서 끊겼으면 다음 쪽도 두 단이고, 첫 단은 지금 쪽 왼쪽 단과 같은 자리에서 시작한다.
            let twoColumns = column.minX > box.midX - 20
            (next, left, right) = (following, box.minX, twoColumns ? box.midX + 2 : box.maxX)
            expected = twoColumns ? lines.filter { $0.bounds.minX < box.midX - 10 }.map(\.bounds.minX).min() ?? box.minX : first.bounds.minX
        } else {
            return nil
        }
        let fontSize = first.fontSize
        var rows = inColumn(Self.lines(of: next), on: next, from: left, to: right)
        guard let found = rows.map(\.bounds.minX).min() else { return nil }
        // 단에 내어쓴 줄과 바깥 줄이 섞여 있으면 바깥 줄이 항목 첫 줄이다. 모두 같은 자리면 이어지는 줄뿐일 수 있어서 어림값을 쓴다.
        let edge = rows.contains { $0.bounds.minX > found + 2 && $0.bounds.minX < found + 40 } ? found : min(found, expected)
        // 단 맨 위의 쪽 머리말("KDD ’24, August 25–29, 2024", 저자 약칭, 논문 제목)은 건너뛴다.
        // 쪽 위쪽에서 멀리 들여 쓰였거나 아래 줄과 떨어져 있다. 아래 줄과 떨어져 있어도 단 왼쪽 끝에서 시작하고
        // 글자가 더 크면 "NeurIPS Paper Checklist" 같은 절 제목이라 건너뛰지 않고, 아래 반복문에서 멈춘다.
        let headerZone = next.bounds(for: .cropBox).maxY - next.bounds(for: .cropBox).height * 0.12
        while let top = rows.first, top.bounds.minY > headerZone {
            var row = top.bounds, count = 1
            while count < rows.count, sameRow(rows[count], row) { row = row.union(rows[count].bounds); count += 1 }
            let isolated = count == rows.count || !continues(rows[count], after: row)
            let indent = top.bounds.minX - edge
            guard indent >= 40 || isolated && (indent > 2 || abs(top.fontSize - first.fontSize) < 1) else { break }
            rows.removeFirst(count)
        }
        var result: [Line] = [], row: CGRect?
        for line in rows {
            if let current = row, sameRow(line, current) {
                result.append(line)
                row = current.union(line.bounds)
                continue
            }
            // 단 첫 줄이 항목 첫 줄(edge에서 시작하거나 "[n]")이면 이어지는 부분이 없다.
            let indent = line.bounds.minX - edge
            // 번호를 오른쪽에 맞춰 찍으면 "[1]" 항목의 내어쓴 폭이 "[10]" 항목보다 숫자 하나만큼 좁다.
            guard result.count < 80, indent > 2, indent < 40, hanging.map({ abs(indent - $0) < max(3, fontSize * 0.7) }) ?? true,
                  abs(line.fontSize - fontSize) < 1, !startsLabeledEntry(line),
                  row.map({ continues(line, after: $0) }) ?? true else { break }
            result.append(line)
            row = line.bounds
        }
        return result.isEmpty ? nil : (next, result, edge)
    }

    /// "[12] …"으로 시작하는 줄. 번호를 오른쪽에 맞춰 찍으면 "[7]"이 "[10]"보다 안쪽에서 시작해 내어쓴 줄처럼 보인다.
    private static func startsLabeledEntry(_ line: Line) -> Bool {
        line.text.range(of: #"^\s*\[\d{1,3}\]"#, options: .regularExpression) != nil
    }

    /// row와 같은 줄의 오른쪽 조각인지. inColumn으로 한 단만 골라 두었으니 높이만 본다(양쪽 맞춤이면 조각 사이가 넓다).
    private static func sameRow(_ line: Line, _ row: CGRect) -> Bool {
        line.bounds.midY > row.minY && line.bounds.midY < row.maxY && line.bounds.minX >= row.maxX - 2
    }

    /// row 바로 다음 줄인지: 아래에 있고, 사이가 한 줄 넘게 벌어지지 않았다.
    private static func continues(_ line: Line, after row: CGRect) -> Bool {
        let gap = row.minY - line.bounds.maxY
        return gap > -2 && gap < max(max(row.height, line.bounds.height) * 0.8, line.fontSize)
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
