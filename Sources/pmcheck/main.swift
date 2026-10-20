import AppKit
import CoreText
import CryptoKit
import PDFKit
import PaperMarkCore

// 사용법: pmcheck <출력 폴더>
// 텍스트 PDF를 만들고, 형광펜을 칠해 저장한 뒤 다시 열어 주석이 보존되는지 확인한다.

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var failures = 0
func check(_ ok: Bool, _ message: String) {
    print(ok ? "PASS" : "FAIL", message)
    if !ok { failures += 1 }
}

func makeSamplePDF(at url: URL) {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    let sentence = "The quick brown fox jumps over the lazy dog. Recommendation systems learn from implicit feedback. "
    for page in 0..<2 {
        ctx.beginPDFPage(nil)
        let text = "Page \(page + 1). " + String(repeating: sentence, count: 14)
        let attr = NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: 14)!])
        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: box.insetBy(dx: 72, dy: 72), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

func renderPNG(_ page: PDFPage, to url: URL) {
    let image = page.thumbnail(of: NSSize(width: 918, height: 1188), for: .mediaBox)
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let sourceURL = outDir.appendingPathComponent("sample.pdf")
let savedURL = outDir.appendingPathComponent("highlighted.pdf")
makeSamplePDF(at: sourceURL)

let doc = PDFDocument(url: sourceURL)!
let page0 = doc.page(at: 0)!, page1 = doc.page(at: 1)!

// 1) 여러 줄 선택(1쪽 안), 2) 쪽을 넘는 선택
let yellow = NSColor(hex: "#FFE45C")!, pink = NSColor(hex: "#F7A8C8")!
let multiLine = page0.selection(for: NSRange(location: 30, length: 180))!
let crossPage = doc.selection(from: page0, atCharacterIndex: page0.numberOfCharacters - 60,
                              to: page1, atCharacterIndex: 50)!

let first = Highlights.make(from: multiLine, color: yellow, author: "tester")
let second = Highlights.make(from: crossPage, color: pink, author: "tester")
check(first.count == 1, "여러 줄 선택 → 주석 1개 (got \(first.count))")
check(second.count == 2, "쪽을 넘는 선택 → 쪽마다 1개, 총 2개 (got \(second.count))")
let lineCount = multiLine.selectionsByLine().count
check(Highlights.rects(of: first[0].annotation).count == lineCount, "줄 수(\(lineCount))만큼 QuadPoints 사각형")

let expectedRects = Highlights.rects(of: first[0].annotation)
for h in first + second { h.page.addAnnotation(h.annotation) }

// 칠한 줄 가운데는 맞고, 페이지 구석은 안 맞아야 한다
let mid = CGPoint(x: expectedRects[0].midX, y: expectedRects[0].midY)
check(Highlights.highlight(on: page0, at: mid) != nil, "칠한 영역 클릭 → 형광펜 찾음")
check(Highlights.highlight(on: page0, at: CGPoint(x: 5, y: 5)) == nil, "빈 영역 클릭 → 없음")

try doc.dataRepresentation()!.write(to: savedURL)

// 다시 열어서 확인
let reloaded = PDFDocument(url: savedURL)!
let r0 = reloaded.page(at: 0)!.annotations.filter(Highlights.isHighlight)
let r1 = reloaded.page(at: 1)!.annotations.filter(Highlights.isHighlight)
check(r0.count == 2 && r1.count == 1, "저장 후 형광펜 개수 유지 (1쪽 \(r0.count), 2쪽 \(r1.count))")
let colors = Set(r0.map { $0.color.hexString })
check(colors == ["#FFE45C", "#F7A8C8"], "색 유지 \(colors.sorted())")
if let y = r0.first(where: { $0.color.hexString == "#FFE45C" }) {
    let got = Highlights.rects(of: y)
    let same = got.count == expectedRects.count && zip(got, expectedRects).allSatisfy {
        abs($0.minX - $1.minX) < 0.5 && abs($0.minY - $1.minY) < 0.5 && abs($0.width - $1.width) < 0.5
    }
    check(same, "저장 후 QuadPoints 위치 유지")
    check(y.userName == "tester", "작성자 유지")
}

renderPNG(reloaded.page(at: 0)!, to: outDir.appendingPathComponent("page1.png"))

// 지우기 → 저장 → 다시 열기
let removeDoc = PDFDocument(url: savedURL)!
for a in removeDoc.page(at: 0)!.annotations.filter(Highlights.isHighlight) { removeDoc.page(at: 0)!.removeAnnotation(a) }
let removedURL = outDir.appendingPathComponent("removed.pdf")
try removeDoc.dataRepresentation()!.write(to: removedURL)
check(PDFDocument(url: removedURL)!.page(at: 0)!.annotations.filter(Highlights.isHighlight).isEmpty, "지운 뒤 저장하면 1쪽 형광펜 없음")

// 겹친 형광펜 합치기: 겹치면 주석 하나(새 색, 한 겹)로, 떨어져 있으면 그대로
let mergeDoc = PDFDocument(url: sourceURL)!
let mp = mergeDoc.page(at: 0)!
let green = NSColor(hex: "#A8E6A1")!
func place(_ hs: [PlacedHighlight]) -> (added: [PlacedHighlight], removed: [PlacedHighlight]) {
    let m = Highlights.merge(hs, color: hs[0].annotation.color)
    for h in m.removed { h.page.removeAnnotation(h.annotation) }
    for h in m.added { h.page.addAnnotation(h.annotation) }
    return m
}
_ = place(Highlights.make(from: mp.selection(for: NSRange(location: 30, length: 120))!, color: yellow))
let overlap = place(Highlights.make(from: mp.selection(for: NSRange(location: 100, length: 150))!, color: green))
let onPage = mp.annotations.filter(Highlights.isHighlight)
check(overlap.removed.count == 1 && onPage.count == 1, "겹친 형광펜 → 주석 1개로 합침 (got \(onPage.count))")
check(onPage.first?.color.hexString == "#A8E6A1", "합친 형광펜은 새 색")
let unionLines = mp.selection(for: NSRange(location: 30, length: 220))!.selectionsByLine().count
let mergedRects = onPage.first.map(Highlights.rects(of:)) ?? []
check(mergedRects.count == unionLines, "줄마다 사각형 하나 (\(mergedRects.count) / \(unionLines)줄)")
let layered = mergedRects.enumerated().contains { i, a in
    mergedRects.enumerated().contains { j, b in i < j && a.intersection(b).width * a.intersection(b).height > 1 } }
check(!layered, "합친 주석 안에서 겹치는 사각형 없음")
let apart = place(Highlights.make(from: mp.selection(for: NSRange(location: 900, length: 40))!, color: yellow))
check(apart.removed.isEmpty && mp.annotations.filter(Highlights.isHighlight).count == 2, "떨어진 형광펜은 합치지 않음")

// 형광펜 말고 다른 주석: 밑줄은 줄 사각형, 펜은 실제 선 근처, 메모는 bounds로 판정. 링크는 제외
let markDoc = PDFDocument(url: sourceURL)!
let kp = markDoc.page(at: 0)!
let underline = PDFAnnotation(bounds: .zero, forType: .underline, withProperties: nil)
let lineRect = Highlights.rects(of: Highlights.make(from: kp.selection(for: NSRange(location: 30, length: 20))!,
                                                    color: yellow)[0].annotation)[0]
underline.bounds = lineRect
underline.quadrilateralPoints = [NSPoint(x: 0, y: lineRect.height), NSPoint(x: lineRect.width, y: lineRect.height),
                                 NSPoint(x: 0, y: 0), NSPoint(x: lineRect.width, y: 0)].map { NSValue(point: $0) }
underline.color = .red
kp.addAnnotation(underline)
// 펜: (100,300)에서 (300,500)으로 가는 대각선. bounds 안이지만 선에서 먼 (280,320)은 안 맞아야 한다.
let inkBounds = CGRect(x: 90, y: 290, width: 220, height: 220)
let ink = PDFAnnotation(bounds: inkBounds, forType: .ink, withProperties: nil)
let stroke = NSBezierPath()
stroke.move(to: NSPoint(x: 10, y: 10)); stroke.line(to: NSPoint(x: 210, y: 210))
ink.add(stroke)
ink.color = .blue
kp.addAnnotation(ink)
let note = PDFAnnotation(bounds: CGRect(x: 500, y: 700, width: 20, height: 20), forType: .text, withProperties: nil)
note.contents = "memo"
let popup = PDFAnnotation(bounds: CGRect(x: 520, y: 600, width: 150, height: 100), forType: .popup, withProperties: nil)
note.popup = popup
kp.addAnnotation(note); kp.addAnnotation(popup)
let link = PDFAnnotation(bounds: CGRect(x: 40, y: 40, width: 60, height: 20), forType: .link, withProperties: nil)
kp.addAnnotation(link)
let markURL = outDir.appendingPathComponent("markups.pdf")
try markDoc.dataRepresentation()!.write(to: markURL)

let mk = PDFDocument(url: markURL)!.page(at: 0)!
func found(_ p: CGPoint) -> String? { Markups.markup(on: mk, at: p).map(Markups.displayName(of:)) }
check(found(CGPoint(x: lineRect.midX, y: lineRect.midY)) == "Underline", "밑줄 위 → Underline")
check(found(CGPoint(x: 200, y: 400)) == "Drawing", "펜 선 위 → Drawing")
check(found(CGPoint(x: 280, y: 320)) == nil, "펜 bounds 안이지만 선에서 먼 곳 → 없음")
check(found(CGPoint(x: 510, y: 710)) == "Note", "메모 아이콘 위 → Note")
check(found(CGPoint(x: 60, y: 50)) == nil, "링크는 사용자 주석이 아님")
// PDFKit은 저장할 때 팝업을 쓰지 않으므로 메모리의 페이지로 확인한다(파일에서 읽으면 팝업이 연결된다).
check(Markups.removalSet(for: note, on: kp).count == 2, "메모를 지우면 팝업도 함께 지움")

// 단축키 정규화와 표시
let shiftD = Shortcut.normalized(characters: "D", modifiers: [.command, .shift])!
check(shiftD.key == "d" && shiftD.modifiers == [.command, .shift] && shiftD.display == "⇧⌘D", "⇧⌘D → d + ⇧⌘ (\(shiftD.display))")
let plus = Shortcut.normalized(characters: "+", modifiers: [.command, .shift])!
check(plus.key == "+" && plus.modifiers == .command, "⇧⌘= → ⌘+ (\(plus.display))")
check(Shortcut.normalized(characters: "\u{7F}", modifiers: .command)!.display == "⌘⌫", "Delete → ⌘⌫")
check(Shortcut.normalized(characters: "e", modifiers: [.shift])?.isValid == false, "⇧E 단독은 안 됨")
let f5 = Shortcut.normalized(characters: "\u{F708}", modifiers: [.function])!
check(f5.isValid && f5.display == "F5", "F5 단독 허용 (\(f5.display))")
let ctrlOptUp = Shortcut.normalized(characters: "\u{F700}", modifiers: [.control, .option, .shift])!
check(ctrlOptUp.display == "⌃⌥⇧↑", "기능 키는 Shift 유지 (\(ctrlOptUp.display))")
let roundTrip = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(shiftD))
check(roundTrip == shiftD, "저장 후 복원")

