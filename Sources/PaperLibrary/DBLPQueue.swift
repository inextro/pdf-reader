import AppKit
import PaperMarkLibrary

/// DBLP에 물어볼 논문들. DBLP는 앱의 요청을 봇 확인으로 막으므로, Chrome 확장이 1분마다(그리고 논문을 저장한 뒤)
/// `GET /tasks`로 받을 주소를 가져가 브라우저에서 받고 `POST /task-result`로 돌려준다.
///
/// - 확장으로 저장한 논문(saved): 빈 칸을 채우고 다른 값을 적어 둔다. arXiv 논문의 출판본은 설정(Use the published version)에
///   따라 바로 바꾼다.
/// - 서재 전체(library, File → Check Library with DBLP…): 빈 칸을 채우고, 다른 값과 출판본은 정보 패널에서 고르게 둔다.
/// - 일주일에 한 번(weekly, 설정에서 켠 경우): 서재의 arXiv 논문이 학회·학술지에 실렸는지.
@MainActor
final class DBLPQueue {
    static let shared = DBLPQueue()
    static let didChange = Notification.Name("DBLPQueueDidChange")

    enum Purpose { case saved, library, weekly }

    private struct Job {
        var itemID: Int64
        var purpose: Purpose
        /// 검색에서 찾은 논문. 학회 전체 이름이 필요하면 .bib을 한 번 더 받는다.
        var hit: DBLP.Hit?
        var url: URL?
    }

    private struct Batch {
        var total = 0
        var done = 0
        var filled = 0
        var differences = 0
        var published: [Int64] = []
    }

    private var waiting: [Job] = []
    private var inFlight: [String: (job: Job, since: Date)] = [:]
    private var batches: [Purpose: Batch] = [:]
    /// 확장이 마지막으로 찾아온 때. 몇 분 안이면 Chrome과 확장이 켜져 있다.
    private(set) var lastPoll: Date?
    /// DBLP의 봇 확인을 통과하지 못하면 잠시 쉰다.
    private var pausedUntil: Date?
    private var timer: Timer?
    /// 확장이 요청 사이에 쉬는 시간(ms). DBLP가 요청 제한(429)을 걸면 늘리고, 잘 받으면 조금씩 줄인다.
    private(set) var delay = 3000
    private var successes = 0

