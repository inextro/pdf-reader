import Foundation

/// DBLP에서 찾은 정보를 서재의 항목과 견준다.
/// - 빈 칸(학회 이름, 연도, 쪽 등)은 채운다.
/// - 이미 있는 값이 DBLP와 다르면 바꾸지 않고 differences에 적어 둔다. 정보 패널에서 사용자가 고른다.
/// - arXiv 프리프린트가 학회·학술지에 실렸으면 published에 적어 둔다. 정보 패널(또는 저장 때 설정)에 따라 바꾼다.
/// 기록은 항목의 fields["_dblp"](JSON)에 둔다. "_"로 시작하는 필드는 정보 패널과 BibTeX에 보이지 않는다.
public enum DBLPCheck {
    public static let fieldKey = "_dblp"

    public struct Published: Codable, Equatable {
        public var type: String
        public var venue: String?
        public var year: Int?
        public var pages: String?
        public var volume: String?
        public var issue: String?
        public var articleNumber: String?
        public var publisher: String?
        public var doi: String?
        public var url: String?
        /// 학회 달까지 아는 날짜("2023-12"). 예전 기록에는 없다.
        public var date: String? = nil
    }

    public struct Record: Codable, Equatable {
        /// DBLP의 논문 key(conf/sigir/0001DWLZ020).
        public var key: String
        /// 필드 이름(year, pages, volume, issue, doi, type) → DBLP의 값.
        public var differences: [String: String] = [:]
        public var published: Published?
        /// 사용자가 지금 값을 지키기로 한 것("pages=639-648", "published=<key>"). 같은 값은 다시 묻지 않는다.
        public var ignored: [String] = []
    }

    /// 다를 때 정보 패널에 보이는 이름.
    public static func title(of field: String) -> String {
        ["year": "Publication date", "pages": "Pages", "volume": "Volume", "issue": "Issue", "doi": "DOI", "type": "Type"][field] ?? field
    }

    public static func record(of e: LibraryEntry) -> Record? {
        e.fields[fieldKey].flatMap { try? JSONDecoder().decode(Record.self, from: Data($0.utf8)) }
    }

    /// 정보 패널에 노란 칸이 뜨는 논문: 출판본 제안이나 DBLP와 다른 값이 남아 있다.
    public static func needsReview(_ e: LibraryEntry) -> Bool {
        guard e.fields[fieldKey] != nil, let record = record(of: e) else { return false }
        return record.published != nil || !record.differences.isEmpty
    }

    /// 사용자가 상태 태그 Verified를 붙인 논문: 직접 확인했으니 빈 칸도 말없이 채우지 않는다(다른 값은 묻는다).
    public static func isVerified(_ e: LibraryEntry) -> Bool {
        e.tags.contains { $0.lowercased().replacingOccurrences(of: "/", with: "").trimmingCharacters(in: .whitespaces) == "verified" }
    }

