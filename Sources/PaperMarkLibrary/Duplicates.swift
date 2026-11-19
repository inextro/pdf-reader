import Foundation

/// 서재 안에서 같은 논문으로 보이는 항목을 찾는다. 저장할 때 쓰는 `Library.existingItem`과 같은 기준이다:
/// DOI가 같거나, arXiv 번호(버전 뺌)가 같거나, 충분히 긴 제목이 글자·숫자만 남겨 같으면 같은 논문이다.
public enum Duplicates {
    /// 항목 id → 같은 논문으로 보이는 다른 항목 id들. 중복이 없는 항목은 들어 있지 않다.
    public static func find(_ items: [LibraryEntry]) -> [Int64: Set<Int64>] {
        var groups: [String: [Int64]] = [:]
        for item in items {
            for key in keys(item) { groups[key, default: []].append(item.id) }
        }
        var out: [Int64: Set<Int64>] = [:]
        for ids in groups.values where ids.count > 1 {
            for id in ids { out[id, default: []].formUnion(ids.filter { $0 != id }) }
        }
        return out
    }

    static func keys(_ item: LibraryEntry) -> [String] {
        var keys: [String] = []
        if let doi = item.doi?.trimmingCharacters(in: .whitespaces).lowercased(), !doi.isEmpty { keys.append("doi:" + doi) }
        if let raw = item.arxivID, let id = PaperID.arxiv(in: "arXiv:" + raw) { keys.append("arxiv:" + id) }
        // 짧은 제목("Introduction" 등)은 다른 논문끼리 우연히 겹칠 수 있어 보지 않는다.
        let title = PaperMetadata.titleKey(item.title)
        if title.count >= 16 { keys.append("title:" + title) }
        return keys
    }
}
