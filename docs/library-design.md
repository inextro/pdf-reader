# 라이브러리 설계 — Phase 1

상태: 초안 (2026-10-29), 브랜치 `feature/library`

> 2026-10-29 변경: 라이브러리를 PaperMark의 탭으로 넣지 않고 **별도 앱 PaperLibrary**(임시 이름)로 만든다.
> PaperLibrary가 중심 앱이고 PDF는 PaperMark로 연다. §3, §6, §8, §9를 이에 맞춰 고쳤다.

## 1. 목표와 범위

Zotero를 대체하는 논문 라이브러리 앱 PaperLibrary(임시 이름, bundle ID `com.inextro.paperlibrary`)를 만든다. 서지 관리는 PaperLibrary가 맡고, PDF는 지금의 PaperMark가 리더로서 연다. 두 앱은 한 Swift 패키지에서 빌드하고 라이브러리 코드(`PaperMarkLibrary`)를 함께 쓴다. 쓸 만한 프로토타입이 나오면 v1.0.0으로 릴리스한다.

두 앱으로 나눈 이유: PaperMark는 Finder에서 아무 PDF나 여는 독립 리더로 남고, iPad에서도 라이브러리 앱이 PDF를 PDF Expert로 넘기는 같은 구조가 된다. 리더가 라이브러리를 알아야 할 때(P2의 Info 등)는 같은 DB를 읽는다.

전체 단계:

| 단계 | 내용 |
|---|---|
| **P1** | 로컬 DB, Zotero 가져오기, Library 화면(목록·컬렉션·태그·검색·PDF 열기), JSON 백업 |
| P2 | DOI/arXiv로 추가하고 메타데이터 자동 채우기, 항목 편집, BibTeX 내보내기 |
| P3 | 브라우저 확장(`papermark://add?doi=`), 중복 탐지, arXiv→출판본 갱신 |
| P4 | 라이브러리 전체 본문 검색, cited-by, Notion Papers DB 연동 |

**P1 완료 기준:** Zotero를 열지 않고도 지금 Zotero 라이브러리(서지 230, 컬렉션 14, PDF 175)를 PaperLibrary에서 찾아보고 PDF를 PaperMark로 열 수 있다.

P1에서 하지 않는 것:

- 항목 추가·편집·삭제 (P2). P1의 라이브러리는 Zotero에서 가져온 내용을 읽기만 한다.
- BibTeX 내보내기 (P2). 다만 citation key는 P1에서 그대로 가져와 둔다.
- 동기화. 당분간 Zotero에서 고치고 다시 가져오는 방식으로 쓴다.
- iPad 앱. P1을 써 본 뒤 만들지 정한다. 다만 P1 설계는 iPad 앱을 나중에 붙일 수 있게 한다(§4.3).

### 1.1 기기와 동기화 전제 (2026-10-29)

- Mac은 MacBook 한 대, iPad에서는 지금 PDF Expert로 읽는다.
- 어느 기기에서 열든 최신 PDF(형광펜 포함)가 보여야 한다. PDF와 형광펜은 Drive의 같은 파일을 쓰므로 지금도 맞춰진다.
- iPad에서도 라이브러리 화면을 쓰고 싶다(Zotero를 iPad에서 못 쓰는 것이 불만 중 하나).
- Apple Developer Program(연 $99)에는 가입하지 않는다. 따라서 iCloud(CloudKit)는 쓰지 않고, 기기 간 동기화는 Drive의 파일로 한다. iPad 앱을 만들면 무료 Apple ID로 설치하고 7일 재서명은 AltStore/SideStore로 자동화한다.

## 2. 현재 구조와 Zotero 현황

### 2.1 앱 구조

