# 리더 합치기: PaperMark를 Quillo의 내장 리더로

상태: 구현 (2026-11-14), 1.0.5에서 이름 변경(PaperLibrary → Quillo)과 함께 배포

## 1. 목표

PaperMark를 별도 앱으로 두지 않고 Quillo 안의 리더로 넣는다. 앱은 Quillo 하나, Dock 아이콘도 하나다.

- 리더는 Quillo를 쓰는 사람만 쓴다. PaperMark를 따로 배포하는 것은 그만둔다.
- Quillo가 기본 PDF 앱이 되면 workspace 안의 PDF는 Quillo 리더로, 그 밖의 PDF는 Preview로 연다.
- 리더 기능(형광펜, 지우개, 번역, 인용 미리보기, 목차, 검색, 단축키 설정)은 지금 PaperMark와 같다.

하지 않는 것: 리더와 서지 정보를 잇는 새 기능(PDF 탭 옆의 정보 패널, 읽기 상태 등). 합친 뒤에 따로 정한다.

## 2. 창 구조: 한 창 + 서재 고정 칸 (사용자 결정)

> 처음에는 macOS 기본 탭으로 서재를 첫 탭에 두었다. 서재가 논문처럼 탭으로 보이고, 같은 탭 묶음에서는 사이드바 상태가
> 탭끼리 묶였다. 다음으로 서재를 따로 창으로 뺐는데 창이 둘로 나뉘었다. 모형으로 비교한 뒤 사용자 결정(2026-11-14)으로
> 탭 막대를 직접 그리고 서재를 맨 앞에 고정했다.

```
┌──────────────────────────────────────────────────────────┐
│ ● ● ●  ▤  Quillo · 159 items          ✨  [Search      ] ⓘ │  ← 툴바: 고른 칸의 것
│ [📚 Library] │ Attention….pdf │ LightGCN.pdf │             │  ← 탭 막대(직접 그림)
├──────────────────────────────────────────────────────────┤
│                   고른 칸의 내용(서재 또는 PDF)              │
└──────────────────────────────────────────────────────────┘
```

- 창은 하나(`TabbedWindowController`). 탭 막대는 툴바 바로 아래 titlebar accessory(`.bottom`)다. 툴바 줄 위(`.top`)에
  두면 툴바를 가려서 macOS 기본 탭과 같은 자리에 둔다.
- 서재 칸(`LibraryPane`)은 맨 앞에 고정이다. 아이콘과 이름, 닫기 없음, 구분선 뒤로 PDF 탭(`ReaderPane`)이 온다.
- 칸을 고르면 창의 내용 뷰, 툴바, 제목이 바뀐다. 툴바를 바꿀 때 AppKit이 창 크기를 바꾸므로 창 크기를 되돌린다.
- 메뉴 항목(target 없음)은 `supplementalTarget(forAction:sender:)`로 고른 칸에 간다. PDF 탭의 Save는 칸이 문서에 넘긴다.
- PDF 문서(`PMDocument`)는 창 컨트롤러 없이 탭으로 보인다. `makeWindowControllers`는 탭을 붙이기만 하고,
  `showWindows`가 그 탭을 고른다. 지난번 PDF는 `display: false`로 열고 탭만 붙여서 켤 때는 서재 칸이 앞에 있다.
- 단축키: ⌘L 서재 칸, ⌘W PDF 탭 닫기(서재 칸에서는 창 닫기), ⇧⌘W 창 닫기, ⇧⌘[ / ⇧⌘] 이전·다음 탭.
- 탭: 누르면 고르고, 끌면 순서를 바꾸고, ✕·가운데 버튼으로 닫는다. 오른쪽 클릭 메뉴: Close Tab, Close Other Tabs, Show in Finder.
- 창을 닫아도(빨간 버튼) 탭은 남는다. Dock 아이콘을 누르면 그대로 다시 보인다.
- 사이드바: 서재와 PDF 탭은 따로 접고 펴며 각자 상태를 기억한다. PDF 탭끼리는 같은 상태를 따른다(`readerSidebarCollapsed`).
  사이드바 버튼은 두 칸 모두 navigational 툴바 항목이라 신호등 옆 같은 자리에 있다.
- 아직 없는 것: 탭을 끌어내 새 창 만들기(두 논문 나란히 보기). 필요하면 따로 만든다.

## 3. 리더 사이드바

