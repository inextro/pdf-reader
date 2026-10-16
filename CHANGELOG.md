# Changelog

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