// 번역용 텍스트 다듬기: 줄 끝 하이픈 잇기, 줄바꿈·겹친 공백 정리
check(PDFText.cleaned("recom-\nmender sys-\ntems\nlearn   from\n") == "recommender systems learn from",
      "하이픈으로 끊긴 단어 잇기와 공백 정리")
check(PDFText.cleaned("Top-\nK results") == "Top- K results", "다음 줄이 대문자면 하이픈을 지우지 않음")
let textDoc = PDFDocument(url: sourceURL)!
let tp = textDoc.page(at: 0)!
let marked = Highlights.make(from: tp.selection(for: NSRange(location: 30, length: 180))!, color: yellow)[0]
let expected = PDFText.cleaned(tp.selection(for: NSRange(location: 30, length: 180))!.string ?? "")
let got = PDFText.text(of: marked.annotation, on: tp)
check(got.contains(String(expected.dropFirst(3).dropLast(3))), "형광펜이 덮은 여러 줄 글자 뽑기 (\(got.count)자)")

// 단어 단위 맞춤: 단어 중간이면 넓히고, 문장부호(오타 "results.In")에서는 멈추고, 앞뒤 공백은 뺀다
func makeTextPDF(_ text: String, at url: URL) -> PDFDocument {
    makeTextPDF(NSAttributedString(string: text, attributes: [.font: NSFont(name: "Helvetica", size: 14)!]), at: url)
}
func makeTextPDF(_ attr: NSAttributedString, at url: URL) -> PDFDocument {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(attr), CFRange(location: 0, length: 0),
                                         CGPath(rect: box.insetBy(dx: 72, dy: 72), transform: nil), nil)
    CTFrameDraw(frame, ctx)
    ctx.endPDFPage()
    ctx.closePDF()
    return PDFDocument(url: url)!
}
// 페이지는 문서를 약하게 참조하므로 문서를 변수로 붙잡아 둔다.
let wordsDoc = makeTextPDF("The quick brown fox saw results.In this case don't stop. See (word). Also [f(x)] here. The users' data and ‘replay’ too. Named ‘t-SNE’ here.",
                          at: outDir.appendingPathComponent("words.pdf"))
