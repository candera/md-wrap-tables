# mdwt: wrapped Markdown tables for Emacs

[![CI](https://github.com/cmoxiv/md-wrap-tables/actions/workflows/ci.yml/badge.svg)](https://github.com/cmoxiv/md-wrap-tables/actions/workflows/ci.yml)
[![License: GPL v3+](https://img.shields.io/badge/License-GPLv3+-blue.svg)](LICENSE)

`mdwt-mode` is an Emacs minor mode that displays Markdown pipe tables as a
grid with **word-wrapped, multi-line cells** that fit the window. It lets you
navigate and edit the cells right in the rendered grid.

```
+----------------+----------------------+---------------------------+
| Axis           | Abdullah             | Zhong et al. 2025         |
+================+======================+===========================+
| Unit           | residual-stream      | residual-stream           |
|                | coordinate           | coordinate                |
+----------------+----------------------+---------------------------+
| Selection rule | Top-k of             | Top-k of corpus           |
|                | across-method XAI    | mean-difference           |
|                | agreement on one     |                           |
|                | prediction           |                           |
+----------------+----------------------+---------------------------+
```

Rendering is display-only. The file keeps its ordinary one-line-per-row pipe
tables, so diffs, `markdown-mode`, exporters and other tools see normal
Markdown. The buffer text changes only when you save a cell edit, and then
only that cell's text.

## Features

- **Wrapped cells:** long cells wrap onto several lines. Column widths shrink
  to fit the window and re-fit when it is resized.
- **Real cursor in the grid:** the cursor moves through the table screen line
  by screen line and cell by cell. The window scrolls with it, including
  through tables and cells taller than the window.
- **Highlighted current cell.**
- **In-place editing:** type in a cell to edit its text where it is shown.
  Movement and deletion keys work inside the cell, and the table re-wraps as
  you type.
- **Other edit methods:** a small edit window below the table, or the
  minibuffer.
- **Raw-source toggle** for free-form editing of the pipe-table text.
- **Markdown details handled:** `<br>` in a cell forces a line break; `\|`
  escapes and pipes inside `` `code` `` are respected; column alignment
  (`:--`, `:-:`, `--:`) is honoured; tables inside fenced code blocks are
  left alone.

## Requirements

- Emacs 29.1 or later.
- Recommended: [`markdown-mode`](https://github.com/jrblevin/markdown-mode),
  which provides `markdown-mode` and `gfm-mode` to hook into.

## Installation

`mdwt` is not on MELPA, so give your package manager the GitHub location.
Pick the section for the package manager you use, and don't mix them.

### straight.el

```elisp
(use-package mdwt
  :straight (:host github :repo "cmoxiv/md-wrap-tables")
  :hook ((markdown-mode gfm-mode) . mdwt-mode))
```

Use this form if you set `straight-use-package-by-default`. With that
setting, `use-package` hands every package to straight first, even one
declared with `:vc`. straight then looks `mdwt` up in its recipe
repositories and fails with *"Could not find package mdwt"*.

### `package.el` with `use-package :vc` (Emacs 30+)

```elisp
(use-package mdwt
  :vc (:url "https://github.com/cmoxiv/md-wrap-tables" :rev :newest)
  :hook ((markdown-mode gfm-mode) . mdwt-mode))
```

### `package.el` on Emacs 29

The `use-package` in Emacs 29 has no `:vc` keyword, but `package-vc-install`
does exist:

```elisp
(unless (package-installed-p 'mdwt)
  (package-vc-install '(mdwt :url "https://github.com/cmoxiv/md-wrap-tables")))

(use-package mdwt
  :ensure nil
  :hook ((markdown-mode gfm-mode) . mdwt-mode))
```

### Manual

```sh
git clone https://github.com/cmoxiv/md-wrap-tables.git ~/src/md-wrap-tables
```

```elisp
(add-to-list 'load-path "~/src/md-wrap-tables")
(require 'mdwt)
(add-hook 'markdown-mode-hook #'mdwt-mode)
(add-hook 'gfm-mode-hook #'mdwt-mode)
```

If you use straight.el with `straight-use-package-by-default` and load a
local checkout with `:load-path`, add `:straight nil`. Otherwise straight
tries to download the package from a recipe repository and fails with
*"Could not find package mdwt"*.

### Full configuration example

Every option, with its default value. This example uses straight.el; with
`package.el`, replace the `:straight` line with the `:vc` line from above.

```elisp
(use-package markdown-mode
  :mode ("\\.md\\'" . gfm-mode))

(use-package mdwt
  :straight (:host github :repo "cmoxiv/md-wrap-tables")
  :commands (mdwt-mode mdwt-refresh mdwt-toggle-source mdwt-version)
  :hook ((markdown-mode gfm-mode) . mdwt-mode)
  :bind (:map mdwt-mode-map
         ("C-c t" . mdwt-toggle-source)
         ("C-c r" . mdwt-refresh))
  :custom
  (mdwt-min-width 8)
  (mdwt-margin 2)
  (mdwt-row-separators t)
  (mdwt-reveal-at-point nil)
  (mdwt-delay 0.3)
  (mdwt-edit-method 'inplace)
  (mdwt-edit-window-height 8)
  :custom-face
  (mdwt-current-cell ((t (:inherit highlight))))
  (mdwt-editing-cell ((t (:inherit region)))))
```

## Usage

Open a Markdown file. With `mdwt-mode` on (the mode line shows `⊞`), every
pipe table is drawn as a wrapped grid. Move onto a table as usual (`C-n`
from the line above, `C-p` from below, or a mouse click) and the cursor
enters the grid with the current cell highlighted.

To edit a cell, just start typing, or press `RET`. Press `RET` again to save
or `C-g` to cancel.

## Keybindings

### On a table (navigating)

| Key                                    | Action                                                        |
| -------------------------------------- | ------------------------------------------------------------- |
| `C-n` / `↓`                            | Next screen line, also inside tall cells; rule lines skipped  |
| `C-p` / `↑`                            | Previous screen line                                          |
| `C-f` / `→`                            | Next cell on the same line; wraps to the next row             |
| `C-b` / `←`                            | Previous cell; wraps to the previous row                      |
| `TAB` / `S-TAB`                        | Next / previous cell                                          |
| `C-a` / `C-e` (`Home` / `End`)         | First / last screen line of the current cell's text           |
| `M-a` / `M-e`                          | First / last cell of the row                                  |
| `C-M-a` / `C-M-e`                      | First (header) / last row of the table, same column           |
| `RET`, double-click                    | Edit the cell (method set by `mdwt-edit-method`)              |
| Typing a character, `DEL`              | Start editing the cell in place (with the `inplace` method)   |
| `mouse-1`                              | Select the clicked cell                                       |
| Moving past the first / last row       | Leave the table                                               |

### While editing a cell in place

| Key                          | Action                                                      |
| ---------------------------- | ----------------------------------------------------------- |
| Any character                | Insert it at the cursor                                     |
| `C-f` / `C-b` (`→` / `←`)    | Character right / left                                      |
| `M-f` / `M-b`                | Word right / left                                           |
| `C-a` / `C-e`                | Start / end of the cell's current wrapped line              |
| `C-n` / `C-p`                | Next / previous wrapped line in the cell, keeping the column |
| `DEL` / `C-d`                | Delete backward / forward                                   |
| `C-k`                        | Kill to the end of the cell text                            |
| `C-y`                        | Yank (line breaks become spaces)                            |
| `C-/`                        | Undo the last change to the cell text                       |
| `RET` / `C-c C-c`            | Save                                                        |
| `TAB` / `S-TAB`              | Save and move to the next / previous cell                   |
| `C-g` / `C-c C-k`            | Cancel, discarding the edit                                 |

Leaving the cell in any other way also saves the edit: `C-n` past its last
line, `C-p` past its first, `M-a`, `C-M-e`, a mouse click, or moving point
out of the table. Nothing is written to the buffer until you save. The whole
cell edit then becomes a single undo step in the buffer. A `|` you type is
saved as `\|`.

### In the edit window (`mdwt-edit-method` set to `buffer`)

| Key       | Action                                |
| --------- | ------------------------------------- |
| `C-c C-c` | Save into the table and close         |
| `C-c C-k` | Cancel and close                      |

The window opens directly below the table's window, whatever your
`display-buffer-alist` says. Line breaks in the edited text become spaces,
since a table cell must be one line.

### Commands (bind as you like)

| Command              | Suggested key | Action                                                                                |
| -------------------- | ------------- | ------------------------------------------------------------------------------------- |
| `mdwt-mode`          |               | Toggle the minor mode                                                                 |
| `mdwt-toggle-source` | `C-c t`       | Toggle between the rendered table and its raw source; point follows the current cell |
| `mdwt-refresh`       | `C-c r`       | Re-render all tables now                                                              |
| `mdwt-version`       |               | Show the loaded version and the file it was loaded from                               |

The raw source shown by `mdwt-toggle-source` re-renders on its own when point
leaves the table.

## Customisation

`M-x customize-group RET mdwt`

| Option                    | Default    | Meaning                                                                                  |
| ------------------------- | ---------- | ---------------------------------------------------------------------------------------- |
| `mdwt-edit-method`        | `inplace`  | How cells are edited: `inplace` (in the grid), `buffer` (window below), or `minibuffer`  |
| `mdwt-edit-window-height` | `8`        | Height of the edit window (with the `buffer` method)                                     |
| `mdwt-min-width`          | `8`        | Narrowest a column is squeezed to before the table may overflow                          |
| `mdwt-margin`             | `2`        | Columns kept free at the right edge of the window                                        |
| `mdwt-row-separators`     | `t`        | Draw a rule between body rows                                                            |
| `mdwt-reveal-at-point`    | `nil`      | Show raw source whenever point is on a table (turns off the cell cursor)                 |
| `mdwt-delay`              | `0.3`      | Idle seconds to wait after an edit or resize before re-rendering                         |

| Face                | Default             | Used for                    |
| ------------------- | ------------------- | --------------------------- |
| `mdwt-current-cell` | inherits `highlight` | The selected cell          |
| `mdwt-editing-cell` | inherits `region`    | A cell being edited in place |

Tables also use `markdown-table-face` when `markdown-mode` defines it.

### Customisation examples

Each example works on its own. Put it in your init file, or in a
`use-package mdwt` block's `:config`.

**Edit long cells in a window instead of in place**

```elisp
(setq mdwt-edit-method 'buffer      ; or 'minibuffer
      mdwt-edit-window-height 12)
```

**Compact tables:** no rule between body rows, narrower minimum column
width, and the full window width used.

```elisp
(setq mdwt-row-separators nil
      mdwt-min-width 5
      mdwt-margin 0)
```

**Re-render faster after typing or resizing**

```elisp
(setq mdwt-delay 0.1)
```

**Always show the raw table source when the cursor is on a table** (the
behaviour before 0.2.0; turns off the cell cursor)

```elisp
(setq mdwt-reveal-at-point t)
```

**Colours for the current and edited cell**

```elisp
(custom-set-faces
 '(mdwt-current-cell ((t (:background "#2f3b54" :weight bold))))
 '(mdwt-editing-cell ((t (:background "#3b2f54" :underline t)))))

;; or adjust one attribute, e.g. reuse another face's colours:
(set-face-attribute 'mdwt-editing-cell nil :inherit 'secondary-selection)
```

To change the colour of the whole table, customise `markdown-table-face`.

**Rebind or add keys:** the four keymaps are listed under [API](#api).

```elisp
(with-eval-after-load 'mdwt
  ;; Anywhere in an mdwt buffer
  (keymap-set mdwt-mode-map "C-c t" #'mdwt-toggle-source)
  ;; On a table
  (keymap-set mdwt-cell-map "C-c e" #'mdwt-edit-cell)
  (keymap-set mdwt-cell-map "M-n"   #'mdwt-cell-down)
  ;; While editing a cell in place
  (keymap-set mdwt-inplace-map "C-j" #'mdwt-ip-commit-next))
```

**Turn off the mouse bindings** (`mouse-1` selects a cell, double-click
edits it)

```elisp
(with-eval-after-load 'mdwt
  (keymap-unset mdwt-mode-map "<mouse-1>" t)
  (keymap-unset mdwt-mode-map "<double-mouse-1>" t))
```

**Skip very large files**

```elisp
(defun my/mdwt-maybe ()
  "Turn on `mdwt-mode' unless the buffer is huge."
  (unless (> (buffer-size) 500000)
    (mdwt-mode 1)))

(add-hook 'gfm-mode-hook #'my/mdwt-maybe)
(add-hook 'markdown-mode-hook #'my/mdwt-maybe)
```

**Different settings per buffer:** set options buffer-locally before turning
the mode on. `mdwt-mode-hook` runs after the first render, so layout options
set there only apply from the next re-render.

```elisp
(defun my/mdwt-notes-setup ()
  "Compact tables and minibuffer editing in my notes."
  (when (and buffer-file-name (string-prefix-p (expand-file-name "~/notes/") buffer-file-name))
    (setq-local mdwt-row-separators nil
                mdwt-edit-method 'minibuffer))
  (mdwt-mode 1))

(add-hook 'gfm-mode-hook #'my/mdwt-notes-setup)
```

**Do something whenever the mode turns on:** for example, truncate rather
than wrap the lines of a table too wide to fit (`mdwt-min-width` stops
columns from shrinking further).

```elisp
(add-hook 'mdwt-mode-hook (lambda () (setq-local truncate-lines t)))
```

## API

Symbols with a double dash (`mdwt--…`) are internal and may change between
versions. Everything below is public.

### Minor mode and hooks

| Symbol                     | Kind          | Description                                                                         |
| -------------------------- | ------------- | ----------------------------------------------------------------------------------- |
| `mdwt-mode`                | minor mode    | Render the buffer's pipe tables as wrapped grids. Turn on from a major-mode hook.    |
| `mdwt-mode-hook`           | hook          | Runs after `mdwt-mode` is turned on or off (after the first render).                |
| `mdwt-cell-edit-mode`      | minor mode    | Active in the `*mdwt cell*` edit buffer (`buffer` edit method).                     |
| `mdwt-cell-edit-mode-hook` | hook          | Runs when the cell edit buffer is set up.                                           |
| `mdwt-unload-function`     | function      | Called by `unload-feature`; turns the mode off everywhere first.                    |

### Keymaps

| Keymap                    | Active                                         | Default bindings                                                           |
| ------------------------- | ---------------------------------------------- | -------------------------------------------------------------------------- |
| `mdwt-mode-map`           | Whole buffer, while `mdwt-mode` is on          | `mouse-1`, `double-mouse-1`                                                |
| `mdwt-cell-map`           | Point on a rendered table                      | Cell navigation, `RET`, typing starts an edit                              |
| `mdwt-inplace-map`        | While a cell is edited in place                | Editing keys; keys it doesn't bind fall through to `mdwt-cell-map`         |
| `mdwt-cell-edit-mode-map` | In the `*mdwt cell*` edit buffer               | `C-c C-c`, `C-c C-k`                                                       |

`mdwt-cell-map` and `mdwt-inplace-map` are emulation keymaps. They take
priority over major- and minor-mode bindings, so `TAB` and `RET` work on
tables even in modes that bind them.

### Commands: general

| Command              | Description                                                                                      |
| -------------------- | ------------------------------------------------------------------------------------------------ |
| `mdwt-refresh`       | Re-render every table in the buffer now.                                                         |
| `mdwt-toggle-source` | Toggle the table at point between the rendered grid and its raw source; point follows the cell. |
| `mdwt-edit-cell`     | Edit the current cell using `mdwt-edit-method`.                                                  |
| `mdwt-version`       | Show the loaded version and the file it was loaded from.                                         |

### Commands: navigation (`mdwt-cell-map`)

| Command                               | Default keys                | Description                                                  |
| ------------------------------------- | --------------------------- | ------------------------------------------------------------ |
| `mdwt-cell-down` / `mdwt-cell-up`     | `C-n` / `C-p`, `↓` / `↑`    | Next / previous screen line, also inside tall cells          |
| `mdwt-cell-next` / `mdwt-cell-prev`   | `C-f` / `C-b`, `TAB` / `S-TAB` | Next / previous cell, wrapping across rows                |
| `mdwt-cell-top` / `mdwt-cell-bottom`  | `C-a` / `C-e`               | First / last screen line of the cell's text                  |
| `mdwt-cell-first` / `mdwt-cell-last`  | `M-a` / `M-e`               | First / last cell of the row                                 |
| `mdwt-row-first` / `mdwt-row-last`    | `C-M-a` / `C-M-e`           | First (header) / last row, same column                       |
| `mdwt-cell-type`                      | printing keys               | Start an in-place edit and insert the key (`inplace` method) |
| `mdwt-cell-type-backspace`            | `DEL`                       | Start an in-place edit and delete backward                   |
| `mdwt-cell-blocked`                   | `C-d`, `C-k`, `C-y`         | Refuse to change the rendered table; show the edit keys      |
| `mdwt-mouse-select`                   | `mouse-1`                   | Set point; select the clicked cell                           |
| `mdwt-mouse-edit`                     | `double-mouse-1`            | Edit the double-clicked cell                                 |

### Commands: in-place editing (`mdwt-inplace-map`)

| Command                                               | Default keys          | Description                                         |
| ----------------------------------------------------- | --------------------- | --------------------------------------------------- |
| `mdwt-ip-insert`                                      | printing keys         | Insert the typed character                          |
| `mdwt-ip-delete-backward` / `mdwt-ip-delete-forward`  | `DEL` / `C-d`         | Delete a character                                  |
| `mdwt-ip-forward-char` / `mdwt-ip-backward-char`      | `C-f` / `C-b`         | Move by character                                   |
| `mdwt-ip-forward-word` / `mdwt-ip-backward-word`      | `M-f` / `M-b`         | Move by word                                        |
| `mdwt-ip-line-start` / `mdwt-ip-line-end`             | `C-a` / `C-e`         | Start / end of the cell's current wrapped line      |
| `mdwt-ip-next-line` / `mdwt-ip-previous-line`         | `C-n` / `C-p`         | Wrapped line down / up; past the edge, save and move |
| `mdwt-ip-kill-line`                                   | `C-k`                 | Kill to the end of the cell text                    |
| `mdwt-ip-yank`                                        | `C-y`                 | Yank, with line breaks turned into spaces           |
| `mdwt-ip-undo`                                        | `C-/`                 | Undo the last change to the cell text               |
| `mdwt-ip-commit`                                      | `RET`, `C-c C-c`      | Save the cell                                       |
| `mdwt-ip-commit-next` / `mdwt-ip-commit-prev`         | `TAB` / `S-TAB`       | Save and move to the next / previous cell           |
| `mdwt-ip-cancel`                                      | `C-g`, `C-c C-k`      | Discard the edit                                    |

### Commands: edit buffer (`mdwt-cell-edit-mode-map`)

| Command            | Default keys | Description                                  |
| ------------------ | ------------ | -------------------------------------------- |
| `mdwt-edit-commit` | `C-c C-c`    | Write the cell back into the table and close |
| `mdwt-edit-abort`  | `C-c C-k`    | Close without saving                         |

### Options, faces and constants

The options and faces are listed under [Customisation](#customisation).
`mdwt-version` is also a constant holding the version string (for example
`"0.6.0"`).

## How it works

Emacs cannot put the cursor inside a display string. So instead of one
overlay showing the whole table, each table gets one small overlay per
rendered screen line. Overlay *i* covers the *i*-th character of the table's
source and displays screen line *i*. Every screen line therefore starts at a
real buffer position, so point can sit on it and the window can scroll to
it. The `cursor` text property then draws the cursor at the right character
inside the current cell.

In-place edits are held in memory and the table is re-rendered from its
source with the edited text substituted. The word-wrapper records where every
character of the cell lands, which places the cursor. Saving rewrites only
that cell's text in the pipe-table line.

## Limitations

- While you edit the widest column in place, column widths can shift as the
  text grows or shrinks.
- A cell's text must stay on one line in the source. Line breaks typed in the
  edit window or yanked into a cell become spaces. Use `<br>` for a forced
  break.
- Very small tables whose rendered grid has more lines than the table source
  has characters can't give every screen line its own cursor position. The
  extra lines are drawn but point can't reach them.
- Evil-mode key bindings are not handled.

## Troubleshooting

- **Check which copy is loaded:** each load prints
  `mdwt X.Y.Z loaded from /path/...` in `*Messages*`.
  `M-x mdwt-version` shows the same. If the path isn't the one you expect,
  `M-x locate-library RET mdwt` shows which file `require` finds.
  A stale compiled copy, for example under `straight/build/`, can shadow the
  one you are editing.
- **Reloading after changes:** restart Emacs, or run
  `M-x unload-feature RET mdwt` and load the file again.
  Unloading turns the mode off in every buffer first, so no stale hooks are
  left behind.
- **`void-variable mdwt-mode-map` from `:bind`:** an old version without the
  keymap is loaded; see the first point.

## Development

```sh
make compile    # byte-compile, warnings are errors
make checkdoc   # docstring conventions
make test       # ERT suite (test/mdwt-test.el)
make lint       # package-lint (installs it from MELPA; needs network)
make            # compile + checkdoc + test
```

Set `EMACS=/path/to/emacs` to test against a particular Emacs. CI runs
`compile`, `checkdoc` and `test` on Emacs 29.1, 29.4, 30.1 and snapshot, and
`lint` on 30.1.

Display itself can't be observed in batch mode, so the tests inspect the
overlays' display strings, where the `cursor` property is placed, point,
and the cell-cursor state.

## License

Copyright (C) 2026 Mo Hossny

GPL-3.0-or-later. See [LICENSE](LICENSE).
