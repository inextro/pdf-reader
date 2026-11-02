import PDFKit

/// 번역할 글에서 수식을 골라낸다. PDF에서 뽑은 수식 글자는 아래첨자가 본문 글자에 붙고 기호가 깨져서
/// (p_θ(x_{t-1}) → "p✓(xt 1"), 수식 자리는 자리표(X1, X2…)로 바꿔 번역하고 그 자리에 PDF에서 잘라 낸 그림을 넣는다.
/// PDFKit은 글꼴 이름을 알려 주지 않으므로 글자와 낱말 모양으로 판단한다.
/// 본문 낱말을 수식으로 잘못 봐도 원래 모습 그대로 그려질 뿐이라 넉넉하게 잡는다.
public enum PDFMath {
    public struct Span {
        public let page: PDFPage
        /// 페이지 좌표. 줄마다 하나이고, 여러 줄을 차지하는 별행 수식은 한 장으로 합친다.
        public let rects: [CGRect]
        /// PDF에서 뽑은 원래 글자(복사용)
        public let text: String
    }

    public enum Piece: Equatable {
        case text(String)
        case math(Int)
    }

    public struct Split {
        /// 수식 자리에 자리표가 들어간 글
        public let text: String
        public let spans: [Span]
        /// 자리표 머리글자. 원문에 이미 "X1" 같은 낱말이 있으면 다른 글자를 쓴다.
        public let marker: String
        /// 이 페이지 본문 한 줄의 높이(페이지 좌표). 수식 그림 크기를 번역문 글자에 맞출 때 쓴다.
        public let lineHeight: CGFloat

        /// 자리표를 원래 글자로 되돌린 글
        public var plain: String {
            pieces(of: text).map { piece in
                switch piece {
                case .text(let s): return s
                case .math(let i): return spans[i].text
                }
            }.joined()
        }