- `PaperMarkCore`(UI 없는 로직), `PaperMark`(앱), `pmcheck`(실제 PDF로 확인하는 검증 도구). XCTest 타깃은 없다.
- PDF 하나가 `PMDocument`(NSDocument) 하나이고 창 하나다. 창들은 시스템 창 탭으로 묶인다(`tabbingMode = .preferred`).
- PDF가 없는 문서가 "New Tab"(시작 탭)이다. 사이드바에 작업 폴더의 파일 트리, 본문에 열기 안내를 보이고, 여기서 PDF를 열면 시작 탭은 닫힌다. 앱을 켜면 시작 탭을 먼저 열고 직전 파일들을 그 왼쪽에 다시 연다.
- 사이드바는 `SidebarViewController`의 세그먼트(Contents | Files)로 바꾼다.
- 열어 둔 파일과 마지막 페이지는 `Session`이 UserDefaults에 경로 기준으로 저장한다.
- 외부 의존성이 없다(SwiftPM 패키지 의존 0개).

### 2.2 Zotero 라이브러리 (`~/Zotero/zotero.sqlite`, 2026-10-29 확인)

| 항목 | 수 | 비고 |
|---|---|---|
| 서지 | 230 | conferencePaper 152, journalArticle 46, preprint 30, book 1, webpage 1 |
| PDF 첨부 | 175 | 모두 linked file(`attachments:archive/…`), 디스크에서 빠진 파일 0개 |
| PDF 있는 서지 | 174 | 1개는 PDF 2개, 56개는 PDF 없음 |
| 컬렉션 | 14 | 하위 컬렉션 11 |
| 태그 | 4 | 태그 연결 19 |
| 노트 | 19 | 모두 서지에 달린 child note |
| 지은이 연결 | 1,778 | 역할은 author, editor |
| 주석(Zotero 리더) | 0 | 형광펜은 PaperMark가 PDF 파일에 직접 쓴다 |

- 첨부 base 폴더: `~/Library/CloudStorage/GoogleDrive-…/My Drive/zotero` (Zotero `prefs.js`의 `extensions.zotero.baseAttachmentPath`).
- citation key: Zotero 7의 기본 필드 `citationKey`에 230개 모두 있다. Better BibTeX의 `better-bibtex/` 폴더에는 별도 key 데이터가 없다(`read-only.json`이 `[]`).
- `extra` 필드(109개)에는 `arXiv:2310.20453 [cs]`, `TLDR: …` 같은 텍스트가 있다.

PDF는 이미 Drive에 있으므로 옮기지 않는다. 메타데이터, 컬렉션, 태그, 노트, citation key만 가져온다.

## 3. 코드 구조

`Package.swift`에 UI 없는 `PaperMarkLibrary` 타깃과 앱 타깃 `PaperLibrary`를 추가한다. PaperMark는 바꾸지 않는다.

```swift
.target(name: "PaperMarkLibrary"),
.executableTarget(name: "PaperMark", dependencies: ["PaperMarkCore"]),
.executableTarget(name: "PaperLibrary", dependencies: ["PaperMarkLibrary"]),
.executableTarget(name: "pmcheck", dependencies: ["PaperMarkCore", "PaperMarkLibrary"]),
```

- 앱 번들: `./scripts/build-app.sh --library [--install]`이 `Resources/PaperLibrary/`의 Info.plist와 아이콘으로 `PaperLibrary.app`을 만든다. 아이콘은 `scripts/make-library-icon.swift`로 그린다.
- 앱 코드(`Sources/PaperLibrary`): `LibraryWindowController`(창, 툴바 검색), `LibrarySidebar`, `LibraryView`(표), `LibraryStore`(DB와 가져오기), `PaperMark`(PDF를 PaperMark로 열기).

| 파일 | 내용 |
|---|---|
| `PaperMarkLibrary/SQLite.swift` | 시스템 `SQLite3` 모듈 위의 얇은 래퍼(열기, prepare/bind/step, 트랜잭션). 외부 패키지는 쓰지 않는다 |
| `PaperMarkLibrary/Schema.swift` | 테이블 생성과 `PRAGMA user_version` 기반 마이그레이션 |
| `PaperMarkLibrary/Models.swift` | `Item`, `Creator`, `Attachment`, `Collection`, `Tag`, `Note` 값 타입 |
| `PaperMarkLibrary/Library.swift` | 조회 API(목록, 컬렉션별, 태그별, 검색, 경로로 항목 찾기) |
| `PaperMarkLibrary/ZoteroImport.swift` | Zotero DB 읽기와 매핑, upsert |
| `PaperMarkLibrary/Backup.swift` | JSON 내보내기 |
| `PaperMark/LibraryView.swift` | 항목 표(NSTableView) |
| `PaperMark/LibrarySidebar.swift` | 컬렉션·태그 목록(NSOutlineView) |

