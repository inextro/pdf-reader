import Foundation

/// DBLP(dblp.org) 검색 결과와 .bib를 읽는다. DBLP는 앱의 요청을 봇 확인으로 막아서, 요청은 Chrome 확장이 보내고
/// 받은 내용을 Quillo가 여기서 읽는다(PaperLibrary의 DBLPQueue).
///
/// 1. `search/publ/api?q=<제목>&format=json`: 후보들(제목, 저자, 학회 약칭, 연도, 쪽, DOI, 종류).
/// 2. 학회 이름 전체가 필요하면 `rec/<key>.bib`: booktitle·journal 전체 이름.
public enum DBLP {
    public struct Hit: Equatable {
        public var key: String
        public var title: String
        public var authors: [String]
        public var venue: String?
        public var year: Int?
        public var type: String
        public var pages: String?
        public var volume: String?
        public var number: String?
        public var doi: String?
        public var ee: String?

        public init(key: String, title: String, authors: [String], venue: String?, year: Int?, type: String, pages: String?,
                    volume: String?, number: String?, doi: String?, ee: String?) {
            (self.key, self.title, self.authors, self.venue, self.year, self.type) = (key, title, authors, venue, year, type)
            (self.pages, self.volume, self.number, self.doi, self.ee) = (pages, volume, number, doi, ee)
        }

        /// Quillo의 항목 종류. 학회·학술지 논문이 아니면(CoRR 프리프린트, 책 등) nil.
        public var itemType: String? {
            switch type {
            case "Conference and Workshop Papers": "conferencePaper"
            case "Journal Articles": venue == "CoRR" ? nil : "journalArticle"
            default: nil
            }
        }
    }

    /// 제목의 낱말과 첫 저자의 성으로 찾는다. 제목만으로는 그 제목을 인용한 비슷한 논문들이 앞에 온다
    /// ("Denoising Diffusion Implicit Models"를 제목에 넣은 후속 논문들).
    public static func searchURL(title: String, firstAuthor: String? = nil) -> URL? {
        var components = URLComponents(string: "https://dblp.org/search/publ/api")
        let clean = { (text: String) in
            text.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        let words = clean(title)
        guard !words.isEmpty else { return nil }
        let author = firstAuthor.map(clean).flatMap { $0.isEmpty ? nil : $0 }
        components?.queryItems = [URLQueryItem(name: "q", value: ([words] + (author.map { [$0] } ?? [])).joined(separator: " ")),
                                  URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "h", value: "30")]
        return components?.url
    }

    public static func bibURL(key: String) -> URL? { URL(string: "https://dblp.org/rec/\(key).bib") }

    public static func hits(_ data: Data) -> [Hit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = ((root["result"] as? [String: Any])?["hits"] as? [String: Any])?["hit"] else { return [] }
        let list = hits as? [[String: Any]] ?? (hits as? [String: Any]).map { [$0] } ?? []
        return list.compactMap { hit in
            guard let info = hit["info"] as? [String: Any], let key = info["key"] as? String, let title = string(info["title"]) else { return nil }
            let people = (info["authors"] as? [String: Any])?["author"]
            let authors = (people as? [[String: Any]] ?? (people as? [String: Any]).map { [$0] } ?? [])
                .compactMap { string($0["text"]) }.map(personName)
            return Hit(key: key, title: cleanTitle(title), authors: authors, venue: string(info["venue"]),
                       year: string(info["year"]).flatMap { Int($0) }, type: string(info["type"]) ?? "",
                       pages: string(info["pages"]), volume: string(info["volume"]), number: string(info["number"]),
                       doi: string(info["doi"]), ee: string(info["ee"]))
        }
    }

    /// 제목(대소문자·문장부호 무시)과 첫 저자의 성이 같은 학회·학술지 논문. 여럿이면 prefer 종류를 먼저 고른다.
    public static func match(_ hits: [Hit], title: String, firstAuthor: String?, prefer: String? = nil) -> Hit? {
        let key = PaperMetadata.titleKey(title)
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let candidates = hits.filter { hit in
            guard hit.itemType != nil, PaperMetadata.titleKey(hit.title) == key else { return false }
            guard let firstAuthor, let theirs = hit.authors.first else { return true }
            return fold(theirs).hasSuffix(fold(firstAuthor)) || hit.authors.contains { fold($0).hasSuffix(" " + fold(firstAuthor)) }
        }
        return candidates.first { $0.itemType == prefer } ?? candidates.first
    }