let wp = wordsDoc.page(at: 0)!
let wtext = wp.string! as NSString
func snapped(_ fragment: String, offset: Int = 0, length: Int) -> String {
    let at = wtext.range(of: fragment).location + offset
    return Highlights.snappedToWords(wp.selection(for: NSRange(location: at, length: length))!).string ?? ""
}
check(snapped("quick", offset: 2, length: 7) == "quick brown", "단어 중간 → 단어 끝까지 (\(snapped("quick", offset: 2, length: 7)))")
check(snapped("results", offset: 2, length: 3) == "results", "오타 results.In → 마침표 앞에서 멈춤 (\(snapped("results", offset: 2, length: 3)))")
check(snapped(" quick ", length: 7) == "quick", "앞뒤 공백 빼기 (\(snapped(" quick ", length: 7)))")
check(snapped("don't", offset: 1, length: 2) == "don't", "아포스트로피는 단어 안 (\(snapped("don't", offset: 1, length: 2)))")
check(snapped("stop.", length: 5) == "stop.", "직접 포함한 문장부호는 유지 (\(snapped("stop.", length: 5)))")
check(snapped("(word)", length: 3) == "(word)", "여는 괄호를 잡으면 닫는 괄호까지 (\(snapped("(word)", length: 3)))")
check(snapped("(word)", offset: 2, length: 4) == "(word)", "닫는 괄호를 잡으면 여는 괄호까지 (\(snapped("(word)", offset: 2, length: 4)))")
check(snapped("(word)", offset: 1, length: 3) == "word", "괄호 없이 단어만 잡으면 괄호는 빼기 (\(snapped("(word)", offset: 1, length: 3)))")
check(snapped("[f(x)]", length: 4) == "[f(x)]", "중첩 괄호 (\(snapped("[f(x)]", length: 4)))")
check(snapped("users'", offset: 1, length: 2) == "users", "단어 뒤 아포스트로피는 넓히지 않음 (\(snapped("users'", offset: 1, length: 2)))")
check(snapped("‘replay’", offset: 2, length: 3) == "replay", "작은따옴표는 넓히지 않음 (\(snapped("‘replay’", offset: 2, length: 3)))")

// 더블클릭: 누른 글자가 속한 단어만
func clicked(_ fragment: String, offset: Int) -> String {
    Highlights.word(at: wtext.range(of: fragment).location + offset, on: wp)?.string ?? "nil"
}
check(clicked("‘t-SNE’", offset: 4) == "t-SNE", "더블클릭 ‘t-SNE’ → 따옴표 없이 하이픈 단어 (\(clicked("‘t-SNE’", offset: 4)))")
check(clicked("don't", offset: 1) == "don't", "더블클릭 don't (\(clicked("don't", offset: 1)))")
check(clicked("users'", offset: 2) == "users", "더블클릭 users' → 아포스트로피 빼기 (\(clicked("users'", offset: 2)))")
check(clicked("(word)", offset: 0) == "nil", "괄호를 더블클릭하면 단어 없음 (\(clicked("(word)", offset: 0)))")
func doubleClicked(_ fragment: String, offset: Int = 0, length: Int) -> String {
    let at = wtext.range(of: fragment).location + offset
    return Highlights.doubleClickedWord(wp.selection(for: NSRange(location: at, length: length))!)?.string ?? "nil"
}
check(doubleClicked("t-SNE’", offset: 1, length: 5) == "t-SNE", "PDFKit이 잡은 -SNE’ → t-SNE (\(doubleClicked("t-SNE’", offset: 1, length: 5)))")
check(doubleClicked("quick brown", length: 11) == "nil", "더블클릭한 채 여러 단어를 끌면 다시 고르지 않음 (\(doubleClicked("quick brown", length: 11)))")

// 인용 번호 위첨자: 본문보다 작은 글자가 바로 붙어 있다. "replay²¹⁻²³"
let body = NSFont(name: "Helvetica", size: 14)!, small = NSFont(name: "Helvetica", size: 9)!
let supText = NSMutableAttributedString(string: "termed experience replay", attributes: [.font: body])
supText.append(NSAttributedString(string: "21–23", attributes: [.font: small, kCTBaselineOffsetAttributeName as NSAttributedString.Key: 5]))
supText.append(NSAttributedString(string: " that uses word2vec, named ‘t-SNE’", attributes: [.font: body]))
supText.append(NSAttributedString(string: "25", attributes: [.font: small, kCTBaselineOffsetAttributeName as NSAttributedString.Key: 5]))
supText.append(NSAttributedString(string: " here.", attributes: [.font: body]))
let supDoc = makeTextPDF(supText, at: outDir.appendingPathComponent("superscript.pdf"))
let sp = supDoc.page(at: 0)!
let stext = sp.string! as NSString
func snappedSup(_ fragment: String, offset: Int = 0, length: Int) -> String {
    let at = stext.range(of: fragment).location + offset
    return Highlights.snappedToWords(sp.selection(for: NSRange(location: at, length: length))!).string ?? ""
}
check(snappedSup("experience", offset: 3, length: 12) == "experience replay", "위첨자 앞에서 멈춤 (\(snappedSup("experience", offset: 3, length: 12)))")
check(snappedSup("replay21", length: 8) == "replay21", "위첨자를 직접 잡으면 유지 (\(snappedSup("replay21", length: 8)))")
check(snappedSup("word2vec", length: 5) == "word2vec", "같은 크기 숫자는 단어 안 (\(snappedSup("word2vec", length: 5)))")
let replayAt = stext.range(of: "replay21").location
check(Highlights.word(at: replayAt + 2, on: sp)?.string == "replay", "더블클릭 replay²¹ → 위첨자 빼기 (\(Highlights.word(at: replayAt + 2, on: sp)?.string ?? "nil"))")
let tsneAt = stext.range(of: "t-SNE").location
check(Highlights.word(at: tsneAt + 3, on: sp)?.string == "t-SNE", "더블클릭 ‘t-SNE’²⁵ → 따옴표·위첨자 빼기 (\(Highlights.word(at: tsneAt + 3, on: sp)?.string ?? "nil"))")
check(snappedSup("t-SNE", offset: 2, length: 2) == "SNE", "드래그 SN → ‘t-SNE’²⁵의 따옴표 빼기 (\(snappedSup("t-SNE", offset: 2, length: 2)))")

// 파일 트리: 폴더와 PDF만, 숨김·패키지는 빼고, 폴더 먼저 Finder 순서(file2 < file10)
let treeDir = outDir.appendingPathComponent("tree")
try? FileManager.default.removeItem(at: treeDir)
for folder in ["b-folder/sub", "A-folder", "Tool.app", ".hidden-folder"] {
    try FileManager.default.createDirectory(at: treeDir.appendingPathComponent(folder), withIntermediateDirectories: true)
}
for file in ["paper10.pdf", "paper2.PDF", "notes.txt", ".hidden.pdf", "b-folder/sub/deep.pdf"] {
    FileManager.default.createFile(atPath: treeDir.appendingPathComponent(file).path, contents: Data())
}
let listed = FileTree.children(of: treeDir).map(\.lastPathComponent)
check(listed == ["A-folder", "b-folder", "paper2.PDF", "paper10.pdf"], "파일 트리 목록과 순서 (\(listed))")
let deep = treeDir.appendingPathComponent("b-folder/sub/deep.pdf")
let path = FileTree.folders(from: treeDir, to: deep)?.map(\.lastPathComponent)
check(path == ["b-folder", "sub"], "현재 파일까지 펼칠 폴더 (\(path ?? []))")
check(FileTree.folders(from: treeDir.appendingPathComponent("A-folder"), to: deep) == nil, "root 밖 파일은 nil")

// 문서 안 링크: hyperref처럼 이름 붙인 목적지로 이어진 링크와 GoTo 동작 링크만 잡고, 웹 주소 링크는 뺀다.
let refs = (1...12).map { "[\($0)] Author \($0). A paper title that is long enough to wrap onto a second line. In Proc. Conf." }
    .joined(separator: "\n")
let linkURL = outDir.appendingPathComponent("links.pdf")
do {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(linkURL as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    let attr = NSAttributedString(string: refs, attributes: [.font: NSFont(name: "Helvetica", size: 9)!])
    let setter = CTFramesetterCreateWithAttributedString(attr)
    // 두 단: 왼쪽 단에 다 못 넣은 글자는 오른쪽 단으로 이어진다.
    let leftFrame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 54, y: 540, width: 240, height: 200), transform: nil), nil)
    CTFrameDraw(leftFrame, ctx)
    let rest = CTFrameGetVisibleStringRange(leftFrame)
    CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: rest.length, length: 0),
                                         CGPath(rect: CGRect(x: 318, y: 540, width: 240, height: 200), transform: nil), nil), ctx)
    ctx.addDestination("cite.2" as CFString, at: CGPoint(x: 54, y: 718))
    ctx.endPDFPage()
    ctx.beginPDFPage(nil)
    ctx.setDestination("cite.2" as CFString, for: CGRect(x: 10, y: 10, width: 20, height: 10))
    ctx.setURL(URL(string: "https://example.com")! as CFURL, for: CGRect(x: 70, y: 10, width: 20, height: 10))
    ctx.endPDFPage()
    ctx.closePDF()
}
let linkDoc = PDFDocument(url: linkURL)!
let lp = linkDoc.page(at: 0)!, lp2 = linkDoc.page(at: 1)!
let ltext = lp.string! as NSString
let links = lp2.annotations.filter { $0.type == "Link" }.sorted { $0.bounds.minX < $1.bounds.minX }
check(links.map { PDFLinks.destination(of: $0) != nil } == [true, false],
      "이름 붙인 목적지 링크만 문서 안 링크, 웹 주소는 아님 (\(links.map { PDFLinks.destination(of: $0) != nil }))")