`PaperMarkLibrary`는 AppKit·PDFKit을 import하지 않아 `pmcheck`에서 창 없이 확인할 수 있다.

## 4. 저장

### 4.1 위치

- DB: `~/Library/Application Support/PaperLibrary/library.sqlite` (WAL 모드). Drive에 두면 다른 기기와 동기화하다 파일이 깨질 수 있어 Mac 로컬에 둔다.
- 백업: DB를 바꿀 때마다(P1에서는 가져오기 직후) JSON 하나를 Drive의 라이브러리 폴더에 쓴다(`PaperLibrary.json`). DB가 깨지거나 Mac을 바꾸면 이 파일로 되살린다(되살리기는 P2).
- PDF: 지금처럼 Drive 폴더. 위치는 **라이브러리 폴더**(기본값: Zotero base 폴더 `My Drive/zotero`) 기준 상대 경로로 저장한다. Drive 경로에는 계정 이메일이 들어가므로 절대 경로를 저장하면 기기나 계정이 바뀔 때 다 깨진다. 라이브러리 폴더는 UserDefaults에 두고 File > Change PDF Folder…로 바꿀 수 있게 한다.

### 4.2 스키마 (version 1)

```sql
CREATE TABLE items (
  id            INTEGER PRIMARY KEY,
  key           TEXT NOT NULL UNIQUE,     -- PaperMark 고유 키(UUID). 백업·동기화에서 항목을 가리킨다
  type          TEXT NOT NULL,            -- journalArticle | conferencePaper | preprint | book | webpage | other
  title         TEXT NOT NULL DEFAULT '',
  date          TEXT,                     -- Zotero 원문 그대로("2023-10-31", "2023" 등)
  year          INTEGER,                  -- 정렬·표시용으로 date에서 뽑는다
  venue         TEXT,                     -- publicationTitle / proceedingsTitle / repository 중 있는 것
  doi           TEXT,
  arxiv_id      TEXT,                     -- extra의 "arXiv:…" 또는 archiveID에서 뽑는다
  url           TEXT,
  abstract      TEXT,
  citation_key  TEXT UNIQUE,
  fields        TEXT NOT NULL DEFAULT '{}', -- 위 열에 없는 Zotero 필드(volume, pages, publisher, extra …) JSON
  added_at      TEXT NOT NULL,            -- ISO 8601. Zotero dateAdded를 이어받는다
  modified_at   TEXT NOT NULL,
  zotero_key    TEXT UNIQUE               -- 다시 가져올 때 같은 항목을 찾는 키
);
CREATE TABLE creators (
  item_id   INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  position  INTEGER NOT NULL,
  role      TEXT NOT NULL,                -- author | editor
  family    TEXT, given TEXT,             -- 기관 저자처럼 이름이 하나면 family만
  PRIMARY KEY (item_id, position)
);
CREATE TABLE attachments (
  id         INTEGER PRIMARY KEY,
  item_id    INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  path       TEXT NOT NULL,               -- 라이브러리 폴더 기준 상대 경로
  zotero_key TEXT UNIQUE
);
CREATE TABLE collections (
  id         INTEGER PRIMARY KEY,
  key        TEXT NOT NULL UNIQUE,      -- UUID. 항목의 key와 같은 용도
  parent_id  INTEGER REFERENCES collections(id) ON DELETE CASCADE,
  name       TEXT NOT NULL,
  zotero_key TEXT UNIQUE
);
CREATE TABLE collection_items (
  collection_id INTEGER NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
  item_id       INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  PRIMARY KEY (collection_id, item_id)
);
CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);
CREATE TABLE item_tags (
  item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  tag_id  INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  PRIMARY KEY (item_id, tag_id)
);
CREATE TABLE notes (
  id         INTEGER PRIMARY KEY,
  item_id    INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  html       TEXT NOT NULL,               -- Zotero 노트 HTML 그대로. 화면 표시는 P2
  zotero_key TEXT UNIQUE
);
CREATE INDEX attachments_item ON attachments(item_id);
CREATE INDEX attachments_path ON attachments(path);
CREATE TABLE deleted_items (            -- 지운 항목 기록. P1에서는 쌓기만 하고, 기기 간 동기화에서 삭제를 전파할 때 쓴다
  key        TEXT PRIMARY KEY,
  deleted_at TEXT NOT NULL
);
CREATE INDEX items_doi ON items(doi);
```