    /// 찾은 논문의 서지 정보. bib가 있으면 학회·학술지의 전체 이름을 쓴다.
    public static func metadata(_ hit: Hit, bib: [String: String]? = nil) -> PaperMetadata {
        var m = PaperMetadata()
        m.type = hit.itemType ?? "other"
        m.title = hit.title
        m.creators = hit.authors.map(Creator.author)
        m.date = hit.year.map(String.init)
        m.doi = hit.doi
        let full = bib.flatMap { $0[m.type == "journalArticle" ? "journal" : "booktitle"] }.map(venueName)
        m.venue = full ?? hit.venue
        if let ee = bib?["url"] ?? hit.ee, hit.doi == nil { m.url = plainURL(ee) }
        if let pages = hit.pages {
            // ACM 학술지는 쪽 대신 "12:1-12:25"(논문 12의 1~25쪽)으로 온다.
            if let colon = pages.firstIndex(of: ":"), m.type == "journalArticle" {
                m.fields[ArticleNumber.key] = String(pages[..<colon])
            } else {
                m.fields["pages"] = pages
            }
        }
        if m.type == "journalArticle" {
            m.fields["volume"] = hit.volume
            m.fields["issue"] = hit.number
        }
        if let publisher = bib?["publisher"] { m.fields["publisher"] = venueName(publisher) }
        // 학회 이름 끝의 날짜("…, December 10-16, 2023")에서 달을 읽는다. DBLP는 따로 달을 주지 않는다.
        if m.type == "conferencePaper", let book = bib?["booktitle"], let year = hit.year, let month = conferenceMonth(book) {
            m.date = String(format: "%04d-%02d", year, month)
        }
        return m
    }

    /// "Advances in Neural Information Processing Systems 33: Annual Conference …, NeurIPS 2020, December 6-12, 2020, virtual"
    /// → "Advances in Neural Information Processing Systems 33: Annual Conference …". 약칭과 연도 뒤의 장소·날짜는 뗀다.
    public static func venueName(_ text: String) -> String {
        var plain = text.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        // "UAI 2009, Proceedings of the Twenty-Fifth Conference …, Montreal, QC, Canada, June 18-21, 2009":
        // 약칭과 연도가 앞에 오면 그것을 떼고, 이름 뒤의 장소·날짜(첫 쉼표부터)도 뗀다.
        if let r = plain.range(of: #"^[A-Z][A-Za-z\-/&*]*[A-Z][A-Za-z\-/&*]*\s*'?\d{2,4},\s*"#, options: .regularExpression) {
            plain.removeSubrange(r)
            if let comma = plain.range(of: ",") { plain = String(plain[..<comma.lowerBound]) }
            return plain
        }
        guard let r = plain.range(of: #",\s*[A-Z][A-Za-z\-/&*]*[A-Z][A-Za-z\-/&*]*\s*'?\d{2,4}\b.*$"#, options: .regularExpression),
              r.lowerBound > plain.startIndex else { return plain }
        return String(plain[..<r.lowerBound])
    }

    static let months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]

    /// 학회 이름 끝에 적힌 개최 달(마지막에 나오는 달 이름). 없으면 nil.
    public static func conferenceMonth(_ booktitle: String) -> Int? {
        let words = booktitle.lowercased().components(separatedBy: CharacterSet.letters.inverted)
        return words.reversed().lazy.compactMap { word in months.firstIndex(of: word).map { $0 + 1 } }.first
    }

    /// BibTeX에서 온 주소는 밑줄이 "\\_"로 이스케이프돼 있다("paper\\_files"). 그대로 두면 링크가 깨진다.
    public static func plainURL(_ text: String) -> String {
        text.replacingOccurrences(of: #"\\([_%&#$~])"#, with: "$1", options: .regularExpression)
    }

    /// "Xiangnan He 0001" → "Xiangnan He" (DBLP가 동명이인을 가르는 번호를 뗀다).
    static func personName(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+\d{4}$"#, with: "", options: .regularExpression)
    }

    static func cleanTitle(_ text: String) -> String {
        var t = PaperMetadata.plain(text)
        if t.hasSuffix(".") { t.removeLast() }
        return t
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s.isEmpty ? nil : s }
        if let list = value as? [Any] { return list.first.flatMap(string) }
        return nil
    }
}

