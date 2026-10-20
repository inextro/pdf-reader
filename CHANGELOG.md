# Changelog

## 0.7.0

- New: After you click a link to a citation, figure, or table, a **Back to p. N** button appears at the bottom.
  Click it to return to where you were. Forward takes you to the link target again.
- New: The mouse back and forward buttons go back and forward, including MX Master buttons set up in
  Logi Options+.
- Improved: Citation previews show the whole reference entry, even when it continues in the next column or on
  the next page. Entries with very long author lists are shortened in the middle.
- Improved: Previews appear for more citations, such as split author–year citations and `Theorem [10]`.
  Links to sections, the appendix, and equations no longer show a wrong preview.
- Fix: Internal links no longer show a "Go to page N" tooltip.

## 0.6.0

- New: PaperMark checks for a new version once a day and shows what's new. Click **Install and Relaunch** to
  update in place, without downloading a zip or approving the app again in Privacy & Security. Choose **Later**
  or **Skip This Version** to wait. **PaperMark → Check for Updates…** checks right away, and Settings (`⌘,`)
  can turn off the daily check.
- Note: Versions before 0.6.0 can't update themselves, so install this version by hand once.

## 0.5.0

- New: Rest the pointer on a citation, such as `[23]` or `Park et al., 2023`, to preview the reference entry it
  points to. PaperMark finds the entry by its number or author name, so the preview is right even when the
  paper's link target is off. Links to figures, tables, and equations just jump.
- New: The sidebar's Pages tab is now a Contents tab with the PDF's table of contents and page numbers. Click a
  section to jump there; the section you are reading stays highlighted as you scroll.
- New: Back (`⌘[`) and Forward (`⌘]`) after following a link, a section, or a search result.
- New: The toolbar shows the current page and the page count.
- Changed: The default palette has four colors (pink, blue, yellow, purple). A palette you already customized is kept.
- Improved: Double-clicking highlights the whole word without surrounding quotes, so `‘t-SNE’` highlights `t-SNE`.
- Fix: Opening several PDFs at once (for example from Raycast or Finder) opened separate windows. They now open as
  tabs in the current window.
- Fix: Word snapping no longer extends into a superscript citation number, so dragging over `replay²¹⁻²³`
  highlights just `replay`. It also no longer pulls in a trailing apostrophe or closing quote.
- Fix: Numbers such as `84 × 84 × 4` were treated as phone numbers, which made them hard to highlight and could
  open a contact card on Force Click.

## 0.4.0

- New: The sidebar has a Files tab that shows the folders and PDFs around the current file, like an IDE
  explorer. Move up a level or pick any root folder, and double-click to open.
- New: PaperMark starts from your working folder (the file tree's root). Each launch opens a tab with its
  file tree next to the files you had open. On first launch it asks you to choose the folder.
- New: The tab bar's `+` opens a new tab that starts on the file tree. PDFs you open always become tabs in
  the current window, and the tab bar stays visible even with a single tab.
- New: Updated for the current macOS design, with glass toolbar buttons, the standard window controls, and
  the PaperMark icon next to the window title.
- Improved: The sidebar opens wider, and its edge is easier to grab and drag.
- Fix: While the eraser was on, toolbar clicks could be swallowed, so you could not turn the eraser off.
  Clicking the highlighter button while erasing now switches back to highlighting.

## 0.3.1

- Fix: Word snapping keeps brackets paired, so dragging `(word` highlights `(word)` instead of dropping the `)`.

## 0.3.0

- New: Translate sentences, not just words. Hold `T` while dragging over text, press `⌘T` on a selection,
  or right-click a highlight. Uses Apple's on-device Translation; hyphenated line breaks are joined first.
- New: Drags snap to whole words and stop at punctuation, so a typo like `results.In` highlights just `results`.

## 0.2.0

- New: Eraser. Hold `Space`, or toggle eraser mode with `⇧⌘E`, then click or rub over annotations to remove them.
- New: Settings window (`⌘,`) for changing keyboard shortcuts.
- New: `⌘1`–`⌘9` switch between palette colors.
- New: Click the selected color to edit it in the color panel. Right-click a color to remove it.
- New: Page thumbnail sidebar (`⌃⌘S`).
- New: Reopens the files you had open at the page you were reading.
- New: Remove or recolor underlines, strikethroughs, pen drawings, notes, and shapes made in other apps.
- New: App icon.
- Changed: Overlapping highlights merge into one layer instead of stacking.
- Changed: The default palette now matches PDF Expert's highlight colors.
- Changed: English UI, with the toolbar on its own row below the title bar.
- Changed: Universal build for Apple Silicon and Intel Macs.

## 0.1.0

- First release: drag to highlight in custom colors, search, zoom, undo, and automatic in-place saving
  that syncs through cloud folders.
