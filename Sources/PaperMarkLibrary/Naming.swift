import Foundation

/// 새 항목의 citation key와 PDF 파일 이름을 패턴으로 짓는다. 패턴의 `{이름}`을 서지 정보로 바꾼다.
///
/// | 이름 | 예 (He et al. 2020, "LightGCN: Simplifying and Powering …") |
/// |---|---|
/// | `{auth}` / `{Auth}` | he / He |
/// | `{authors}` | He et al. |
/// | `{year}` | 2020 |
/// | `{title}` | LightGCN: Simplifying and Powering … |
/// | `{Title1}`…`{Title3}` | LightGCN, LightGCNSimplifying … (의미 있는 첫 낱말들) |
/// | `{title1}`…`{title3}` | lightgcn, lightgcnsimplifying … |
/// | `{venue}` | 학회·저널 이름 |
public enum Naming {
    public static let defaultCitationKey = "{auth}{year}{Title1}"
    public static let defaultFileName = "{title}"
    public static let tokens = ["{auth}", "{Auth}", "{authors}", "{year}", "{title}", "{Title1}", "{title1}", "{venue}"]

    private static let skipWords: Set<String> = ["a", "an", "the", "and", "or", "of", "on", "in", "at", "to", "for", "with",
                                                 "by", "from", "via", "into", "is", "are", "as"]

    public static func expand(_ pattern: String, _ m: PaperMetadata) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\{(\w+)\}"#) else { return pattern }
        var result = pattern
        for match in regex.matches(in: pattern, range: NSRange(pattern.startIndex..., in: pattern)).reversed() {
            guard let whole = Range(match.range, in: pattern), let name = Range(match.range(at: 1), in: pattern),
                  let value = token(String(pattern[name]), m) else { continue }
            result.replaceSubrange(whole, with: value)
        }
        return result
    }

    private static func token(_ name: String, _ m: PaperMetadata) -> String? {
        let people = m.creators.filter { $0.role == "author" }.isEmpty ? m.creators : m.creators.filter { $0.role == "author" }
        let first = ascii(people.first?.family ?? "")
        switch name {
        case "auth": return first.lowercased()
        case "Auth": return first.prefix(1).uppercased() + first.dropFirst()
        case "authors":
            switch people.count {
            case 0: return ""
            case 1: return people[0].family
            case 2: return "\(people[0].family) and \(people[1].family)"
            default: return "\(people[0].family) et al."
            }
        case "year": return m.year.map(String.init) ?? ""
        case "title": return m.title
        case "venue": return m.venue ?? ""
        default:
            guard name.count == 6, let n = Int(name.suffix(1)), name.lowercased().hasPrefix("title") else { return nil }
            // 하이픈으로 이은 낱말은 조각마다 첫 글자를 올린다("Score-based" → "ScoreBased").
            let words = m.title.split(whereSeparator: \.isWhitespace)
                .map { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { ascii(String($0)) }.filter { !$0.isEmpty } }
                .filter { !$0.isEmpty && !skipWords.contains($0.joined().lowercased()) }.prefix(n)
            return name.first == "T" ? words.flatMap { $0 }.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
                                     : words.flatMap { $0 }.joined().lowercased()
        }
    }

    /// 로마자로 옮기고(악센트·한자 등) 영문자와 숫자만 남긴다.
    static func ascii(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? text
        return String(latin.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// taken에 없는 key. 겹치면 a, b, c …를 붙인다.
    public static func citationKey(pattern: String, metadata m: PaperMetadata, taken: Set<String>) -> String {
        var base = String(expand(pattern, m).unicodeScalars.filter {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_-:.".unicodeScalars.contains($0))
        }.map(Character.init))
        if base.isEmpty { base = "item" }
        guard taken.contains(base) else { return base }
        var n = 0
        while true {
            var suffix = "", i = n
            repeat { suffix = String(UnicodeScalar(UInt8(97 + i % 26))) + suffix; i = i / 26 - 1 } while i >= 0
            if !taken.contains(base + suffix) { return base + suffix }
            n += 1
        }
    }

    /// 확장자를 뺀 파일 이름. 파일 이름에 못 쓰는 글자는 빼고 150자 안에서 낱말 단위로 자른다.
    public static func fileName(pattern: String, metadata m: PaperMetadata) -> String {
        var name = expand(pattern, m).replacingOccurrences(of: #"[\\/:*?"<>|\n\r\t]"#, with: "", options: .regularExpression)
        name = PaperMetadata.clean(name).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.count > 150 {
            let cut = name.prefix(150)
            name = String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut)
        }
        return name.isEmpty ? "Untitled" : name
    }
}
