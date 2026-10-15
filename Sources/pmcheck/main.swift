import AppKit
import CoreText
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

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED", "→", outDir.path)
exit(failures == 0 ? 0 : 1)
