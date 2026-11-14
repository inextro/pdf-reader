# Quillo

**A free, open-source Mac app for keeping and reading papers.** Quillo is a paper library, a lighter Zotero, that
saves papers from Chrome, and a PDF reader that lets you highlight in any color you like. Papers open as tabs in
a reader window next to your library.

Quillo was two apps up to version 1.0.4: the library PaperLibrary and the reader PaperMark. PaperMark is now
built into Quillo. If you used PaperMark, delete `PaperMark.app`; Quillo brings over your colors, shortcuts, and
open files the first time it runs.

## Why

Highlighting a PDF on a Mac should be simple, but the common options each come with a catch:

| App | The catch |
|---|---|
| **Preview** (built in) | Free, but you cannot customize highlight colors. You get a small fixed set and no color picker. |
| **PDF Expert for Mac** | Annotation is a Premium feature (subscription or paid license) per its [pricing page](https://pdfexpert.com/pricing). The free version is mostly a viewer. |

Quillo's reader covers the part most readers need, for free: read, search, and highlight with your own
palette, then keep going on another device.

## Reading and highlighting

Drag over text and it is highlighted in your current color. Your highlights are saved into the PDF itself as
standard annotations, so they show up in PDF Expert on iPad and in other PDF readers too.


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
  shows the reference entry it points to. Quillo finds the entry by its number or author name, so the preview
  stays right even when the paper's link target is off. Links to figures, tables, and equations just jump. After
  following any link, press `⌘[` to come back where you were (`⌘]` goes forward again).
- **Table of contents in the sidebar.** It lists the PDF's sections and subsections with page numbers. Click one
  to jump there; the section you are reading stays highlighted as you scroll.
- **Customizable keyboard shortcuts** in **Settings → Reader** (`⌘,`).
- **Picks up where you left off.** Reopens the papers you had open, at the page you were reading.
- **Saves automatically** to the original file, and every change can be undone.

## Library and reader

Quillo has one window. The library sits at the front of the tab bar, and each PDF you open becomes a tab after
it. Double-click a paper to open its PDF in a new tab.

- Click **Library** in the tab bar or press `⌘L` to go back to the library. `⇧⌘[` and `⇧⌘]` move between tabs.
- `⌘W` closes the current PDF tab. Drag a tab to reorder it. Right-click a tab to close other tabs or show the file
  in Finder.
- The toolbar follows the tab: search and Add by Identifier in the library, highlighter, eraser, and colors in a PDF.
- The library and the PDF tabs each keep their own sidebar state.

The library keeps the bibliographic data in a local database and leaves the PDFs as plain files in a folder you
choose (for example in Google Drive).

- **Collections are folders.** Your workspace is a folder, and each collection is a folder inside it. A paper
  lives in one folder with its PDF, and can also appear in other collections as a reference (`⌥`-drag or
  **Add Reference**). Changes you make in Finder show up in the library.
- **Save from Chrome.** The **Save to Quillo** extension adds the paper on the current page, with its PDF, to the
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
- **Backup.** The library is also written as `Quillo.json` in your workspace folder.
- **Updates itself.** Once a day it checks GitHub for a new release and shows what's new, and **Install and
  Relaunch** updates it in place. Use **Quillo → Check for Updates…** any time, or turn off the daily check in Settings (`⌘,`). When
  an update changes the Chrome extension, Quillo asks you to click **Reload** on it in Chrome.

To install the Chrome extension, choose **Quillo → Install Chrome Extension…** and follow the steps. The
extension is not in the Chrome Web Store; it is loaded unpacked from a folder Quillo keeps up to date.

## Release notes

See [CHANGELOG.md](CHANGELOG.md) for what changed in each version.

## Works across devices

Quillo writes standard PDF `/Highlight` annotations (with `QuadPoints`, color, and an appearance
stream) directly into the file. There is no sidecar database and no account.

Put your PDFs in a synced folder (for example Google Drive for desktop, iCloud Drive, or Dropbox) and
open them from there. Quillo edits the file in place, the sync client uploads it, and the same
highlights appear on your other devices. Round-tripping with **PDF Expert on iPad** through Google
Drive has been tested in both directions. If a file changes on another device while it is open and
you have no unsaved edits, Quillo reloads it.

## Install

Requires macOS 14 (Sonoma) or later. Runs natively on Apple Silicon and Intel Macs.

1. Download `Quillo-<version>.zip` from the [latest release](https://github.com/inextro/pdf-reader/releases/latest).
2. Unzip it and move `Quillo.app` to your Applications folder.
3. The app is not notarized by Apple, so macOS blocks it the first time. Open it once, then go to
   **System Settings → Privacy & Security** and click **Open Anyway**.
   Alternatively, run `xattr -dr com.apple.quarantine /Applications/Quillo.app` in Terminal.
4. For Quillo's Chrome extension, choose **Quillo → Install Chrome Extension…** and follow the steps.

### Install with a coding agent

If you use Claude Code or another coding agent, you can ask it to "install Quillo from
github.com/inextro/pdf-reader". These are the steps for the agent. They need only the macOS command line tools
(`curl`, `ditto`), not `gh`.

```sh
# 1. Download the latest release and unzip it into a new, empty folder.
DIR="$(mktemp -d)"
cd "$DIR"
url="$(curl -fsSL https://api.github.com/repos/inextro/pdf-reader/releases/latest \
  | grep -o "https://[^\"]*/Quillo-[0-9.]*\.zip" | head -1)"
curl -fsSL -o Quillo.zip "$url"
ditto -x -k Quillo.zip .

# 2. Quit running copies, then move the app to /Applications (replacing older versions).
#    PaperLibrary is Quillo's name up to 1.0.4, and PaperMark is now built into Quillo.
osascript -e 'tell application id "com.inextro.paperlibrary" to quit' 2>/dev/null
osascript -e 'tell application id "com.inextro.papermark" to quit' 2>/dev/null
rm -rf /Applications/PaperLibrary.app /Applications/PaperMark.app /Applications/Quillo.app
ditto Quillo.app /Applications/Quillo.app
xattr -dr com.apple.quarantine /Applications/Quillo.app 2>/dev/null || true

# 3. Put the Chrome extension where Quillo keeps it up to date.
EXT="$HOME/Library/Application Support/PaperLibrary/ChromeExtension"
mkdir -p "$(dirname "$EXT")"
rm -rf "$EXT"
ditto /Applications/Quillo.app/Contents/Resources/ChromeExtension "$EXT"
open -g /Applications/Quillo.app
```

The agent can't load the Chrome extension for you, so do this once by hand. Open `chrome://extensions`, turn on
**Developer mode** (top right), click **Load unpacked**, and choose
`~/Library/Application Support/PaperLibrary/ChromeExtension` (press `⌘⇧G` in the dialog and paste the path).
Then pin **Save to Quillo** from the puzzle icon.

When Quillo opens for the first time, it asks you to choose your workspace folder or import your Zotero
library. You can't use Quillo until you do one of these. Then it asks once whether to become your default PDF
app. If you installed PaperLibrary 1.0.2 or earlier, run the same steps once more. PaperLibrary 1.0.3 and 1.0.4
update to Quillo by themselves.

### Default PDF app

Quillo asks once whether to become your default PDF app. If you agree, PDFs inside your workspace open in
Quillo, and every other PDF opens in Preview. This is handy for launchers like Raycast or Alfred, which always
use the system default app. Change it later with **Quillo → Default PDF App…**.

This replaces the separate PDFRouter app and PaperMark's default-app setting.

## Keyboard shortcuts

Reader shortcuts, except `Space`, `T`, and `Esc`, can be changed in **Settings → Reader** (`⌘,`).

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
| Show the library | `⌘L` |
| Back / forward (after following a link, a section, or a search result) | `⌘[` / `⌘]` |
| Zoom in / out / fit | `⌘=` / `⌘-` / `⌘0` |
| Undo / redo | `⌘Z` / `⇧⌘Z` |

Mouse:

- **Right-click an annotation** to translate, remove, or recolor it. Right-click a selection to translate it.
- **Click the selected color** in the toolbar to edit it in the color panel. `+` adds a new color,
  and right-clicking a color removes it.

## Limitations

- When Quillo saves a PDF, PDFKit rewrites the whole file. Unusual PDFs may come out slightly different
  (for example, metadata or structure that PDFKit does not preserve). Keep a copy of anything critical.
- There is no annotation-level merge. If you edit the same file on two devices before the sync
  finishes, the sync service decides which version wins (Google Drive keeps both as a conflict copy).
- macOS only. On iPad, use any reader that supports standard PDF annotations.
- When Quillo is the default PDF app, a PDF outside the workspace goes to Preview even if you choose
  **Open With → Quillo** in Finder. Open it with **File → Open PDF…** (`⌘O`) instead.

## Build from source

Needs the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not required.

```sh
./scripts/build-app.sh                  # build/Quillo.app (universal)
./scripts/build-app.sh --install        # also copy it to ~/Applications
./scripts/build-app.sh --zip            # also create build/Quillo-<version>.zip (and PaperLibrary-<version>.zip)
./scripts/build-app.sh --dev --install  # quick arm64 debug build for trying changes
swift run pmcheck /tmp/pmcheck          # run the annotation and library checks
```

To publish a release, bump `CFBundleShortVersionString` in `Resources/PaperLibrary/Info.plist`, add a matching
`## <version>` entry at the top of `CHANGELOG.md`, commit and push, then run `./scripts/release.sh`. It uploads
`Quillo-<version>.zip`, and the same app as `PaperLibrary-<version>.zip` so PaperLibrary 1.0.4 and earlier can
update in place.
Versions follow [Semantic Versioning](https://semver.org).

The code is Swift and PDFKit, organized as:

- `Sources/PaperMarkCore`: highlight geometry, merging, annotation hit testing, shortcut parsing, workspace path
  checks, and updates.
  This target has no UI, so `pmcheck` can test it.
- `Sources/PaperMarkLibrary`: the paper library (SQLite database, Zotero import, JSON backup).
  No UI either, so `pmcheck` tests it, including an import of `~/Zotero/zotero.sqlite` into a temporary database when it exists.
- `Sources/Reader`: the PDF reader, formerly the PaperMark app (document, reader window, toolbar, palette,
  shortcut settings, default-app routing).
- `Sources/PaperLibrary`: the Quillo app (library window, info panel, workspace sync, the local server the Chrome
  extension talks to, menus, and opening PDFs as tabs). The target and its bundle ID keep the old name PaperLibrary.
- `Extension/Chrome`: the "Save to Quillo" Chrome extension. `build-app.sh` puts it inside Quillo.app.
- `Sources/pmcheck`: a command-line check that creates PDFs, annotates them, saves, and reloads.

## License

[MIT](LICENSE)
