import AppKit
import PDFKit
import PaperMarkCore

/// PDF 파일 하나. 형광펜을 바꾸면 잠시 뒤 원래 파일에 자동 저장한다.
/// Google Drive 폴더의 파일이면 저장 즉시 Drive가 동기화한다.
@objc(PMDocument)
final class PMDocument: NSDocument {
    private(set) var pdf: PDFDocument?
    private var pendingSave: DispatchWorkItem?

    // Drive(File Provider) 볼륨에서 버전 보관이 확실치 않아 시스템 자동 저장 대신 직접 저장한다.
    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(DocumentWindowController(document: self))
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let document = PDFDocument(data: data) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadCorruptFileError)
        }
        pdf = document
        undoManager?.removeAllActions()
        for case let controller as DocumentWindowController in windowControllers {
            controller.documentDidReload()
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        guard let data = pdf?.dataRepresentation() else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
        }
        return data
    }

    // MARK: 형광펜 편집 (모두 실행 취소 가능)

    func add(_ highlights: [PlacedHighlight]) {
        for h in highlights { h.page.addAnnotation(h.annotation) }
        undoManager?.registerUndo(withTarget: self) { $0.remove(highlights) }
        undoManager?.setActionName("형광펜")
        scheduleSave()
    }

    func remove(_ highlights: [PlacedHighlight]) {
        for h in highlights { h.page.removeAnnotation(h.annotation) }
        undoManager?.registerUndo(withTarget: self) { $0.add(highlights) }
        undoManager?.setActionName("형광펜 지우기")
        scheduleSave()
    }

    func recolor(_ highlight: PlacedHighlight, to color: NSColor) {
        let old = highlight.annotation.color
        highlight.annotation.color = color
        undoManager?.registerUndo(withTarget: self) { $0.recolor(highlight, to: old) }
        undoManager?.setActionName("형광펜 색 바꾸기")
        scheduleSave()
    }

    // MARK: 저장

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func saveNow() {
        pendingSave = nil
        guard let url = fileURL, let type = fileType else { return }
        save(to: url, ofType: type, for: .saveOperation) { [weak self] error in
            if let error { self?.presentError(error) }
        }
    }

    // 창을 닫거나 앱을 끌 때 대기 중인 저장을 먼저 끝내서 "저장할까요?" 창이 뜨지 않게 한다.
    override func canClose(withDelegate delegate: Any, shouldClose shouldCloseSelector: Selector?,
                           contextInfo: UnsafeMutableRawPointer?) {
        guard let work = pendingSave, let url = fileURL, let type = fileType else {
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
            return
        }
        work.cancel()
        pendingSave = nil
        save(to: url, ofType: type, for: .saveOperation) { _ in
            super.canClose(withDelegate: delegate, shouldClose: shouldCloseSelector, contextInfo: contextInfo)
        }
    }

    // MARK: 다른 기기에서 바뀐 파일 다시 읽기

    override func presentedItemDidChange() {
        super.presentedItemDidChange()
        DispatchQueue.main.async { [weak self] in self?.reloadIfChangedElsewhere() }
    }

    private func reloadIfChangedElsewhere() {
        guard pendingSave == nil, !isDocumentEdited, let url = fileURL, let type = fileType,
              let known = fileModificationDate,
              let current = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              current > known else { return }
        try? revert(toContentsOf: url, ofType: type)
    }
}