- 열로 뽑는 필드는 목록 표시·검색·중복 탐지(P3)에 쓰는 것만이다. 나머지는 `fields` JSON에 그대로 담아 BibTeX 내보내기(P2)에서 잃는 필드가 없게 한다.
- 읽기 상태, 별점 같은 열은 쓰는 기능이 생길 때 마이그레이션으로 추가한다.
- 본문 검색용 FTS 테이블은 P4에서 추가한다. P1 검색은 230개 규모라 `LIKE`로 충분하다.

### 4.3 iPad·동기화 준비

P1에서 동기화를 만들지는 않지만, 나중에 iPad 앱과 Drive 기반 동기화를 붙일 때 데이터를 고치지 않아도 되게 다음을 지킨다.

| 준비 | 나중에 답하는 질문 |
|---|---|
| 항목·컬렉션마다 UUID `key` | 두 기기의 항목이 같은 항목인가 |
| `modified_at`을 UTC ISO 8601로 기록 | 둘 다 고쳤으면 어느 쪽이 최신인가 |
| PDF는 라이브러리 폴더 기준 상대 경로 | 다른 기기에서도 같은 PDF를 찾는가 |
| `deleted_items`에 지운 key와 시각 | 지운 것을 다른 기기에도 반영해야 하는가 |
| JSON 백업은 내부 `id` 대신 `key`로 서로를 가리킨다 | 다른 기기의 DB에 그대로 읽히는가 |

- `PaperMarkLibrary`는 Foundation과 `SQLite3`만 쓴다. 둘 다 iPadOS에도 있어 iPad 앱에서 그대로 쓸 수 있다.
- 동기화 방식(Drive의 JSON을 원본으로 둘지, 변경 기록을 쌓을지)은 iPad 앱을 만들기로 할 때 정한다.

## 5. Zotero 가져오기

### 5.1 읽기

- `file:~/Zotero/zotero.sqlite?immutable=1`로 연다. Zotero가 켜져 있어도 잠금 없이 읽을 수 있고 Zotero DB는 절대 쓰지 않는다.
  - immutable 모드는 WAL에 아직 반영되지 않은 최근 변경을 못 볼 수 있다. Zotero를 끈 뒤 가져오기를 권하는 안내를 띄운다.
- 첨부 base 폴더는 Zotero 프로필의 `prefs.js`에서 `extensions.zotero.baseAttachmentPath`를 읽는다. 찾지 못하면 폴더 선택 창을 띄운다.
- `deletedItems`(휴지통)에 있는 항목은 가져오지 않는다.

### 5.2 매핑

| Zotero | PaperMark |
|---|---|
| `items.key` | `zotero_key` |
| itemType | `type` (위 다섯 종류 밖은 `other`) |
| title, date, DOI, url, abstractNote, citationKey | 같은 이름의 열 |
| publicationTitle / proceedingsTitle / repository | `venue` (앞에서부터 있는 것) |
| extra의 `arXiv:XXXX`, 또는 archiveID `arXiv:XXXX` | `arxiv_id` |
| 그 밖의 필드 | `fields` JSON |
| dateAdded, dateModified | `added_at`, `modified_at` |
| itemCreators (orderIndex 순) | `creators` |
| itemAttachments, `attachments:` 접두어 | `attachments.path` (접두어를 떼고 base 기준 상대 경로) |
| collections(+parentCollectionID), collectionItems | `collections`, `collection_items` |
| tags, itemTags | `tags`, `item_tags` |
| itemNotes (child) | `notes` |