    /// 날짜만 "2015"처럼 연도뿐이다.
    static func yearOnly(_ date: String?) -> Bool {
        (date ?? "").trimmingCharacters(in: .whitespaces).range(of: #"^\d{4}$"#, options: .regularExpression) != nil
    }

    /// 날짜를 견줄 일이 있다: 연도가 다르거나 지금 날짜가 연도뿐이다. 그럴 때만 정확한 날짜(학회 달, 출판사 날짜)를 더 받아 온다.
    public static func dateNeedsCheck(_ e: LibraryEntry, year: Int?) -> Bool {
        guard !isPreprint(e), let year, let mine = PaperMetadata(e).year else { return false }
        return mine != year || yearOnly(e.date)
    }

    /// 출판사 DOI(arXiv DOI가 아닌 것). 있으면 날짜는 출판사가 CrossRef에 등록한 것을 따른다.
    public static func publisherDOI(_ e: LibraryEntry) -> String? {
        guard let doi = e.doi, !doi.isEmpty, !doi.lowercased().hasPrefix("10.48550/") else { return nil }
        return doi
    }

    public static func isPreprint(_ e: LibraryEntry) -> Bool {
        e.type == "preprint" || (e.venue ?? "").lowercased().contains("arxiv")
    }

    /// DBLP에서 찾은 found를 e에 반영한 서지 정보. 바뀌는 것이 없으면 nil.
    public static func apply(_ found: PaperMetadata, key: String, to e: LibraryEntry) -> PaperMetadata? {
        let before = PaperMetadata(e)
        var m = before
        var record = record(of: e).flatMap { $0.key == key ? $0 : Record(key: key, ignored: $0.ignored) } ?? Record(key: key)
        record.differences = [:]

        if isPreprint(e) {
            if ["conferencePaper", "journalArticle"].contains(found.type), !record.ignored.contains("published=\(key)") {
                record.published = Published(type: found.type, venue: found.venue, year: found.year, pages: found.fields["pages"],
                                             volume: found.fields["volume"], issue: found.fields["issue"],
                                             articleNumber: found.fields[ArticleNumber.key], publisher: found.fields["publisher"],
                                             doi: found.doi, url: found.url, date: found.date)
            }
        } else {
            record.published = nil
            let fill = !isVerified(e)
            func empty(_ s: String?) -> Bool { (s ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            // 빈 칸 채우기(Verified 논문은 하지 않는다)
            if fill { fillEmpty() }
            func fillEmpty() {
            if empty(m.venue), let venue = found.venue {
                if ["other", "webpage"].contains(m.type) { m.type = found.type }
                setVenue(&m, venue)
            }
            if empty(m.date) { m.date = found.date }
            if m.creators.isEmpty { m.creators = found.creators }
            if empty(m.doi), let doi = found.doi { m.doi = doi }
            let numbered = !empty(m.fields[ArticleNumber.key])
            if empty(m.fields["pages"]), !numbered, let pages = found.fields["pages"] { m.fields["pages"] = pages }
            if !numbered, empty(m.fields["pages"]), let number = found.fields[ArticleNumber.key] { m.fields[ArticleNumber.key] = number }
            if m.type == "journalArticle" {
                for name in ["volume", "issue"] where empty(m.fields[name]) { m.fields[name] = found.fields[name] }
            }
            if m.type == "conferencePaper", empty(m.fields["publisher"]) { m.fields["publisher"] = found.fields["publisher"] }
            }

            // 다른 값 적어 두기
            var theirs: [String: String] = [:]
            // 날짜: 연도가 다르거나, 지금은 연도뿐인데 달까지 알면 묻는다.
            if let a = before.year, let b = found.year {
                let date = found.date ?? String(b)
                if a != b || (yearOnly(before.date) && date.count > 4) { theirs["year"] = date }
            }
            // DBLP의 쪽이 범위가 아니면("1") 자리만 채운 값이라 비교하지 않는다.
            if let a = before.fields["pages"], let b = found.fields["pages"], b.contains(where: { "-–—".contains($0) }),
               pageKey(a) != pageKey(b) { theirs["pages"] = b }
            if m.type == "journalArticle", found.type == "journalArticle" {
                for name in ["volume", "issue"] {
                    if let a = before.fields[name], let b = found.fields[name], a.trimmingCharacters(in: .whitespaces) != b { theirs[name] = b }
                }
            }
            if let a = before.doi, let b = found.doi, a.lowercased() != b.lowercased(), !a.lowercased().hasPrefix("10.48550/") { theirs["doi"] = b }
            let kinds = ["conferencePaper", "journalArticle"]
            if kinds.contains(before.type), kinds.contains(found.type), before.type != found.type { theirs["type"] = found.type }
            // 날짜는 연도로 견준다: "year=2016"을 지키기로 했으면 "2016-10"도 다시 묻지 않는다.
            record.differences = theirs.filter { field, value in
                !record.ignored.contains { kept in
                    kept == "\(field)=\(value)" || (field == "year" && kept.hasPrefix("year=") && kept.dropFirst(5).prefix(4) == value.prefix(4))
                }
            }
        }

        m.fields[fieldKey] = encode(record)
        return m == before ? nil : m
    }

    /// 다른 값 하나를 DBLP 쪽으로 바꾼 서지 정보.
    public static func useDBLP(_ field: String, in e: LibraryEntry) -> PaperMetadata? {
        guard var record = record(of: e), let value = record.differences[field] else { return nil }
        var m = PaperMetadata(e)
        switch field {
        case "year":
            // 날짜의 연도만 바꾼다(달·일은 판마다 달라 버린다).
            m.date = value
        case "doi": m.doi = value
        case "type":
            let venue = m.venue
            m.type = value
            if let venue { setVenue(&m, venue) }
        default: m.fields[field] = value
        }
        record.differences[field] = nil
        m.fields[fieldKey] = encode(record)
        return m
    }

    /// 다른 값 하나를 지금 값 그대로 두기로 한다. 같은 DBLP 값은 다시 묻지 않는다.
    public static func keep(_ field: String, in e: LibraryEntry) -> PaperMetadata? {
        guard var record = record(of: e), let value = record.differences[field] else { return nil }
        var m = PaperMetadata(e)
        record.differences[field] = nil
        record.ignored.append("\(field)=\(value)")
        m.fields[fieldKey] = encode(record)
        return m
    }

    /// 출판본으로 바꾼 서지 정보. 제목·저자·citation key는 그대로 둔다.
    /// crossref는 출판본 DOI로 CrossRef에서 받은 정보(학술지 전체 이름 등). 있으면 DBLP보다 먼저 쓴다.
    public static func usePublished(in e: LibraryEntry, crossref: PaperMetadata? = nil) -> PaperMetadata? {
        guard var record = record(of: e), let p = record.published else { return nil }
        var m = PaperMetadata(e)
        m.type = p.type
        setVenue(&m, crossref?.venue ?? p.venue.map(DBLP.venueName) ?? "")
        if m.venue == "" { m.venue = nil }
        // 날짜: CrossRef(출판사) > DBLP의 학회 달 > 연도. 프리프린트의 arXiv 날짜는 출판본 날짜가 아니다.
        if let date = crossref?.date ?? p.date { m.date = date }
        else if let year = p.year, m.year != year { m.date = String(year) }
        for name in ["pages", "volume", "issue", ArticleNumber.key, "publisher", "archiveID"] { m.fields[name] = nil }
        let fields: [String: String?] = ["pages": p.pages, "volume": p.volume, "issue": p.issue, ArticleNumber.key: p.articleNumber,
                                         "publisher": p.publisher]
        for (name, value) in fields { m.fields[name] = crossref?.fields[name] ?? value }
        if m.type != "journalArticle" { m.fields["volume"] = nil; m.fields["issue"] = nil }
        // DOI 하나: 출판본 DOI. 없으면(NeurIPS 등) arXiv DOI를 버리고 출판본 주소를 둔다. arXiv 번호는 남겨 같은 논문을 알아본다.
        // ICLR 2015 같은 일부 학회 논문은 DBLP에 arXiv DOI만 있다. 그건 출판본 DOI가 아니니 기존 DOI·주소를 둔다.
        let doi = p.doi.flatMap { $0.lowercased().hasPrefix("10.48550/") ? nil : $0 }
        if p.doi == nil || doi != nil { m.doi = doi }
        if doi == nil, let url = p.url { m.url = DBLP.plainURL(url) }
        record.published = nil
        m.fields[fieldKey] = encode(record)
        return m
    }

    /// 출판본으로 바꾸지 않기로 한다. 같은 출판본은 다시 묻지 않는다.
    public static func keepPreprint(_ e: LibraryEntry) -> PaperMetadata? {
        guard var record = record(of: e), record.published != nil else { return nil }
        var m = PaperMetadata(e)
        record.published = nil
        record.ignored.append("published=\(record.key)")
        m.fields[fieldKey] = encode(record)
        return m
    }

    /// venue는 종류에 맞는 Zotero 필드 하나에만 둔다.
    static func setVenue(_ m: inout PaperMetadata, _ venue: String) {
        for name in ["publicationTitle", "proceedingsTitle", "repository", "websiteTitle", "bookTitle"] { m.fields[name] = nil }
        m.venue = venue
        if !venue.isEmpty { m.fields[m.venueField] = venue }
    }

    /// "639–648", "639--648" → "639-648".
    /// "1–22"와 "2:1-2:22"(ACM의 논문 번호:쪽)를 같게 본다.
    public static func pageKey(_ s: String) -> String {
        s.replacingOccurrences(of: #"\b\d+:"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[-–—]+\s*"#, with: "-", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func encode(_ record: Record) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: (try? encoder.encode(record)) ?? Data(), as: UTF8.self)
    }
}
