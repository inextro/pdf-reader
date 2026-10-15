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
        let lines = Highlights.rects(of: annotation).compactMap { rect -> String? in
            // 위아래 줄 글자가 섞이지 않도록 세로로 조금 줄여서 고른다.
            page.selection(for: rect.insetBy(dx: 0, dy: rect.height * 0.25))?.string
        }
        return cleaned(lines.joined(separator: "\n"))
    }
}
