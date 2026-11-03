# PaperMark and PaperLibrary

**Free, open-source Mac apps for reading and keeping papers.** PaperMark is a PDF reader that lets you highlight
in any color you like. PaperLibrary is a paper library, a lighter Zotero, that saves papers from Chrome and opens
them in PaperMark.

## PaperMark

PaperMark is a small, native Mac app for reading and marking up papers. Drag over text and it is
highlighted in your current color. Your highlights are saved into the PDF itself as standard
annotations, so they show up in PDF Expert on iPad and in other PDF readers too.

It comes with **PaperLibrary**, a companion app that keeps your papers' bibliographic data, collections, and tags,
and opens each paper in PaperMark. See [PaperLibrary](#paperlibrary) below.

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
- **Preview citations.** Rest the pointer on a citation link, such as `[23]` or `Park et al., 2023`, and a popover
  shows the reference entry it points to. PaperMark finds the entry by its number or author name, so the preview
  stays right even when the paper's link target is off. Links to figures, tables, and equations just jump. After
  following any link, press `⌘[` to come back where you were (`⌘]` goes forward again).
- **Sidebar with the table of contents or a file tree.** The Contents tab lists the PDF's sections and
  subsections with page numbers. Click one to jump there; the section you are reading stays highlighted as you
  scroll. The Files tab shows the folders and PDFs around the current file, like an IDE explorer. Move up a level or pick any root folder, and double-click to open.
  The tab bar's `+` opens a new tab that starts on the file tree. Closing the last PDF tab leaves this tab open
  instead of closing the window.
- **Customizable keyboard shortcuts** (`⌘,`).
- **Picks up where you left off.** Reopens the files you had open, at the page you were reading, next to
  a tab showing your working folder's file tree. The working folder is the file tree's root folder; on
  first launch PaperMark asks you to choose one.
- **Saves automatically** to the original file, and every change can be undone.
- **Updates itself.** Once a day PaperMark checks GitHub for a new release and shows what's new. Click
  **Install and Relaunch** to update in place, or use **PaperMark → Check for Updates…** any time. Turn off the
  daily check in Settings (`⌘,`).

## PaperLibrary

PaperLibrary is a paper library app, built as a lighter replacement for Zotero. It keeps the bibliographic data
in a local database and leaves the PDFs as plain files in a folder you choose (for example in Google Drive).
Double-click a paper to read it in PaperMark.

- **Collections are folders.** Your workspace is a folder, and each collection is a folder inside it. A paper
  lives in one folder with its PDF, and can also appear in other collections as a reference (`⌥`-drag or
  **Add Reference**). Changes you make in Finder show up in the library.
- **Save from Chrome.** The **Save to PaperLibrary** extension adds the paper on the current page, with its PDF, to the
  collection selected in the sidebar. It reads the page's metadata and fills in the rest from CrossRef and arXiv.
  If the paper is already in the library, it asks before updating it.
- **Add by DOI or arXiv ID** (`⇧⌘N`).
- **Import from Zotero**, including collections, tags, notes, and Better BibTeX citation keys.
- **Reading status.** Click the status pill in the Tags column to switch between To Do, In Process, Verified, and
  Completed. New papers start as To Do. Change the list in **Settings → Menu → Status tags**. Create, rename,
  and delete tags by right-clicking them in the sidebar.
- **Fix metadata in place.** Click any field in the info panel to edit it, like in Zotero. Fields you edit are
  remembered and not overwritten when the paper is saved again from the browser.
- **Copy citations** in APA, ACM, or IEEE style (`⇧⌘C`), or copy the citation key or DOI.
- **Backup.** The library is also written as `PaperLibrary.json` in your workspace folder.

To install the Chrome extension, choose **PaperLibrary → Install Chrome Extension…** and follow the steps. The
extension is not in the Chrome Web Store; it is loaded unpacked from a folder PaperLibrary keeps up to date.

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
   For the library app, also download `PaperLibrary-<version>.zip`.
2. Unzip it and move `PaperMark.app` (and `PaperLibrary.app`) to your Applications folder.
3. The apps are not notarized by Apple, so macOS blocks them the first time. Open each one once, then go to
   **System Settings → Privacy & Security** and click **Open Anyway**.
   Alternatively, run `xattr -dr com.apple.quarantine /Applications/PaperMark.app` in Terminal.
4. For PaperLibrary's Chrome extension, choose **PaperLibrary → Install Chrome Extension…** and follow the steps.

### Install with a coding agent

If you use Claude Code or another coding agent, you can ask it to "install PaperMark and PaperLibrary from
github.com/inextro/pdf-reader". These are the steps for the agent. They need only the macOS command line tools
(`curl`, `ditto`), not `gh`.

```sh
# 1. Download the latest release and unzip it into a new, empty folder.
DIR="$(mktemp -d)"
cd "$DIR"
for app in PaperMark PaperLibrary; do
  url="$(curl -fsSL https://api.github.com/repos/inextro/pdf-reader/releases/latest \
    | grep -o "https://[^\"]*/$app-[0-9.]*\.zip" | head -1)"
  curl -fsSL -o "$app.zip" "$url"
  ditto -x -k "$app.zip" .
done

# 2. Quit running copies, then move the apps to /Applications (replacing older versions).
osascript -e 'tell application "PaperLibrary" to quit' -e 'tell application "PaperMark" to quit' 2>/dev/null
for app in PaperMark PaperLibrary; do
  rm -rf "/Applications/$app.app"
  ditto "$app.app" "/Applications/$app.app"
  xattr -dr com.apple.quarantine "/Applications/$app.app" 2>/dev/null || true
done

# 3. Put the Chrome extension where PaperLibrary keeps it up to date.
EXT="$HOME/Library/Application Support/PaperLibrary/ChromeExtension"
mkdir -p "$(dirname "$EXT")"
rm -rf "$EXT"
ditto /Applications/PaperLibrary.app/Contents/Resources/ChromeExtension "$EXT"
open -g /Applications/PaperLibrary.app
```

The agent can't load the Chrome extension for you, so do this once by hand. Open `chrome://extensions`, turn on
**Developer mode** (top right), click **Load unpacked**, and choose
`~/Library/Application Support/PaperLibrary/ChromeExtension` (press `⌘⇧G` in the dialog and paste the path).
Then pin **Save to PaperLibrary** from the puzzle icon.

When PaperLibrary opens for the first time, it asks you to choose your workspace folder or import your Zotero
library. You can't use PaperLibrary until you do one of these. PaperMark asks once whether to become your
default PDF app. Later updates of PaperMark install from inside the app. To update
PaperLibrary, run the same steps again and click **Reload** on the extension in Chrome.

### Default PDF app

If you use PaperLibrary, PaperMark asks once whether to become your default PDF app. If you agree, PDFs inside
your PaperLibrary workspace open in PaperMark, and every other PDF opens in Preview. This is handy for
launchers like Raycast or Alfred, which always use the system default app. Change it later with
**PaperMark → Default PDF App…**.

This replaces the separate PDFRouter app, which you can delete.

Without PaperLibrary, make PaperMark the default PDF app the usual way: select a PDF in Finder, press `⌘I`,
choose PaperMark under **Open with**, and click **Change All…**.

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
| Show or hide the sidebar | `⌘B` |
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
- When PaperMark is the default PDF app with a PaperLibrary workspace, a PDF outside the workspace goes to
  Preview even if you choose **Open With → PaperMark** in Finder. Open it from PaperMark's **File → Open…** instead.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.

```sh
./scripts/build-app.sh                  # build/PaperMark.app (universal)
./scripts/build-app.sh --install        # also copy it to ~/Applications
./scripts/build-app.sh --zip            # also create build/PaperMark-<version>.zip
./scripts/build-app.sh --library        # build/PaperLibrary.app (takes the same --install and --zip)
./scripts/build-app.sh --dev --install  # quick arm64 debug build for trying changes
swift run pmcheck /tmp/pmcheck          # run the annotation round-trip checks
swift scripts/make-icon.swift .         # redraw Resources/AppIcon.icns
```

To publish a release, bump `CFBundleShortVersionString` to the same version in `Resources/Info.plist` and
`Resources/PaperLibrary/Info.plist`, add a matching `## <version>` entry at the top of `CHANGELOG.md`, commit and
push, then run `./scripts/release.sh`. It uploads both apps' zips to one GitHub release.
Versions follow [Semantic Versioning](https://semver.org).

The code is Swift and PDFKit, organized as:

- `Sources/PaperMarkCore`: highlight geometry, merging, annotation hit testing, shortcut parsing, and
  default-app routing.
  This target has no UI, so `pmcheck` can test it.
- `Sources/PaperMarkLibrary`: the paper library (SQLite database, Zotero import, JSON backup).
  No UI either, so `pmcheck` tests it, including an import of `~/Zotero/zotero.sqlite` into a temporary database when it exists.
- `Sources/PaperMark`: the app (document, window, toolbar, palette, settings).
- `Sources/PaperLibrary`: the PaperLibrary app (library window, info panel, workspace sync, and the local server
  the Chrome extension talks to). It opens PDFs in PaperMark.
- `Extension/Chrome`: the "Save to PaperLibrary" Chrome extension. `build-app.sh --library` puts it inside
  PaperLibrary.app.
- `Sources/pmcheck`: a command-line check that creates PDFs, annotates them, saves, and reloads.

## License

[MIT](LICENSE)
