import Foundation
import PDFKit
import PaperMarkLibrary

/// 학술지 논문 번호를 PDF 첫 쪽(ACM)과 CrossRef(Elsevier·Springer)에서 찾아 채운다.
extension LibraryStore {
    /// PDF 앞 두 쪽의 글자에서 논문 번호를 찾는다.
    nonisolated static func articleNumber(inPDF document: PDFDocument?) -> String? {
        guard let document else { return nil }
        let text = (0..<min(2, document.pageCount)).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        return ArticleNumber.inPDFText(text)
    }

    /// 1.0.4 이전에 저장한 학술지 논문에 한 번 채운다. 사용자가 고친 칸은 update가 지킨다.
    /// Zotero에서 가져온 뒤에는 `force`로 다시 본다(앱을 켤 때의 확인은 가져오기 전 항목만 봤을 수 있다).
    @MainActor
    func fillArticleNumbers(force: Bool = false) {
        let doneKey = "articleNumbersFilled"
        guard force || !UserDefaults.standard.bool(forKey: doneKey), let folder else { return }
        let candidates = items.filter(ArticleNumber.needsLookup)
        Task { @MainActor in
            var filled = 0
            for entry in candidates {
                let files = entry.attachments.map { Library.resolve($0, in: folder) }
                var number = await Task.detached {
                    files.lazy.compactMap { Self.articleNumber(inPDF: PDFDocument(url: $0)) }.first
                }.value
                if number == nil, let doi = entry.doi {
                    number = try? await MetadataLookup.crossref(doi: doi)?.fields[ArticleNumber.key]
                }
                if let number, setArticleNumber(number, of: entry.id) { filled += 1 }
            }
            UserDefaults.standard.set(true, forKey: doneKey)
            NSLog("%@", "PaperLibrary: filled \(filled) article numbers (\(candidates.count) journal articles checked)")
            if filled > 0 { didModify() }
        }
    }

    /// 번호가 아직 없을 때만 넣는다. 다시 읽기·백업은 부르는 쪽이 한다.
    @MainActor
    @discardableResult
    func setArticleNumber(_ number: String, of id: Int64) -> Bool {
        guard let library, let current = try? library.item(id), ArticleNumber.needsLookup(current) else { return false }
        var m = PaperMetadata(current)
        m.fields[ArticleNumber.key] = number
        do { try library.update(id, with: m, citationKey: current.citationKey) } catch { return false }
        return true
    }
}