/// BibTeX 항목 하나(DBLP .bib, OpenReview의 _bibtex)를 필드 이름(소문자) → 값으로 읽는다. 값 안의 줄바꿈은 빈칸 하나로.
public enum BibTeXReader {
    public static func fields(_ text: String) -> (type: String, fields: [String: String])? {
        let chars = Array(text)
        guard let at = chars.firstIndex(of: "@"), let open = chars[at...].firstIndex(where: { $0 == "{" || $0 == "(" }) else { return nil }
        let type = String(chars[(at + 1)..<open]).trimmingCharacters(in: .whitespaces).lowercased()
        var i = open + 1
        // 키 건너뛰기
        while i < chars.count, chars[i] != "," { i += 1 }
        var out: [String: String] = [:]
        while i < chars.count {
            i += 1
            while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
            var name = ""
            while i < chars.count, chars[i].isLetter || chars[i].isNumber || chars[i] == "_" || chars[i] == "-" { name.append(chars[i]); i += 1 }
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard !name.isEmpty, i < chars.count, chars[i] == "=" else { break }
            i += 1
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count else { break }
            var value = ""
            if chars[i] == "{" || chars[i] == "\"" {
                let close: Character = chars[i] == "{" ? "}" : "\""
                var depth = 0
                i += 1
                while i < chars.count {
                    let c = chars[i]
                    if c == "{" { depth += 1 } else if c == "}" && depth > 0 { depth -= 1 } else if c == close && depth == 0 { break }
                    value.append(c)
                    i += 1
                }
                i += 1
            } else {
                while i < chars.count, chars[i] != ",", chars[i] != "}", chars[i] != "\n" { value.append(chars[i]); i += 1 }
            }
            out[name.lowercased()] = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            while i < chars.count, chars[i] != "," && chars[i] != "}" { i += 1 }
            if i < chars.count, chars[i] == "}" { break }
        }
        return (type, out)
    }
}

/// OpenReview의 논문(note). 확장이 OpenReview 탭 안에서 API(api2.openreview.net/notes?id=)를 불러 보낸다.
public enum OpenReview {
    /// 채택된 논문은 학회 논문, 심사 중·탈락·철회는 OpenReview 프리프린트. 읽지 못하면 nil.
    public static func metadata(_ data: Data) -> PaperMetadata? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let note = (root["notes"] as? [[String: Any]])?.first, let content = note["content"] as? [String: Any] else { return nil }
        // API v2는 {"value": …}로 감싸고, v1은 값을 바로 둔다.
        func value(_ name: String) -> Any? {
            let raw = content[name]
            return (raw as? [String: Any])?["value"] ?? raw
        }
        guard let title = (value("title") as? String).map(PaperMetadata.plain), !title.isEmpty else { return nil }
        var m = PaperMetadata()
        m.title = title
        m.creators = Creator.people(((value("authors") as? [String]) ?? []).map(Creator.author))
        let venue = (value("venue") as? String) ?? ""
        let venueID = (value("venueid") as? String) ?? ""
        let bib = (value("_bibtex") as? String).flatMap(BibTeXReader.fields)
        let rejected = ["submitted", "withdrawn", "rejected", "desk"].contains { venue.lowercased().contains($0) || venueID.lowercased().contains($0) }
        if let id = note["forum"] as? String ?? note["id"] as? String { m.url = "https://openreview.net/forum?id=\(id)" }
        let millis = (note["pdate"] as? Double) ?? (note["cdate"] as? Double)
        let year = bib?.fields["year"] ?? millis.map { String(Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: $0 / 1000))) }
        m.date = year
        if !rejected, !venue.isEmpty {
            m.type = "conferencePaper"
            // "ICLR 2024 poster" → bib의 booktitle("The Twelfth International Conference on Learning Representations")이 있으면 그것.
            m.venue = bib?.fields["booktitle"].map(DBLP.venueName)
                ?? venue.replacingOccurrences(of: #"\s+(poster|oral|spotlight|notable.*|top.*)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            if let year = venue.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) { m.date = String(venue[year]) }
        } else {
            m.type = "preprint"
            m.venue = "OpenReview"
        }
        return m
    }
}