check(links.first.flatMap(PDFLinks.destination(of:))?.page === lp, "링크가 1쪽을 가리킴")
let viaAction = PDFAnnotation(bounds: CGRect(x: 40, y: 10, width: 20, height: 10), forType: .link, withProperties: nil)
viaAction.action = PDFActionGoTo(destination: PDFDestination(page: lp, at: CGPoint(x: 54, y: 700)))
check(PDFLinks.destination(of: viaAction)?.page === lp, "GoTo 동작만 있는 링크도 문서 안 링크")
/// 그 글자가 있는 줄 위쪽(참고문헌 링크의 목적지 자리).
func destination(atStartOf fragment: String) -> PDFDestination {
    let bounds = lp.selection(for: ltext.range(of: fragment))!.bounds(for: lp)
    return PDFDestination(page: lp, at: CGPoint(x: bounds.minX, y: bounds.maxY + 2))
}

// 미리보기 영역: 두 단이면 그 단 너비로, 한 단이면 본문 너비로.
let rightStart = (1...12).map { "[\($0)]" }.first { lp.selection(for: ltext.range(of: $0))?.bounds(for: lp).minX ?? 0 > 300 }!
func top(of fragment: String) -> CGPoint {
    let bounds = lp.selection(for: ltext.range(of: fragment))!.bounds(for: lp)
    return CGPoint(x: bounds.minX, y: bounds.maxY + 1)
}
let leftRect = PDFLinks.previewRect(on: lp, at: top(of: "[2]"))
check(leftRect.minX < 54 && abs(leftRect.maxX - 308) < 1 && leftRect.height == 80, "두 단 왼쪽 단 미리보기 (\(leftRect))")
let rightRect = PDFLinks.previewRect(on: lp, at: top(of: rightStart))
check(rightRect.minX > 300 && rightRect.maxX == 612, "두 단 오른쪽 단 미리보기 \(rightStart) (\(rightRect))")
let singleRect = PDFLinks.previewRect(on: wp, at: CGPoint(x: 72, y: 722))
check(singleRect.minX == 66 && singleRect.maxX == 546, "한 단 미리보기는 본문 너비 (\(singleRect))")
let unspecified = CGFloat(kPDFDestinationUnspecifiedValue)
check(PDFLinks.point(of: PDFDestination(page: lp, at: CGPoint(x: unspecified, y: unspecified))) == CGPoint(x: 0, y: 792),
      "좌표를 정하지 않은 목적지는 쪽 왼쪽 위")

