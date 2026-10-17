# PaperMark

**A free, open-source PDF reader for macOS that lets you highlight in any color you like.**

PaperMark is a small, native Mac app for reading and marking up papers. Drag over text and it is
highlighted in your current color. Your highlights are saved into the PDF itself as standard
annotations, so they show up in PDF Expert on iPad and in other PDF readers too.

## Why

Highlighting a PDF on a Mac should be simple, but the common options each come with a catch:

| App | The catch |
|---|---|
| **Preview** (built in) | Free, but you cannot customize highlight colors. You get a small fixed set and no color picker. |
| **PDF Expert for Mac** | Annotation is a Premium feature (subscription or paid license) per its [pricing page](https://pdfexpert.com/pricing). The free version is mostly a viewer. |

PaperMark covers the part most readers need, for free: read, search, and highlight with your own
palette, then keep going on another device.

## Features

- **Highlight with your own colors.** Pick from a preset palette with `⌘1`–`⌘9`, click the selected
  color again to change it, or add new colors. The default palette uses four of PDF Expert's highlight colors
  (pink, blue, yellow, purple).
- **Highlight mode.** Turn it on and every drag highlights immediately. No toolbar trips.
- **Snaps to whole words.** A drag that ends mid-word extends to the word boundary, but stops at
  punctuation, so a typo like `results.In` still highlights just `results`. It also stops before a
  superscript citation number, so dragging over `replay²¹⁻²³` highlights just `replay`. Double-clicking
  highlights the whole word without surrounding quotes, so double-clicking `‘t-SNE’` highlights `t-SNE`. A bracket you drag over
  pulls in its partner, so dragging `(word` highlights `(word)`.
- **Clean overlaps.** Highlighting over an existing highlight merges them into one layer instead of
  stacking darker and darker color.
- **Eraser.** Hold `Space` (or toggle eraser mode) and click or rub over annotations to remove them.
- **Works with annotations from other apps.** Remove or recolor highlights, underlines, strikethroughs,
  pen drawings, notes, and shapes made in PDF Expert or elsewhere (right-click on them).
- **Translate sentences, not just words.** Hold `T` while dragging over text, press `⌘T` on a
  selection, or right-click a highlight. Uses Apple's on-device Translation (macOS 14.4+), so it is
  free, private, and adds nothing to the app size. Hyphenated line breaks are joined before translating.
- **Search** with next/previous result navigation.
- **Preview citations and figure references.** Rest the pointer on a link inside the paper, such as `[23]` or
  `Fig. 3`, and a popover shows the reference entry or figure it points to. Click to jump there, then `⌘[` to come
  back where you were (`⌘]` goes forward again).
- **Sidebar with the table of contents or a file tree.** The Contents tab lists the PDF's sections and
  subsections with page numbers. Click one to jump there; the section you are reading stays highlighted as you
  scroll. The Files tab shows the folders and PDFs around the current file, like an IDE explorer. Move up a level or pick any root folder, and double-click to open.
  The tab bar's `+` opens a new tab that starts on the file tree.
- **Customizable keyboard shortcuts** (`⌘,`).
- **Picks up where you left off.** Reopens the files you had open, at the page you were reading, next to
  a tab showing your working folder's file tree. The working folder is the file tree's root folder; on
  first launch PaperMark asks you to choose one.
- **Saves automatically** to the original file, and every change can be undone.

## Release notes

See [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

## Works across devices

PaperMark writes standard PDF `/Highlight` annotations (with `QuadPoints`, color, and an appearance
stream) directly into the file. There is no sidecar database and no account.

Put your PDFs in a synced folder (for example Google Drive for desktop, iCloud Drive, or Dropbox) and
open them from there. PaperMark edits the file in place, the sync client uploads it, and the same
highlights appear on your other devices. Round-tripping with **PDF Expert on iPad** through Google
Drive has been tested in both directions. If a file changes on another device while it is open and
you have no unsaved edits, PaperMark reloads it.

## Install

Requires macOS 14 (Sonoma) or later. Runs natively on Apple Silicon and Intel Macs.

1. Download `PaperMark-<version>.zip` from the [latest release](https://github.com/inextro/pdf-reader/releases/latest).
2. Unzip it and move `PaperMark.app` to your Applications folder.
3. The app is not notarized by Apple, so macOS blocks it the first time. Open it once, then go to
   **System Settings → Privacy & Security** and click **Open Anyway**.
   Alternatively, run `xattr -dr com.apple.quarantine /Applications/PaperMark.app` in Terminal.

To make it the default PDF app, select a PDF in Finder, press `⌘I`, choose PaperMark under
**Open with**, and click **Change All…**.

### Companion app: PDFRouter

[PDFRouter](https://github.com/inextro/pdf-router) takes the default PDF app slot and opens each PDF
in an app chosen by where the file lives: PDFs in your Zotero attachment folders or in folders you
choose go to PaperMark, and everything else goes to Preview. This is handy for launchers like Raycast or Alfred, which always use
the system default app.

## Keyboard shortcuts

All shortcuts except `Space`, `T`, and `Esc` can be changed in **Settings** (`⌘,`).

| Action | Shortcut |
|---|---|
| Highlight the selection (when highlight mode is off) | `⌘D` |
| Toggle highlight mode | `⇧⌘D` |
| Choose color 1–9 | `⌘1` – `⌘9` |
| Erase while held | `Space` |
| Toggle eraser mode / turn it off | `⇧⌘E` / `Esc` |
| Translate while dragging | hold `T` |
| Translate the selection | `⌘T` |
| Find / next / previous result | `⌘F` / `⌘G` or `Return` / `⇧⌘G` or `⇧Return` |
| Show or hide the sidebar | `⌃⌘S` |
| Back / forward (after following a link, a section, or a search result) | `⌘[` / `⌘]` |
| Zoom in / out / fit | `⌘=` / `⌘-` / `⌘0` |
| Undo / redo | `⌘Z` / `⇧⌘Z` |

Mouse:

- **Right-click an annotation** to translate, remove, or recolor it. Right-click a selection to translate it.
- **Click the selected color** in the toolbar to edit it in the color panel. `+` adds a new color,
  and right-clicking a color removes it.

## Limitations

- When PaperMark saves, PDFKit rewrites the whole file. Unusual PDFs may come out slightly different
  (for example, metadata or structure that PDFKit does not preserve). Keep a copy of anything critical.
- There is no annotation-level merge. If you edit the same file on two devices before the sync
  finishes, the sync service decides which version wins (Google Drive keeps both as a conflict copy).
- macOS only. On iPad, use any reader that supports standard PDF annotations.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.

```sh
./scripts/build-app.sh                  # build/PaperMark.app (universal)
./scripts/build-app.sh --install        # also copy it to ~/Applications
./scripts/build-app.sh --zip            # also create build/PaperMark-<version>.zip
swift run pmcheck /tmp/pmcheck          # run the annotation round-trip checks
swift scripts/make-icon.swift .         # redraw Resources/AppIcon.icns
```

To publish a release, bump `CFBundleShortVersionString` in `Resources/Info.plist`, add a matching
`### <version>` entry under Release notes, commit and push, then run `./scripts/release.sh`.
Versions follow [Semantic Versioning](https://semver.org).

The code is Swift and PDFKit, organized as:

- `Sources/PaperMarkCore`: highlight geometry, merging, annotation hit testing, and shortcut parsing.
  This target has no UI, so `pmcheck` can test it.
- `Sources/PaperMark`: the app (document, window, toolbar, palette, settings).
- `Sources/pmcheck`: a command-line check that creates PDFs, annotates them, saves, and reloads.

## License

[MIT](LICENSE)
