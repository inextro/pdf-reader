import PDFKit

/// PDF에서 뽑은 글자를 번역 등에 넘길 수 있게 다듬는다.
public enum PDFText {
    /// 줄 끝 하이픈으로 끊긴 단어를 잇고(recom-↵mender → recommender) 줄바꿈과 겹친 공백을 한 칸으로 줄인다.
    public static func cleaned(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        s = s.replacingOccurrences(of: #"(\p{L})-[ \t]*\n[ \t]*(\p{Ll})"#, with: "$1$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 주석(형광펜·밑줄 등)이 덮고 있는 글자들을 줄 순서대로 뽑는다.
    public static func text(of annotation: PDFAnnotation, on page: PDFPage) -> String {
        cleaned(lineSelections(of: annotation, on: page).compactMap(\.string).joined(separator: "\n"))
    }

    /// 주석이 덮고 있는 글자들의 선택 하나(수식 그림을 잘라 낼 때 쓴다).
    public static func selection(of annotation: PDFAnnotation, on page: PDFPage) -> PDFSelection? {
        let lines = lineSelections(of: annotation, on: page)
        guard let all = lines.first?.copy() as? PDFSelection else { return nil }
        lines.dropFirst().forEach(all.add)
        return all
    }

    private static func lineSelections(of annotation: PDFAnnotation, on page: PDFPage) -> [PDFSelection] {
        // 위아래 줄 글자가 섞이지 않도록 세로로 조금 줄여서 고른다.
        Highlights.rects(of: annotation).compactMap { page.selection(for: $0.insetBy(dx: 0, dy: $0.height * 0.25)) }
    }
}