// 인용 미리보기: 목적지 좌표가 엉뚱해도(단 끝·쪽 머리) 번호로 항목을 찾고, 그림·식 번호 링크는 미리보지 않는다.
let citeDoc = makeTextPDF((1...14).map { "[\($0)] Author\($0) Name. A paper title, 20\(10 + $0)." }.joined(separator: "\n")
                          + "\nSmith, J. and Lee, K. A study of things, 2020."
                          + "\nSee Figure 3, (5), Jones 2021, Smith et al. 2020 and [7].",
                          at: outDir.appendingPathComponent("cites.pdf"))
let cp = citeDoc.page(at: 0)!, ctext = cp.string! as NSString
func link(over fragment: String, offset: Int = 0, length: Int? = nil, to point: CGPoint) -> PDFAnnotation {
    let r = ctext.range(of: fragment)
    let range = NSRange(location: r.location + offset, length: length ?? r.length - offset)
    let a = PDFAnnotation(bounds: cp.selection(for: range)!.bounds(for: cp), forType: .link, withProperties: nil)
    a.destination = PDFDestination(page: cp, at: point)
    return a
}
func previewHead(_ a: PDFAnnotation, on linkPage: PDFPage? = nil) -> String {
    guard let first = PDFLinks.citationPreview(for: a, on: linkPage ?? cp)?.first else { return "nil" }
    let (page, rect) = (first.page, first.rect)
    return page.selection(for: CGRect(x: rect.minX, y: rect.maxY - 18, width: rect.width, height: 18))?.string?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
}
let pageTop = CGPoint(x: 72, y: 792), pageBottom = CGPoint(x: 72, y: 60)
check(previewHead(link(over: "[7].", offset: 1, length: 1, to: pageTop)).hasPrefix("[7]"),
      "쪽 머리에 찍힌 목적지도 [7] 항목을 찾음 (\(previewHead(link(over: "[7].", offset: 1, length: 1, to: pageTop))))")
check(previewHead(link(over: "[7].", offset: 1, length: 1, to: pageBottom)).hasPrefix("[7]"), "단 끝에 찍힌 목적지도 [7] 항목을 찾음")
let shownSeven = PDFLinks.citationPreview(for: link(over: "[7].", offset: 1, length: 1, to: pageTop), on: cp)?.first
    .flatMap { $0.page.selection(for: $0.rect)?.string } ?? ""
check(shownSeven.hasPrefix("[7]") && !shownSeven.contains("[6]") && !shownSeven.contains("[8]"),
      "미리보기는 그 항목만 담는다 (\(shownSeven.debugDescription))")
