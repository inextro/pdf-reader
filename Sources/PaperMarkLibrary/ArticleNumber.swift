import Foundation

/// 학술지 논문의 쪽 번호와 논문 번호(article number)를 가른다.
/// Elsevier·Springer·ACM 학술지처럼 쪽 대신 논문 번호를 다는 곳이 있다. 둘 다 `pages`에 들어오면 참고문헌이 "pp. 103403"이 된다.
public enum ArticleNumber {
    /// fields에 두는 칸 이름. Zotero에는 학술지 논문 번호 칸이 없어 이 이름을 쓴다.
    public static let key = "articleNumber"

    /// `pages`에 든 논문 번호를 `articleNumber`로 옮긴다. 학술지만 본다.
    /// - "12:1–12:25"(ACM): 논문 12, 1–25쪽
    /// - 끝 쪽 없는 다섯 자리 이상 숫자나 "e1002345": 논문 번호(한 쪽짜리 논문의 "5"는 쪽으로 둔다)
    public static func separated(_ fields: [String: String], type: String) -> [String: String] {
        guard type == "journalArticle" else { return fields }
        var f = fields
        let pages = (f["pages"] ?? "").trimmingCharacters(in: .whitespaces)
        if let number = f[key], !number.isEmpty {
            if pages == number { f["pages"] = nil }
            return f
        }
        if let m = match(#"^([0-9A-Za-z]+):(\d+)\s*[-–]\s*\1:(\d+)$"#, pages) {
            f[key] = m[1]
            f["pages"] = "\(m[2])-\(m[3])"
        } else if match(#"^(e\d+|\d{5,})$"#, pages) != nil {
            f[key] = pages
            f["pages"] = nil
        }
        return f
    }

    /// ACM 학술지 PDF 첫 쪽 아래의 "ACM Trans. Inf. Syst., Vol. 41, No. 1, Article 12. Publication date: …".
    /// CrossRef가 ACM 논문 번호를 주지 않아서 PDF에서 읽는다. PDFKit은 띄어쓰기를 자주 빼먹는다("No.1,Article 19.Publicationdate").
    public static func inPDFText(_ text: String) -> String? {
        match(#"Vol\.\s*\d+,\s*No\.\s*[0-9A-Za-z]+,\s*Article\s*([0-9A-Za-z]+?)\.?\s*Publication\s*date"#, text)?[1]
    }

    /// 논문 번호를 PDF·CrossRef에서 찾아볼 학술지 논문: 번호가 없고, 쪽이 비었거나 1쪽에서 시작한다(ACM 학술지는 논문마다 1쪽부터).
    public static func needsLookup(_ e: LibraryEntry) -> Bool {
        guard e.type == "journalArticle", (e.fields[key] ?? "").isEmpty else { return false }
        let pages = (e.fields["pages"] ?? "").trimmingCharacters(in: .whitespaces)
        return pages.isEmpty || match(#"^1\s*[-–]"#, pages) != nil
    }

    /// "1-25" → 25. ACM 참고문헌의 "25 pages".
    static func pageCount(_ pages: String?) -> Int? {
        guard let pages, let m = match(#"^(\d+)\s*[-–]\s*(\d+)$"#, pages),
              let first = Int(m[1]), let last = Int(m[2]), last >= first else { return nil }
        return last - first + 1
    }

    private static func match(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }
}

extension PaperMetadata {
    /// 학술지로 들어온 학회 논문(Zotero에서 NeurIPS·ICLR을 Journal Article로 저장한 경우)의 종류와 venue 칸을 고친다.
    static func correctedType(type: String, venue: String?, fields: [String: String]) -> (String, [String: String]) {
        guard type == "journalArticle", let venue = venue ?? fields["publicationTitle"], isConference(venue) else { return (type, fields) }
        var f = fields
        if let title = f.removeValue(forKey: "publicationTitle"), f["proceedingsTitle"] == nil { f["proceedingsTitle"] = title }
        return ("conferencePaper", f)
    }
}
