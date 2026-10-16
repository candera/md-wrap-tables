# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [0.6.0] - 2026-10-16

### Changed

- **The package is renamed from `md-wrap-tables` to `mdwt`.** The file is
  now `mdwt.el` and the feature `(require 'mdwt)`. The customisation group
  is `mdwt`. The unload hook is `mdwt-unload-function`. Commands, options
  and faces keep their `mdwt-` names. Update `require` / `use-package`
  forms accordingly.

### Added

- Standard package headers (`Package-Requires: ((emacs "29.1"))`) and the
  GPL-3.0-or-later license.
- ERT test suite, `Makefile` (`compile`, `checkdoc`, `lint`, `test`) and a
  GitHub Actions workflow.

### Fixed

- All checkdoc and package-lint findings.

## [0.5.1] - 2026-10-16

### Fixed

- Resizing the window during an in-place edit now re-renders the tables for
  the new width straight away and keeps the edit in progress.

## [0.5.0] - 2026-10-16

### Added

- **In-place cell editing**, the new default `mdwt-edit-method`. Type in a
  cell, or press `RET`, to edit its text right in the grid. Movement,
  deletion, kill/yank and per-cell undo work inside the cell. `RET` saves,
  `TAB`/`S-TAB` save and move, `C-g` cancels, and leaving the cell saves.
- `mdwt-editing-cell` face.

### Changed

- The word-wrapper also maps every character of a cell to its displayed
  position. Its output is unchanged.

## [0.4.2] - 2026-10-16

### Added

- `mdwt-edit-method` (`buffer` or `minibuffer`) and
  `mdwt-edit-window-height`.

### Fixed

- The cell edit window always opens directly below the table's window,
  regardless of `display-buffer-alist`.
- Saving or cancelling now closes the edit window instead of leaving it
  showing the table's buffer.

## [0.4.1] - 2026-10-16

### Added

- `C-a`/`C-e` jump to the first/last screen line of the cell's text,
  `M-a`/`M-e` to the first/last cell of the row, and `C-M-a`/`C-M-e` to
  the first/last row of the table.

### Fixed

- Cell lookup on screen lines compared cell ids with `eq`, so the lower
  lines of tall cells were missed.

## [0.4.0] - 2026-10-16

### Changed

- The real cursor now moves through the grid. Each rendered screen line is
  its own overlay anchored on a source character, and the `cursor` text
  property places the cursor in the current cell. The window scrolls line
  by line, including inside tables and cells taller than the window.

## [0.3.0] - 2026-10-16

### Added

- Cell cursor with a highlighted current cell (`mdwt-current-cell`), cell
  navigation keys, editing a cell in a small buffer (`RET`), and mouse
  selection.

### Fixed

- The `===` header rule was drawn above the header instead of below it.

## [0.2.1] - 2026-10-16

### Fixed

- `unload-feature` turns the mode off everywhere first, so no stale hooks
  are left behind.

## [0.2.0] - 2026-10-16

### Changed

- Tables stay rendered while navigating, scrolling or clicking.
  `mdwt-reveal-at-point` now defaults to `nil`.

### Added

- `mdwt-toggle-source`, `mdwt-mode-map`, and `mdwt-version` with a load
  message.

[0.6.0]: https://github.com/cmoxiv/md-wrap-tables/releases/tag/v0.6.0