check(previewHead(link(over: "Figure 3", offset: 7, length: 1, to: top(of: "[3]"))) == "nil", "Figure 3의 번호 링크는 미리보지 않음")
check(previewHead(link(over: "(5)", offset: 1, length: 1, to: pageTop)) == "nil", "식 번호 (5) 링크는 미리보지 않음")
check(previewHead(link(over: "Smith et al. 2020", to: pageTop)).hasPrefix("Smith, J."),
      "저자-연도 인용은 저자 성으로 항목을 찾음 (\(previewHead(link(over: "Smith et al. 2020", to: pageTop))))")
check(previewHead(link(over: "2020 and", length: 4, to: pageTop)).hasPrefix("Smith, J."), "연도에만 걸린 링크는 앞 낱말의 저자로 찾음")
check(previewHead(link(over: "Jones 2021", to: pageTop)) == "nil", "참고문헌에 없는 저자는 미리보지 않음")
// 이름이 앞에 오는 형식에서 저자가 많아 연도가 미리보기 아래에 있고, 인용 링크는 괄호까지 들거나 줄을 넘어 둘로 나뉜다.
let helvetica: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Helvetica", size: 14)!]
let hanging = NSMutableParagraphStyle()
hanging.headIndent = 12
let authorText = NSMutableAttributedString(
    string: "Ann Park, " + (1...40).map { "Bo Kim\($0)" }.joined(separator: ", ") + ". A paper with many authors, 2019.\n",
    attributes: helvetica.merging([.paragraphStyle: hanging]) { $1 })
authorText.append(NSAttributedString(string: "As shown (Park et al., 2019) here. Wrapped Park et al.,\n2019 ends.", attributes: helvetica))
let authorDoc = makeTextPDF(authorText, at: outDir.appendingPathComponent("authors.pdf"))
let ap = authorDoc.page(at: 0)!, atext = ap.string! as NSString
func authorLink(_ fragment: String, offset: Int = 0, length: Int? = nil) -> PDFAnnotation {
    let r = atext.range(of: fragment)
    let range = NSRange(location: r.location + offset, length: length ?? r.length - offset)
    let a = PDFAnnotation(bounds: ap.selection(for: range)!.bounds(for: ap), forType: .link, withProperties: nil)
    a.destination = PDFDestination(page: ap, at: pageTop)
    ap.addAnnotation(a)
    return a
}
check(previewHead(authorLink("(Park et al., 2019)"), on: ap).hasPrefix("Ann Park"),
      "괄호까지 링크에 든 인용, 연도가 미리보기 아래에 있는 긴 항목 (\(previewHead(authorLink("(Park et al., 2019)"), on: ap)))")
_ = authorLink("Park et al.,\n", length: 12)
let wrappedYear = authorLink("\n2019 ends", offset: 1, length: 4)
check(previewHead(wrappedYear, on: ap).hasPrefix("Ann Park"), "줄을 넘어 나뉜 인용의 연도 쪽 링크도 윗줄 저자로 찾음 (\(previewHead(wrappedYear, on: ap)))")
let shownLong = PDFLinks.citationPreview(for: wrappedYear, on: ap)?.first.flatMap { $0.page.selection(for: $0.rect)?.string } ?? ""
check(shownLong.hasSuffix("many authors, 2019.") && !shownLong.contains("As shown"),
      "긴 항목은 끝(연도)까지 늘려 보여 주고 아래 본문은 담지 않는다 (…\(String(shownLong.suffix(40)).debugDescription))")