    /// ~/Library/Logs/Quillo/dblp.log에 한 줄. 확장과 주고받는 일이 보이지 않아 문제를 찾기 어려워서 남긴다.
    static func log(_ text: String) {
        let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Quillo")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("dblp.log")
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: file)
        }
    }

    var isConnected: Bool { lastPoll.map { Date().timeIntervalSince($0) < 180 } ?? false }

    /// 화면에 보일 진행 상황: 서재 확인과 주간 확인(논문 하나를 저장할 때는 보이지 않는다).
    var visibleProgress: (done: Int, total: Int)? {
        let shown = [batches[.library], batches[.weekly]].compactMap { $0 }
        guard !shown.isEmpty else { return nil }
        return (shown.map(\.done).reduce(0, +), shown.map(\.total).reduce(0, +))
    }

    /// 진행이 멈춘 까닭. 잘 돌고 있으면 nil.
    var statusNote: String? {
        if let pausedUntil, pausedUntil > Date() {
            return "DBLP asked to slow down, resuming in \(max(1, Int(pausedUntil.timeIntervalSinceNow.rounded())))s"
        }
        if !isConnected { return lastPoll == nil ? "waiting for Chrome" : "open Chrome to continue" }
        return nil
    }

    // MARK: 넣기

    func add(_ ids: [Int64], purpose: Purpose) {
        let queued = Set(waiting.map(\.itemID)).union(inFlight.values.map(\.job.itemID))
        let fresh = ids.filter { !queued.contains($0) }
        guard !fresh.isEmpty else { return }
        waiting += fresh.map { Job(itemID: $0, purpose: purpose) }
        batches[purpose, default: Batch()].total += fresh.count
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    /// File → Check Library with DBLP…
    func checkLibrary(in window: NSWindow?) {
        let kinds: Set<String> = ["journalArticle", "conferencePaper", "preprint", "bookSection", "other"]
        let ids = LibraryStore.shared.items.filter { kinds.contains($0.type) && !$0.title.isEmpty }.map(\.id)
        add(ids, purpose: .library)
        let alert = NSAlert()
        alert.messageText = "Checking \(ids.count) papers with DBLP"
        let minutes = max(1, ids.count * 3 / 60)
        alert.informativeText = "Quillo looks each paper up in DBLP through the Save to Quillo extension in Chrome, about one paper "
            + "a second (around \(minutes) min). Empty fields are filled in. Where DBLP has a different value, or an arXiv paper "
            + "has been published, the paper’s info panel lets you choose. Nothing you entered is overwritten."
            + (isConnected ? "" : "\n\nOpen Chrome to start. The extension picks up the work within a minute.")
        alert.runModalOrSheet(for: window)
    }

    /// 앱을 켤 때와 몇 시간마다: 주간 확인을 켰고 7일이 지났으면 arXiv 논문을 넣는다.
    func scheduleWeekly() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in DBLPQueue.shared.startWeeklyIfDue() }
        }
        startWeeklyIfDue()
    }

    func startWeeklyIfDue() {
        guard Settings.checkPublishedWeekly, batches[.weekly] == nil,
              Settings.lastPublishedCheck.map({ Date().timeIntervalSince($0) >= 7 * 86400 }) ?? true else { return }
        let items = LibraryStore.shared.items
        guard !items.isEmpty else { return }
        let ids = items.filter { $0.type == "preprint" && !$0.title.isEmpty }.map(\.id)
        if ids.isEmpty { Settings.lastPublishedCheck = Date(); return }
        add(ids, purpose: .weekly)
    }

    // MARK: 확장과 주고받기

    /// GET /tasks: 확장이 받아 갈 주소들.
    func tasks(max count: Int) -> [[String: String]] {
        lastPoll = Date()
        // 확장이 받다가 멈췄으면(Chrome을 닫는 등) 다시 줄을 세운다.
        for (id, entry) in inFlight where Date().timeIntervalSince(entry.since) > 120 {
            inFlight[id] = nil
            waiting.insert(entry.job, at: 0)
        }
        if let pausedUntil, pausedUntil > Date() { return [] }
        var out: [[String: String]] = []
        while out.count < count, !waiting.isEmpty {
            var job = waiting.removeFirst()
            guard let item = LibraryStore.shared.items.first(where: { $0.id == job.itemID }),
                  let url = job.hit.flatMap({ DBLP.bibURL(key: $0.key) }) ?? DBLP.searchURL(title: item.title, firstAuthor: item.authors.first?.family) else {
                finish(job, changed: nil)
                continue
            }
            job.url = url
            let id = UUID().uuidString
            inFlight[id] = (job, Date())
            out.append(["id": id, "url": url.absoluteString])
        }
        return out
    }

    /// POST /task-result: 확장이 받은 내용. blocked면 DBLP의 봇 확인을 넘지 못한 것.
    func receive(id: String, status: Int, body: String, blocked: Bool, retryAfter: Int? = nil) async {
        guard var job = inFlight.removeValue(forKey: id)?.job else { Self.log("result for unknown task \(id)"); return }
        Self.log("result \(job.itemID) \(job.hit == nil ? "search" : "bib"): status \(status)\(blocked ? " blocked" : ""), \(body.count) chars: \(body.prefix(120).replacingOccurrences(of: "\n", with: " "))")
        // 확장이 보내지 않고 돌려준 일(요청 제한 뒤): 다시 줄 앞에.
        if status == -1 { waiting.insert(job, at: 0); return }
        if status == 429 {
            delay = min(delay * 2, 20_000)
            successes = 0
        } else if status == 200 {
            successes += 1
            if successes >= 15 { delay = max(2000, delay * 9 / 10); successes = 0 }
        }
        if blocked || status == 429 {
            waiting.insert(job, at: 0)
            pausedUntil = Date().addingTimeInterval(blocked ? 120 : Double(min(max(retryAfter ?? 60, 10), 600)))
            Self.log("pause \(Int(pausedUntil!.timeIntervalSinceNow))s, delay now \(delay) ms")
            NotificationCenter.default.post(name: Self.didChange, object: self)
            NSLog("%@", "Quillo DBLP: \(blocked ? "blocked by the bot check" : "rate limited"); pausing")
            return
        }
        guard status == 200, let item = LibraryStore.shared.items.first(where: { $0.id == job.itemID }) else {
            finish(job, changed: nil)
            return
        }
        if let hit = job.hit {
            // .bib을 받았다.
            await conclude(job, item: item, found: DBLP.metadata(hit, bib: BibTeXReader.fields(body)?.fields), key: hit.key)
            return
        }
        let preprint = DBLPCheck.isPreprint(item)
        let prefer = preprint ? "conferencePaper" : item.type
        let hits = DBLP.hits(Data(body.utf8))
        guard let hit = DBLP.match(hits, title: item.title, firstAuthor: item.authors.first?.family, prefer: prefer) else {
            Self.log("no match for \(item.id) “\(item.title)” among \(hits.count) hits: \(hits.prefix(3).map { "\($0.type) | \($0.title)" })")
            finish(job, changed: nil)
            return
        }
        // 학회 이름 전체와 개최 달은 .bib에만 있다. 빈 venue를 채우거나, 출판본을 알리거나,
        // 출판사 DOI 없이 날짜를 견줄 때만 받는다(DOI가 있으면 날짜는 CrossRef에서).
        let dateFromBib = DBLPCheck.dateNeedsCheck(item, year: hit.year) && DBLPCheck.publisherDOI(item) == nil
        if preprint || (item.venue ?? "").isEmpty || dateFromBib {
            job.hit = hit
            waiting.insert(job, at: 0)
            return
        }
        await conclude(job, item: item, found: DBLP.metadata(hit), key: hit.key)
    }

    private func conclude(_ job: Job, item: LibraryEntry, found: PaperMetadata, key: String) async {
        let store = LibraryStore.shared
        guard let library = store.library else { finish(job, changed: nil); return }
        // 출판사 DOI가 있고 날짜를 견줄 일이 있으면, 출판사가 등록한 날짜(CrossRef issued)를 기준으로 삼는다.
        // 예: ACM 학술지는 온라인 공개일(2015-12-22)이 공식 날짜이고 DBLP는 인쇄 권호 연도(2016)를 쓴다.
        var found = found
        if DBLPCheck.dateNeedsCheck(item, year: found.year), let doi = DBLPCheck.publisherDOI(item),
           let crossref = try? await MetadataLookup.crossref(doi: doi), let date = crossref.date {
            Self.log("crossref date for \(item.id): \(date) (DBLP \(found.date ?? "-"))")
            found.date = date
        }
        guard let updated = DBLPCheck.apply(found, key: key, to: item) else { Self.log("no change for \(item.id)"); finish(job, changed: nil); return }
        Self.log("update \(item.id) from \(key)")
        do {
            try library.update(item.id, with: updated, citationKey: item.citationKey)
            var entry = try library.item(item.id) ?? item
            // 확장으로 방금 저장한 arXiv 논문: 설정이 켜져 있으면 바로 출판본으로.
            if job.purpose == .saved, Settings.lookup.usePublishedVersion, DBLPCheck.record(of: entry)?.published != nil {
                try await applyPublished(to: entry, edit: false)
                entry = try library.item(item.id) ?? entry
            }
            store.didModify()
            finish(job, changed: (before: item, after: entry))
        } catch {
            NSLog("%@", "Quillo DBLP: could not update \(item.id): \(error)")
            finish(job, changed: nil)
        }
    }

    private func finish(_ job: Job, changed: (before: LibraryEntry, after: LibraryEntry)?) {
        guard var batch = batches[job.purpose] else { return }
        batch.done += 1
        if let changed {
            let record = DBLPCheck.record(of: changed.after)
            if record?.published != nil { batch.published.append(changed.after.id) }
            batch.differences += record?.differences.count ?? 0
            var before = PaperMetadata(changed.before), after = PaperMetadata(changed.after)
            before.fields[DBLPCheck.fieldKey] = nil
            after.fields[DBLPCheck.fieldKey] = nil
            if before != after { batch.filled += 1 }
        }
        batches[job.purpose] = batch
        NotificationCenter.default.post(name: Self.didChange, object: self)
        guard batch.done >= batch.total else { return }
        batches[job.purpose] = nil
        report(job.purpose, batch)
    }

    private func report(_ purpose: Purpose, _ batch: Batch) {
        switch purpose {
        case .saved: return
        case .weekly:
            Settings.lastPublishedCheck = Date()
            guard !batch.published.isEmpty else { return }
        case .library: break
        }
        let alert = NSAlert()
        let titles = batch.published.compactMap { id in LibraryStore.shared.items.first { $0.id == id }?.title }
        if purpose == .weekly {
            alert.messageText = titles.count == 1 ? "An arXiv paper in your library has been published"
                : "\(titles.count) arXiv papers in your library have been published"
        } else {
            alert.messageText = "Checked \(batch.total) papers with DBLP"
        }
        var lines: [String] = []
        if purpose == .library {
            lines.append("Filled in missing details for \(batch.filled) papers.")
            if batch.differences > 0 { lines.append("\(batch.differences) values differ from DBLP. Select a paper to compare them in the info panel.") }
        }
        if !titles.isEmpty {
            lines.append("Published versions found for:\n" + titles.prefix(8).map { "• " + $0 }.joined(separator: "\n")
                         + (titles.count > 8 ? "\n…and \(titles.count - 8) more" : ""))
        }
        alert.informativeText = lines.joined(separator: "\n\n")
        if !titles.isEmpty {
            alert.addButton(withTitle: "Update All")
            alert.addButton(withTitle: "Review One by One")
        }
        let window = NSApp.mainWindow
        alert.runModalOrSheet(for: window) { response in
            guard !titles.isEmpty, response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                for id in batch.published {
                    guard let entry = LibraryStore.shared.items.first(where: { $0.id == id }) else { continue }
                    try? await self.applyPublished(to: entry, edit: true)
                }
                LibraryStore.shared.didModify()
            }
        }
    }

    // MARK: 출판본

    /// 출판본으로 바꾼다. DOI가 있으면 CrossRef에서 학술지·학회 이름을 받아 쓴다(CrossRef는 앱에서 바로 받을 수 있다).
    /// edit이면 사용자가 고른 것으로 기록한다(뒤에 다시 채울 때 지킨다).
    func applyPublished(to entry: LibraryEntry, edit: Bool) async throws {
        guard let library = LibraryStore.shared.library, let published = DBLPCheck.record(of: entry)?.published else { return }
        let crossref = if let doi = published.doi { try? await MetadataLookup.crossref(doi: doi) } else { PaperMetadata?.none }
        guard let m = DBLPCheck.usePublished(in: entry, crossref: crossref) else { return }
        if edit { try library.edit(entry.id, to: m, citationKey: entry.citationKey) } else { try library.update(entry.id, with: m, citationKey: entry.citationKey) }
    }
}

extension NSAlert {
    func runModalOrSheet(for window: NSWindow?, then done: ((NSApplication.ModalResponse) -> Void)? = nil) {
        if let window { beginSheetModal(for: window) { done?($0) } } else { done?(runModal()) }
    }
}