        /// 번역문을 글 조각과 수식 번호로 나눈다. 번역기가 "X 1"처럼 띄어 쓴 자리표도 알아본다.
        public func pieces(of translated: String) -> [Piece] {
            guard !spans.isEmpty,
                  let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\d])\(marker) ?(\\d+)(?!\\d)")
            else { return [.text(translated)] }
            let ns = translated as NSString
            var pieces: [Piece] = []
            var last = 0
            for match in regex.matches(in: translated, range: NSRange(location: 0, length: ns.length)) {
                guard let n = Int(ns.substring(with: match.range(at: 1))), (1...spans.count).contains(n) else { continue }
                if match.range.location > last {
                    pieces.append(.text(ns.substring(with: NSRange(location: last, length: match.range.location - last))))
                }
                pieces.append(.math(n - 1))
                last = NSMaxRange(match.range)
            }
            if last < ns.length { pieces.append(.text(ns.substring(from: last))) }
            return pieces
        }
    }

    public static func split(_ selection: PDFSelection) -> Split {
        // 글자 하나(UTF-16 단위)와 그 위치. 줄 사이에는 index가 nil인 줄바꿈을 넣는다.
        struct Unit {
            let page: PDFPage
            let index: Int?
            let code: unichar
            let line: Int
        }
        var units: [Unit] = []
        let lines = selection.selectionsByLine()
        for (lineNo, line) in lines.enumerated() {
            for page in line.pages {
                guard let string = page.string as NSString? else { continue }
                for r in 0..<line.numberOfTextRanges(on: page) {
                    let range = line.range(at: r, on: page)
                    for i in range.location..<min(NSMaxRange(range), string.length) {
                        units.append(Unit(page: page, index: i, code: string.character(at: i), line: lineNo))
                    }
                }
                if let last = units.last { units.append(Unit(page: last.page, index: nil, code: 0x0A, line: lineNo)) }
            }
        }
        guard let firstPage = selection.pages.first, !units.isEmpty else {
            return Split(text: PDFText.cleaned(selection.string ?? ""), spans: [], marker: "X", lineHeight: 12)
        }

        // 낱말(공백 사이 글자 묶음)로 나누고 수식인지 본다.
        func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0xA0 }
        var tokens: [Range<Int>] = []
        var start: Int?
        for (i, unit) in units.enumerated() {
            if isSpace(unit.code) {
                if let s = start { tokens.append(s..<i); start = nil }
            } else if start == nil {
                start = i
            }
        }
        if let s = start { tokens.append(s..<units.count) }
        func string(_ range: Range<Int>) -> String { String(utf16CodeUnits: units[range].map(\.code), count: range.count) }
        let words = tokens.map(string)
        var kind: [Kind] = words.map { looksLikeMath($0) ? .math : isBridge($0) ? .bridge : .text }

        // 수식 낱말이 대부분인 줄은 별행 수식으로 보고 줄 전체를 수식으로 한다.
        var displayLines = Set<Int>()
        for lineNo in Set(units.map(\.line)) {
            let onLine = tokens.indices.filter { units[tokens[$0].lowerBound].line == lineNo }
            let total = onLine.reduce(0) { $0 + tokens[$1].count }
            let math = onLine.filter { kind[$0] == .math }.reduce(0) { $0 + tokens[$1].count }
            if total > 0, Double(math) / Double(total) >= 0.6 {
                displayLines.insert(lineNo)
                onLine.forEach { kind[$0] = .math }
            }
        }
        // 수식 낱말 사이에 낀 기호·숫자 낱말(":=", "+", "1")은 수식에 붙인다.
        for i in kind.indices where kind[i] == .bridge {
            var j = i
            while j < kind.count, kind[j] == .bridge { j += 1 }
            let before = kind[..<i].last(where: { $0 != .bridge })
            if before == .math, j < kind.count, kind[j] == .math { kind[i] = .math }
        }

        // 이어진 수식 낱말을 한 덩어리로 묶는다. 끝에 붙은 문장부호(".", ",", ";")는 본문으로 남긴다.
        var groups: [Range<Int>] = []   // units 범위
        var i = 0
        while i < tokens.count {
            guard kind[i] == .math else { i += 1; continue }
            var j = i
            while j + 1 < tokens.count, kind[j + 1] == .math { j += 1 }
            var end = tokens[j].upperBound
            while end > tokens[j].lowerBound + 1, [0x2E, 0x2C, 0x3B].contains(units[end - 1].code) { end -= 1 }
            groups.append(tokens[i].lowerBound..<end)
            i = j + 1
        }

        let marker = ["X", "Q", "Z", "K", "W"].first { m in
            !words.contains { $0.range(of: "(?<![\\p{L}\\d])\(m) ?\\d", options: .regularExpression) != nil }
        } ?? "X"
        var pageLines: [PDFPage: [CGRect]] = [:]
        func boxes(on page: PDFPage) -> [CGRect] {
            if let cached = pageLines[page] { return cached }
            let found = (page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? [])
                .map { $0.bounds(for: page) }.filter { $0.height > 1 }
            pageLines[page] = found
            return found
        }
        let heights = boxes(on: firstPage).map(\.height).sorted()
        let lineHeight = heights.isEmpty ? 12 : heights[heights.count / 2]
        var spans: [Span] = []
        var text = ""
        var cursor = 0
        for group in groups {
            text += string(cursor..<group.lowerBound)
            text += " \(marker)\(spans.count + 1)"
            cursor = group.upperBound
            let chars = units[group].compactMap { u in u.index.map { (u.page, $0, u.line) } }
            spans.append(span(of: chars, text: PDFText.cleaned(string(group)), display: displayLines, lines: lines,
                              pageLines: chars.first.map { boxes(on: $0.0) } ?? [], lineHeight: lineHeight))
        }
        text += string(cursor..<units.count)
        return Split(text: PDFText.cleaned(text), spans: spans, marker: marker, lineHeight: lineHeight)
    }

    private enum Kind { case text, math, bridge }

    /// 줄마다 글자 상자를 합친다. 별행 수식 줄이 이어지면 한 장으로 합친다.
    /// 글자 상자가 줄 높이의 절반만 나오는 PDF가 있어서, 세로는 줄 상자만큼 늘린다.
    private static func span(of chars: [(PDFPage, Int, Int)], text: String, display: Set<Int>, lines: [PDFSelection],
                             pageLines: [CGRect], lineHeight: CGFloat) -> Span {
        let page = chars.first?.0 ?? PDFPage()
        var rects: [(line: Int, rect: CGRect)] = []
        for (charPage, index, line) in chars where charPage == page {
            guard var box = charPage.selection(for: NSRange(location: index, length: 1))?.bounds(for: charPage),
                  box.width > 0, box.height > 0 else { continue }
            let lineBox = lines[line].bounds(for: charPage)
            if lineBox.height > 0 {
                let minY = min(box.minY, lineBox.minY)
                box = CGRect(x: box.minX, y: minY, width: box.width, height: max(box.maxY, lineBox.maxY) - minY)
            }
            // 같은 줄, 이어진 별행 수식 줄, 또는 PDFKit이 다른 줄로 본 위·아래첨자(∑의 N, i=1)처럼 붙어 있는 상자는 합친다.
            if let last = rects.last, last.line == line || (display.contains(last.line) && display.contains(line))
                || touches(last.rect, box) {
                rects[rects.count - 1] = (line, last.rect.union(box))
            } else {
                rects.append((line, box))
            }
        }
        // 한 덩어리 안에서도 본문 속 수식 줄과 별행 수식이 이어지면 겹칠 수 있다. 낮은 상자를 높은 상자 밖으로 줄인다.
        let boxes = rects.map(\.rect)
        return Span(page: page, rects: boxes.enumerated().map { i, rect in
            var clipped = clip(rect, against: pageLines, lineHeight: lineHeight)
            for (j, other) in boxes.enumerated() where j != i && other.height > rect.height && other.minX < clipped.maxX && other.maxX > clipped.minX {
                if other.midY < clipped.minY + clipped.height * 0.25, other.maxY > clipped.minY, other.maxY < clipped.maxY {
                    clipped = CGRect(x: clipped.minX, y: other.maxY, width: clipped.width, height: clipped.maxY - other.maxY)
                } else if other.midY > clipped.maxY - clipped.height * 0.25, other.minY < clipped.maxY, other.minY > clipped.minY {
                    clipped = CGRect(x: clipped.minX, y: clipped.minY, width: clipped.width, height: other.minY - clipped.minY)
                }
            }
            return clipped
        }, text: text)
    }

    /// ∫ 같은 큰 기호가 있는 줄은 상자가 이웃 줄까지 덮어서 그 줄 글자가 그림에 섞인다.
    /// 폭이 넓은 본문 줄이 상자 위나 아래에 걸쳐 있으면 그 줄과 겹치는 만큼 잘라 낸다.
    /// (좁은 조각은 PDFKit이 따로 떼어 낸 위·아래첨자일 수 있어서 기준으로 쓰지 않는다.)
    private static func clip(_ rect: CGRect, against lines: [CGRect], lineHeight: CGFloat) -> CGRect {
        var minY = rect.minY, maxY = rect.maxY
        let middle = (rect.minY + rect.height * 0.25)...(rect.maxY - rect.height * 0.25)
        for line in lines where line.width > lineHeight * 5 && line.height < lineHeight * 1.5
            && line.minX < rect.maxX && line.maxX > rect.minX && line.minY < maxY && line.maxY > minY
            && !middle.contains(line.midY) {
            if line.midY < rect.midY { minY = max(minY, line.maxY) } else { maxY = min(maxY, line.minY) }
        }
        return maxY - minY >= lineHeight * 0.5 ? CGRect(x: rect.minX, y: minY, width: rect.width, height: maxY - minY) : rect
    }

    private static func touches(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > min(a.height, b.height) * 0.5 && b.minX <= a.maxX + 2 && b.maxX >= a.minX - 2
    }

    /// 수식 낱말인가. 수학 기호·그리스 문자가 있거나, 한 글자 변수(관사 a, A 제외)거나, x0·dx1:T·q(x0)처럼 생겼으면 수식이다.
    /// 논문에는 대명사 I가 거의 없고 항등행렬 I는 흔해서 I는 수식으로 본다.
    public static func looksLikeMath(_ word: String) -> Bool {
        let token = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;"))
        guard !token.isEmpty else { return false }
        if token.unicodeScalars.contains(where: isMathScalar) { return true }
        let core = token.trimmingCharacters(in: CharacterSet(charactersIn: "()[]{}.,;:"))
        if core.count == 1, let c = core.first, c.isLetter, !"aA".contains(c) { return true }
        if core.contains(","), core.split(separator: ",").contains(where: { looksLikeMath(String($0)) }) { return true }
        // 글자 바로 뒤에 숫자(x0, β1, x1,...,xT). 세 글자 넘게 이어진 낱말(ResNet50)은 뺀다.
        if core.range(of: "\\p{L}\\d", options: .regularExpression) != nil,
           core.range(of: "\\p{L}{3}", options: .regularExpression) == nil { return true }
        return core.range(of: "^\\p{L}{1,3}\\(", options: .regularExpression) != nil
    }

    /// 글자 없이 숫자·기호·문장부호로만 된 낱말. 양옆이 수식이면 수식에 붙는다.
    static func isBridge(_ word: String) -> Bool {
        !word.isEmpty && word.unicodeScalars.allSatisfy {
            CharacterSet.decimalDigits.contains($0) || CharacterSet.punctuationCharacters.contains($0)
                || CharacterSet.symbols.contains($0)
        }
    }

    private static func isMathScalar(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3D, 0x3C, 0x3E, 0x5E, 0x5F, 0x7C, 0x7E, 0x5C, 0x2B: return true   // = < > ^ _ | ~ \ +
        case 0xAF, 0xB1, 0xB7, 0xD7, 0xF7: return true                           // ¯ ± · × ÷
        case 0x02C6...0x02DC, 0x0300...0x036F: return true                       // ˆ ˜, 결합 악센트(모자·물결·막대)
        case 0x0370...0x03FF: return true                                        // 그리스 문자
        case 0x2032...0x2037: return true                                        // ′ ″
        case 0x2100...0x23FF: return true                                        // ℝ ℓ, 화살표, 연산자, 기술 기호
        case 0x2700...0x27BF: return true                                        // 딩뱃(수식 글꼴의 θ가 ✓로 나온다)
        case 0x27C0...0x27EF, 0x2980...0x2AFF: return true                       // 수학 기호 보충
        case 0xE000...0xF8FF: return true                                        // 사용자 영역(수식 글꼴 기호)
        case 0x1D400...0x1D7FF: return true                                      // 수학 글자(𝑥, 𝐖)
        default: return false
        }
    }
}