// 두 단 참고문헌: 왼쪽 단 끝에서 끊긴 항목은 오른쪽 단 맨 위의 이어지는 부분까지 붙여 보여 준다.
// 번호는 오른쪽에 맞춰 찍어서 "[9]"가 "[10]"보다 안쪽에서 시작하고, 본문과 따로 그린다(ACM처럼).
let spillURL = outDir.appendingPathComponent("spill.pdf")
let spillFont = NSFont(name: "Helvetica", size: 9)!
let entryTexts = (1...14).map { "Author\($0) Name, Other Person, and Third Writer. A fairly long paper title number \($0) about many things. In Proceedings of a Conference, 20\(10 + $0)." }
var spillTop: [CGPoint] = []
var splitEntry = 0
do {
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let ctx = CGContext(spillURL as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    let hanging = NSMutableParagraphStyle()
    hanging.headIndent = 0
    let body = NSAttributedString(string: entryTexts.joined(separator: "\n"), attributes: [.font: spillFont, .paragraphStyle: hanging])
    let setter = CTFramesetterCreateWithAttributedString(body)
    // 번호 자리(18pt)를 비우고 본문을 그린 뒤, 각 항목 첫 줄 왼쪽에 번호를 따로 찍는다.
    var leftHeight: CGFloat = 200, left: CTFrame
    repeat {   // 항목 중간에서 끊기도록 왼쪽 단 높이를 고른다
        left = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                                        CGPath(rect: CGRect(x: 72, y: 720 - leftHeight, width: 222, height: leftHeight), transform: nil), nil)
        let cut = CTFrameGetVisibleStringRange(left).length
        let starts = entryTexts.indices.map { entryTexts[..<$0].reduce(0) { $0 + ($1 as NSString).length + 1 } }
        splitEntry = starts.lastIndex { $0 < cut } ?? 0
        if !starts.contains(cut) && cut - starts[splitEntry] > 30 { break }
        leftHeight += 3
    } while leftHeight < 400
    let rest = CTFrameGetVisibleStringRange(left).length
    let right = CTFramesetterCreateFrame(setter, CFRange(location: rest, length: 0),
                                         CGPath(rect: CGRect(x: 336, y: 72, width: 222, height: 648), transform: nil), nil)
    for frame in [left, right] {
        CTFrameDraw(frame, ctx)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let frameX: CGFloat = frame === left ? 72 : 336, frameY: CGFloat = frame === left ? 720 - leftHeight : 72
        for (line, origin) in zip(lines, origins) {
            let start = CTLineGetStringRange(line).location
            guard let n = entryTexts.indices.first(where: { entryTexts[..<$0].reduce(0) { $0 + ($1 as NSString).length + 1 } == start }) else { continue }
            let label = NSAttributedString(string: "[\(n + 1)]", attributes: [.font: spillFont])
            let labelLine = CTLineCreateWithAttributedString(label)
            let width = CTLineGetTypographicBounds(labelLine, nil, nil, nil)
            ctx.textPosition = CGPoint(x: frameX - 4 - width, y: frameY + origin.y)   // 오른쪽 맞춤
            CTLineDraw(labelLine, ctx)
            spillTop.append(CGPoint(x: frameX - 18, y: frameY + origin.y + 10))
        }
    }
    ctx.textPosition = CGPoint(x: 72, y: 750)
    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "See \(splitEntry + 1) and 9 here.", attributes: [.font: spillFont])), ctx)
    ctx.endPDFPage()
    ctx.closePDF()
}
let spillDoc = PDFDocument(url: spillURL)!
let spillPage = spillDoc.page(at: 0)!
/// 쪽 위 "See n and 9 here."(n은 끊긴 항목 번호)의 번호에 건 링크.
func spillCite(_ number: Int, to entry: Int) -> PDFAnnotation {
    let sentence = "See \(splitEntry + 1) and 9"
    let start = (spillPage.string! as NSString).range(of: sentence).location
    let range = number == 9 ? NSRange(location: start + sentence.count - 1, length: 1) : NSRange(location: start + 4, length: "\(number)".count)
    let a = PDFAnnotation(bounds: spillPage.selection(for: range)!.bounds(for: spillPage), forType: .link, withProperties: nil)
    a.destination = PDFDestination(page: spillPage, at: spillTop[entry])
    return a
}
let spillLink = spillCite(splitEntry + 1, to: splitEntry)
let spillRegions = PDFLinks.citationPreview(for: spillLink, on: spillPage) ?? []
let spillShown = spillRegions.map { $0.page.selection(for: $0.rect)?.string ?? "" }
check(spillRegions.count == 2 && spillShown[0].hasPrefix("[\(splitEntry + 1)]") && spillShown[1].hasSuffix("20\(11 + splitEntry).")
      && !spillShown.joined().contains("[\(splitEntry + 2)]"),
      "단 끝에서 끊긴 [\(splitEntry + 1)] 항목은 오른쪽 단 이어지는 부분까지, 다음 항목 없이 (\(spillShown.map { String($0.suffix(30)) }))")
let nineLink = spillCite(9, to: 8)
let nineShown = (PDFLinks.citationPreview(for: nineLink, on: spillPage) ?? []).map { $0.page.selection(for: $0.rect)?.string ?? "" }.joined()
check(nineShown.hasPrefix("[9]") && nineShown.contains("2019.") && !nineShown.contains("[10]"),
      "오른쪽 맞춤 번호: [9] 항목은 왼쪽으로 삐져나온 [10]에서 끝난다 (…\(String(nineShown.suffix(30)).debugDescription))")

// 저자가 너무 많아 한도를 넘는 항목은 앞 몇 줄과 끝(제목·연도)만 보여 주고 가운데는 건너뛴다.
let manyText = NSMutableAttributedString(
    string: "Ann Park, " + (1...260).map { "Bo Kim\($0)" }.joined(separator: ", ") + ". A paper with very many authors. Big Conference, 2018.\n",
    attributes: [.font: NSFont(name: "Helvetica", size: 10)!, .paragraphStyle: hanging])
manyText.append(NSAttributedString(string: "As shown by Park et al. (2018) here.", attributes: [.font: NSFont(name: "Helvetica", size: 10)!]))
let manyDoc = makeTextPDF(manyText, at: outDir.appendingPathComponent("many.pdf"))
let manyPage = manyDoc.page(at: 0)!
let manyLink = PDFAnnotation(bounds: manyPage.selection(for: (manyPage.string! as NSString).range(of: "Park et al."))!.bounds(for: manyPage), forType: .link, withProperties: nil)
manyLink.destination = PDFDestination(page: manyPage, at: pageTop)
manyPage.addAnnotation(manyLink)
let manyRegions = PDFLinks.citationPreview(for: manyLink, on: manyPage) ?? []
let manyShown = manyRegions.map { $0.page.selection(for: $0.rect)?.string ?? "" }
check(manyRegions.count == 2 && manyRegions[1].omittedBefore && manyShown[0].hasPrefix("Ann Park")
      && manyShown[1].hasSuffix("Big Conference, 2018.") && !manyShown.joined().contains("As shown")
      && manyRegions.map(\.rect.height).reduce(0, +) < 120,
      "저자가 너무 많은 항목은 앞뒤만, 가운데 생략 (\(manyRegions.map { Int($0.rect.height) }) …\(String(manyShown.last?.suffix(30) ?? "").debugDescription))")
check(PDFLinks.citationNumber("[12]") == 12 && PDFLinks.citationNumber("12,") == 12 && PDFLinks.citationNumber("2017") == nil
      && PDFLinks.citationNumber("Fig. 3") == nil, "번호 인용 번호 읽기")
check(PDFLinks.startsEntry("[3] Author", number: 3) && PDFLinks.startsEntry("3. Author", number: 3)
      && PDFLinks.startsEntry("3 Author", number: 3) && !PDFLinks.startsEntry("30. Author", number: 3)
      && !PDFLinks.startsEntry("3 of the", number: 3), "번호 항목 첫 줄 알아보기")