- PDF가 아닌 첨부, 저장 방식이 linked file이 아닌 첨부(Zotero storage 안 파일)는 지금 라이브러리에 없다. 만나면 건너뛰고 가져오기 결과에 개수를 보인다.

### 5.3 다시 가져오기

P1 동안은 Zotero에서 고치고 다시 가져오는 방식으로 쓰므로, 가져오기를 여러 번 해도 결과가 같아야 한다.

- `zotero_key`로 같은 항목을 찾아 갱신(upsert)하고, 없으면 새로 만든다. P1에는 PaperLibrary에서 편집하는 기능이 없으므로 **Zotero 내용이 이긴다**.
- Zotero에서 지운 항목(이번 가져오기에 없는 `zotero_key`)은 PaperLibrary에서도 지운다.
- 컬렉션 구성, 태그 연결은 매번 Zotero 기준으로 다시 맞춘다.
- 전체를 트랜잭션 하나로 처리한다. 중간에 실패하면 이전 상태 그대로다.
- P2에서 편집이 생기면 규칙을 바꿔야 한다(§8 질문 2).

### 5.4 실행

- 메뉴 File > Import from Zotero…. 백그라운드에서 돌리고 끝나면 결과(서지·PDF·컬렉션·태그·노트 수, 건너뛴 것)를 시트로 보인다.

## 6. 화면

### 6.1 라이브러리 창

PaperLibrary를 켜면 라이브러리 창 하나가 뜬다. 논문을 더블클릭하면 PaperMark가 그 PDF를 연다(이미 켜져 있으면 PaperMark 창에 탭으로 붙는다).

```
[PaperLibrary]                                      [PaperMark]
┌──────────────────┬──────────────────────────┐     ┌ PaperA.pdf ┬ PaperB.pdf ┐
│ LIBRARY          │ 🔍 search                │     │                         │
│   All Items      │ Title        Authors Year│ ──▶ │      PDF                │
│   Unfiled        │ A ConvNet…   Liu…    2022│     │                         │
│ COLLECTIONS      │ TALLRec…     Bao…    2023│     │                         │
│   ▸ main         │ …                        │     │                         │
│ TAGS             │                          │     │                         │
│   /Completed     │                          │     │                         │
└──────────────────┴──────────────────────────┘     └─────────────────────────┘
```

- 창을 닫아도 앱은 남고, Dock 아이콘이나 Window > Library(⌘0)로 다시 연다.
- 라이브러리가 비어 있으면(가져오기 전) 본문에 "Import from Zotero…" 버튼을 보인다.
- 메뉴: File > Import from Zotero…(⇧⌘I), File > Change PDF Folder…, Edit > Find…(⌘F, 툴바 검색창).

### 6.2 사이드바

- All Items, Unfiled, 컬렉션 트리, 태그 목록. 고르면 오른쪽 표를 거른다. 펼침 상태를 기억한다.

### 6.3 항목 표

- 열: Title, Authors(첫 저자 성 + "et al.", 둘이면 "A & B"), Year, Venue, Added. 머리글을 눌러 정렬하고 열 너비·순서·정렬을 기억한다.
- 검색창: 제목, 저자, venue, citation key, DOI에서 찾는다. 입력하는 대로 거른다.
- 더블클릭·Return: PDF를 PaperMark로 연다(`NSWorkspace.open(_:withApplicationAt:)`). PaperMark가 없으면 기본 앱으로 열지 묻는다. PDF가 둘 이상이면 첫 번째를 연다.
- PDF가 없는 항목은 글자를 흐리게 보이고, 더블클릭하면 DOI/URL을 브라우저로 연다.
- PDF 파일이 디스크에 없으면 경고 아이콘을 보이고 열 때 알린다.
- 오른쪽 클릭: Open PDF, Show in Finder, Copy Citation Key, Copy DOI, Open DOI/URL.
- 선택한 항목의 상세(초록, 전체 저자, 노트)는 P1에서 툴팁으로만 보인다. 상세 패널은 P2.