- Files 탭(폴더 트리)은 뺀다(사용자 결정). 리더 사이드바는 목차(Contents)만 둔다.
- 함께 없어지는 것: 작업 폴더(`fileTreeRoot`) 묻기, 빈 시작 탭, Drive 폴더 제안.

## 4. PDF 열기와 기본 PDF 앱

지금 PaperMark의 `DefaultPDFApp`과 `PDFRouting`을 Quillo로 옮긴다.

| 어디서 여나 | 동작 |
|---|---|
| 서재(더블클릭, 정보 패널의 PDF) | 항상 리더 탭으로 연다 |
| Finder, Raycast 등 (Quillo가 기본 PDF 앱) | workspace 안이면 리더 탭, 밖이면 Preview로 넘긴다 |
| Finder의 "다음으로 열기 > Quillo" | Quillo가 기본 앱이면 위와 같다(보낸 쪽이 Finder라 구별할 수 없다). 기본 앱이 아니면 리더 탭 |
| File > Open PDF… (⌘O) | 리더 탭으로 연다 |

- **처음 한 번 묻기:** workspace를 고른 뒤 "Quillo를 기본 PDF 앱으로 쓸까요? workspace 안의 PDF는 Quillo에서, 나머지는 Preview에서 열립니다"를 묻는다. Quillo 메뉴의 "Default PDF App…"으로 나중에 바꾼다.
- **넘기기만 하려고 켜졌을 때:** Quillo가 꺼져 있는데 workspace 밖 PDF만 받았으면 창을 띄우지 않고 Preview로 넘긴 뒤 다시 끈다(PaperMark의 0.5초 규칙 그대로). 이 경우 workspace 묻기, 업데이트 확인, Chrome 확장 안내도 하지 않는다.
- **workspace 밖 PDF의 판단:** 지금과 같이 workspace 폴더 경로로 판단한다(DB 조회 아님).

## 5. 메뉴와 단축키

두 앱의 메뉴를 하나로 합친다. 리더 전용 항목(Highlight 메뉴, Zoom, Go)은 PDF 탭에서만 켜지고 서재 칸에서는 흐리게 보인다(응답자 체인으로 자동).

- **Find…(⌘F):** 두 창 모두 `focusSearch(_:)`를 가져서 항목 하나로 탭에 맞게 동작한다.
- **Show Sidebar:** 리더는 ⌘B(`DocumentWindowController.toggleSidebar`), 서재는 ⌃⌘S(`NSSplitViewController.toggleSidebar`)였다. 셀렉터가 같아서 항목 하나로 합치고, 키는 리더 설정의 ⌘B를 따른다(서재도 ⌘B).
- **충돌: ⌘0.** 서재의 Window > Library와 리더의 Zoom to Fit이 겹쳐서 Library를 ⌘L로 바꿨다.
- **File 메뉴:** Open PDF…(⌘O), Open Recent, Add by Identifier…, Import from Zotero…, Change PDF Folder…, Close, Save.
- **툴바 모양:** 두 칸 모두 한 줄 툴바(unified). PDF 탭은 제목을 숨긴다(파일 이름은 탭에 보인다).
- 단축키 설정(⌘1–9 색, 형광펜 등)은 Quillo 설정 창의 새 탭 "Reader"로 옮긴다. 자동 업데이트 체크박스는 Quillo 것 하나만 둔다.

## 6. 설정과 세션 옮기기

Quillo 1.0.5가 처음 켤 때 한 번, PaperMark 설정(`com.inextro.papermark` 도메인)에서 아래 키를 Quillo 도메인으로 복사한다. Quillo에 이미 있는 키는 덮어쓰지 않는다. 복사했다는 표시(`didImportPaperMarkSettings`)를 남긴다.

| 키 | 내용 |
|---|---|
| `presets`, `currentColor`, `paletteVersion` | 형광펜 색 팔레트 |
| `highlightMode` | 형광펜 모드 켜짐 |
| `shortcuts` | 사용자 단축키 |
| `openFiles`, `lastPages` | 열려 있던 PDF와 파일마다 마지막 페이지 |
| `sidebarTab` | 리더 사이드바 탭(목차만 남으므로 필요 없으면 버린다) |