// 목차: 지금 읽는 위치를 지난 마지막 항목. 두 단이라 같은 쪽 안에서 목차 순서와 높이 순서가 어긋날 수 있다.
let sections = [PDFContents.Position(page: 0, y: 700), .init(page: 2, y: 600), .init(page: 2, y: 300), .init(page: 2, y: 700), .init(page: 4, y: 500)]
check(PDFContents.current(in: sections, at: .init(page: 0, y: 750)) == nil, "첫 절 위면 고른 항목 없음")
check(PDFContents.current(in: sections, at: .init(page: 1, y: 100)) == 0, "다음 절 전까지는 앞 절")
check(PDFContents.current(in: sections, at: .init(page: 2, y: 400)) == 3, "같은 쪽에서 위치를 지난 목차 순서의 마지막 항목")
check(PDFContents.current(in: sections, at: .init(page: 3, y: 0)) == 3, "쪽을 넘기면 그 쪽의 마지막 절")
check(PDFContents.current(in: sections, at: .init(page: 9, y: 0)) == 4, "끝 절")
let item = PDFOutline()
item.action = PDFActionGoTo(destination: PDFDestination(page: lp, at: CGPoint(x: 0, y: 500)))
check(PDFLinks.destination(of: item)?.page === lp, "GoTo 동작만 있는 목차 항목도 목적지가 있다")
check(PDFLinks.destination(of: PDFOutline()) == nil, "목적지 없는 목차 항목")

// 업데이트: 버전 비교, 릴리스 JSON, 내려받은 zip 검증과 앱 교체
check(Updates.isNewer("0.10.0", than: "0.9.1") && Updates.isNewer("v0.5.1", than: "0.5.0")
      && Updates.isNewer("1.0", than: "0.9.9") && !Updates.isNewer("0.5.0", than: "0.5.0")
      && !Updates.isNewer("0.5", than: "0.5.0") && !Updates.isNewer("0.4.9", than: "0.5.0"), "버전 비교")

let updateDir = outDir.appendingPathComponent("update")
try? FileManager.default.removeItem(at: updateDir)
try FileManager.default.createDirectory(at: updateDir, withIntermediateDirectories: true)
/// Info.plist만 든 가짜 PaperMark.app을 만들어 release.sh처럼 ditto로 묶는다.
func makeAppZip(version: String, bundleID: String = "com.inextro.papermark", name: String) -> URL {
    let folder = updateDir.appendingPathComponent(name)
    let app = folder.appendingPathComponent("PaperMark.app")
    try! FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    (["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version] as NSDictionary)
        .write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    let zip = updateDir.appendingPathComponent("\(name).zip")
    let ditto = Process()
    ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    ditto.arguments = ["-c", "-k", "--keepParent", app.path, zip.path]
    try! ditto.run()
    ditto.waitUntilExit()
    return zip
}
func sha256(_ url: URL) -> String {
    "sha256:" + SHA256.hash(data: try! Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
let goodZip = makeAppZip(version: "9.9.9", name: "good")
let releaseJSON = """
{"tag_name": "v9.9.9", "html_url": "https://github.com/inextro/pdf-reader/releases/tag/v9.9.9",
 "body": "- New: something\\n\\n---\\nDownload `PaperMark-9.9.9.zip`, unzip, and move it.",
 "assets": [{"name": "PaperMark-9.9.9.zip", "browser_download_url": "\(goodZip.absoluteString)", "digest": "\(sha256(goodZip))"}]}
"""
let releaseFile = updateDir.appendingPathComponent("latest.json")
try releaseJSON.write(to: releaseFile, atomically: true, encoding: .utf8)
let semaphore = DispatchSemaphore(value: 0)
var fetched: Updates.Release?
Task { fetched = try? await Updates.latestRelease(from: releaseFile); semaphore.signal() }
semaphore.wait()
check(fetched?.version == "9.9.9" && fetched?.zip?.url == goodZip, "릴리스 JSON에서 버전과 zip 찾기 (\(fetched?.version ?? "nil"))")
check(fetched?.changes == "- New: something", "패치 노트에서 설치 안내 빼기 (\(fetched?.changes ?? "nil"))")

let unpacked = try? Updates.unpack(zip: goodZip, digest: sha256(goodZip), bundleID: "com.inextro.papermark", version: "9.9.9")
check(unpacked?.lastPathComponent == "PaperMark.app", "zip을 풀어 앱 찾기")
func unpackError(_ zip: URL, digest: String?, version: String = "9.9.9") -> Updates.UpdateError? {
    do { _ = try Updates.unpack(zip: zip, digest: digest, bundleID: "com.inextro.papermark", version: version); return nil }
    catch { return error as? Updates.UpdateError }
}
check(unpackError(goodZip, digest: "sha256:" + String(repeating: "0", count: 64)) == .checksumMismatch, "체크섬이 다르면 거부")
check(unpackError(goodZip, digest: nil, version: "9.9.8") == .notTheApp("version"), "버전이 다르면 거부")
check(unpackError(makeAppZip(version: "9.9.9", bundleID: "com.example.other", name: "other"), digest: nil) == .notTheApp("bundle ID"),
      "번들 ID가 다르면 거부")

let installedApp = updateDir.appendingPathComponent("Installed/PaperMark.app")
try FileManager.default.createDirectory(at: installedApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)
(["CFBundleShortVersionString": "0.5.0"] as NSDictionary).write(to: installedApp.appendingPathComponent("Contents/Info.plist"), atomically: true)
if let unpacked { try? Updates.replace(installedApp, with: unpacked) }
let replacedVersion = NSDictionary(contentsOf: installedApp.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
check(replacedVersion == "9.9.9", "설치된 앱을 새 앱으로 교체 (\(replacedVersion ?? "nil"))")

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED", "→", outDir.path)
exit(failures == 0 ? 0 : 1)