### 6.4 리더와의 연결

- PaperMark는 P1에서 바꾸지 않는다. Finder에서 PDF를 열면 지금처럼 단독 리더로 연다(pdf-router·PDF Expert 호환 유지).
- 열린 PDF가 라이브러리 항목인지는 경로로 찾는다(`attachments_path` 인덱스). P1에서는 쓰는 곳이 없고 API만 만든다. P2에서 PaperMark가 같은 DB를 읽기 전용으로 열어 Info 세그먼트, 읽기 상태에 쓴다.
- `Session`의 마지막 페이지는 지금처럼 경로 기준으로 둔다.

## 7. 검증

XCTest 대신 지금처럼 `pmcheck`에 라이브러리 검사를 더한다(GUI 없이 실행).

- **합성 Zotero DB:** 검사 안에서 Zotero 스키마의 필요한 테이블만 가진 작은 sqlite를 만들어 가져오기 → 매핑·하위 컬렉션·삭제 항목 제외·다시 가져오기(같은 결과, 지운 항목 반영)를 확인한다.
- **실제 Zotero DB:** `~/Zotero/zotero.sqlite`가 있으면 임시 폴더의 DB로 가져와 개수(서지 230, PDF 175, 컬렉션 14, citation key 230)와 PDF 경로가 모두 실제 파일을 가리키는지 확인한다. 없으면 건너뛴다.
- **마이그레이션:** 빈 DB에서 version 1을 만들고 다시 열어도 그대로인지 확인한다.
- **UI:** PaperLibrary에서 컬렉션 거르기, 검색, PaperMark로 PDF 열기를 확인한다. 테스트 창은 화면 밖에 두고 앞으로 가져오지 않는다.

## 8. 정할 것

> 2026-10-29: 1은 별도 앱 PaperLibrary로 정했다(사용자 결정). 3, 4는 이 초안의 제안대로 정했다:
> 라이브러리 폴더는 Zotero 첨부 base 폴더, 노트는 가져와 두기만 한다. 바꾸려면 알려 주면 된다.


1. ~~**Library 자리:** PaperMark 안의 탭으로 둘지, 별도 라이브러리 창을 둘지.~~ → 별도 앱 PaperLibrary(§6.1).
2. **다시 가져오기 규칙:** P1은 Zotero가 이긴다. P2에서 PaperLibrary 편집이 생기면 (a) 그 시점에 Zotero 가져오기를 끝내고 PaperLibrary만 쓴다, (b) PaperLibrary에서 고친 항목은 다시 가져올 때 건너뛴다 중 하나를 골라야 한다. Zotero를 완전히 떠나는 시점을 정하면 (a)가 가장 단순하다.
3. **라이브러리 폴더:** Zotero base 폴더(`My Drive/zotero`)를 그대로 라이브러리 폴더로 쓸지, 새 폴더를 만들지. 새 PDF를 넣을 곳(P2)도 여기로 정해진다.
4. **노트:** Zotero 노트 19개를 HTML 그대로 가져와 두기만 하고 표시는 P2로 미루는 것으로 충분한지.
5. **앱 이름:** 개발 중에는 PaperLibrary를 쓴다. 정식 이름은 v1.0.0 때 정하고, DB 폴더 이름(`Application Support/PaperLibrary`)과 백업 파일 이름도 그때 함께 옮긴다. 리더는 PaperMark 그대로.

## 9. 작업 순서

1. `PaperMarkLibrary` 타깃, SQLite 래퍼, 스키마 v1, `pmcheck` 마이그레이션 검사
2. Zotero 가져오기와 `pmcheck` 검사(합성 DB, 실제 DB)
3. 조회 API(컬렉션·태그·검색·경로)와 JSON 백업
4. PaperLibrary 앱: 라이브러리 창, 사이드바, 항목 표, PaperMark로 PDF 열기
5. File > Import from Zotero…, 빈 라이브러리 화면, File > Change PDF Folder…
6. 실제 라이브러리로 일주일 정도 써 보고 P2 범위 확정