옮기지 않는 키: `checksForUpdates`, `lastUpdateCheck`, `skippedVersion`(Quillo 것을 쓴다), `fileTreeRoot`, `fileTreeExpanded`, `didAskWorkingFolder`, `didSuggestDriveFolder`(Files 탭과 함께 없어짐), `didAskDefaultPDFApp`(Quillo가 새로 묻는다).

세션: Quillo를 켜면 지난번에 열려 있던 PDF를 탭으로 되살리고 서재 칸을 앞에 둔다. 파일을 열면서 켜졌으면 그 PDF 탭을 고른다.

## 7. 기존 PaperMark.app의 마무리

PaperMark는 1.0.4를 마지막으로 배포하지 않는다(사용자 결정, 2026-11-14). 따로 쓰던 사람은 사용자 본인 외 1명이라 안내 앱을 만들지 않고 직접 알린다: PaperMark.app을 지우고 Quillo를 기본 PDF 앱으로 쓰면 된다. 릴리스에는 PaperMark zip을 올리지 않는다. PaperMark 1.0.4는 새 릴리스를 보면 업데이트 창에 릴리스 노트를 띄우고, Install을 누르면 zip이 없어 릴리스 페이지를 연다. 그래서 1.0.5 릴리스 노트 첫 줄에 "PaperMark is now built into Quillo. Delete PaperMark.app and use Quillo."를 쓴다. 이 창이 안내를 대신한다.

## 8. 코드 구조

| 지금 | 바꾼 뒤 |
|---|---|
| `Sources/PaperMark` (리더 앱) | `Sources/Reader`: 리더 모듈(문서, 창, 팔레트, 번역, 목차, 단축키, 색). AppDelegate, main, Files 탭, 시작 탭은 빼거나 Quillo로 옮긴다 |
| `Sources/PaperLibrary` (Quillo) | `Reader` 모듈을 쓴다. 메뉴, 열기 라우팅, 설정 옮기기, 세션 복원을 맡는다 |
| `PaperMarkCore` | 그대로(형광펜 계산, 링크, 라우팅, 업데이트) |

- 두 앱에 같은 이름의 `SettingsWindowController`가 있다. 리더 쪽은 설정 탭에 넣을 뷰(`ReaderSettingsView`)로 바꾼다.
- 리더의 `NSDocumentController`(`PMDocumentController`)를 Quillo의 문서 컨트롤러로 쓴다. Quillo의 서재는 문서가 아니므로 영향이 없다.
- `Info.plist`: Quillo에 PDF 문서 타입(`CFBundleDocumentTypes`, `com.adobe.pdf`, Viewer/Editor)을 넣는다. 지금 PaperMark의 항목을 옮긴다.
- `build-app.sh`는 Quillo만 만든다(`--library`는 받아도 무시). `release.sh`: zip 두 개(Quillo, PaperLibrary 호환).

## 9. 검증

- `pmcheck`: 형광펜·링크 검사는 `PaperMarkCore`에 있어 그대로 돈다. 더할 것: 설정 옮기기(가짜 PaperMark 도메인에서 복사, 이미 있는 키는 유지), 열기 라우팅 표(4절)의 경우마다 열기·넘기기 판정.
- 창과 탭: 사용자 Mac에서 직접 써 보며 확인한다.
- 실제 앱: 마지막에 사용자 Mac에 설치해서 확인한다.

## 10. 정한 것 (2026-11-14)

1. ⌘0은 리더의 Zoom to Fit으로 두고, Window > Library는 ⌘L로 바꾼다(서재 칸으로).
2. 창 하나에 탭 막대를 직접 그리고 서재를 맨 앞에 고정한다(2절). ⌘W는 PDF 탭을 닫는다.
3. PaperMark 안내 앱은 만들지 않는다(7절).

## 11. 작업 순서

1. `Sources/PaperMark` → `Sources/Reader` 모듈로 옮기고 앱 부분을 떼어 낸다. Files 탭과 시작 탭을 뺀다.
2. Quillo에서 리더 탭 열기(서재 → 리더), 탭 규칙(2절), 메뉴 합치기(5절).
3. 기본 PDF 앱과 열기 라우팅(4절), 넘기기만 할 때 창 없이 끄기.
4. 설정·세션 옮기기(6절), 설정 창의 Reader 탭.
5. `build-app.sh`·`release.sh`, README, CHANGELOG.
6. `pmcheck`과 화면 밖 확인, 사용자 Mac에 설치해서 확인 → 1.0.5 배포(사용자 지시 때).
