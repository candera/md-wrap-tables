;;; mdwt.el --- Wrapped, navigable, editable Markdown tables  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Mo Hossny

;; Author: Mo Hossny <cmoxiv@gmail.com>
;; Maintainer: Mo Hossny <cmoxiv@gmail.com>
;; URL: https://github.com/cmoxiv/md-wrap-tables
;; Version: 0.6.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: text, wp, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `mdwt-mode' displays pipe tables as a grid with word-wrapped,
;; multi-line cells that fit the window, and lets you navigate and edit
;; the cells right in the rendered grid.
;;
;; Display-only: the buffer text is never modified.  Each Markdown (or Org)
;; pipe table is displayed, via overlays, as the same table re-rendered as
;; a grid with every cell word-wrapped to fit the window.
;;
;; The cursor moves through the grid: C-n / C-p (arrows) go screen line by
;; screen line, also inside tall wrapped cells, and the window scrolls with
;; it; C-f / C-b / TAB / S-TAB go cell by cell.  C-a / C-e jump to the
;; first / last screen line of the cell's text, M-a / M-e to the row's
;; first / last cell, C-M-a / C-M-e to the table's first / last row.
;; Moving past an edge leaves the table.  The current
;; cell is highlighted.  mouse-1 selects a cell.
;;
;; Editing (see `mdwt-edit-method'): by default just type in a cell, or
;; press RET / double-click, to edit it in place -- the usual movement and
;; deletion keys work inside the cell text, RET saves, TAB / S-TAB save
;; and move to the next / previous cell, C-g cancels, and moving off the
;; cell saves.  Alternatively edit in a small window below the table
;; (C-c C-c saves, C-c C-k cancels) or in the minibuffer.
;;
;; `mdwt-toggle-source' shows the raw source of the table at point for
;; free-form editing (it re-renders when point leaves).  Set
;; `mdwt-reveal-at-point' to reveal automatically instead.
;;
;; Usage:
;;   (require 'mdwt)
;;   (add-hook 'markdown-mode-hook #'mdwt-mode)
;;   (add-hook 'gfm-mode-hook #'mdwt-mode)
;;   ;; Org pipe tables work too:
;;   ;; (add-hook 'org-mode-hook #'mdwt-mode)

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst mdwt-version "0.6.0"
  "Version of mdwt.  Bump on every change to tell copies apart.")

(defconst mdwt--load-file (or load-file-name buffer-file-name)
  "File this library was loaded from.")

(defgroup mdwt nil
  "Display pipe tables with wrapped multi-line cells."
  :group 'text
  :prefix "mdwt-")

(defcustom mdwt-min-width 8
  "Narrowest a column is squeezed to before the table may overflow."
  :type 'integer)

(defcustom mdwt-margin 2
  "Columns kept free at the right edge of the window."
  :type 'integer)

(defcustom mdwt-row-separators t
  "Non-nil draws a rule between body rows (helps when rows are multi-line)."
  :type 'boolean)

(defcustom mdwt-reveal-at-point nil
  "Non-nil shows the raw table source whenever point moves onto a table.
When nil, tables stay rendered while navigating, scrolling or clicking;
use `mdwt-toggle-source' to show the raw source of the table at point."
  :type 'boolean)

(defcustom mdwt-edit-method 'inplace
  "How a table cell is edited (\\<mdwt-cell-map>\\[mdwt-edit-cell], \
double-click, or typing in a cell).
`inplace': edit the text right in the rendered cell;
  \\<mdwt-inplace-map>\\[mdwt-ip-commit] or \\[mdwt-ip-commit-next] saves, \
\\[mdwt-ip-cancel] cancels, moving off the cell saves.
  Typing in a cell starts it.
`buffer': a small window opened directly below the table's window
  (\\<mdwt-cell-edit-mode-map>\\[mdwt-edit-commit] saves, \
\\[mdwt-edit-abort] cancels); comfortable for very long cells.
`minibuffer': edit the cell text in the minibuffer."
  :type '(choice (const :tag "In place, in the rendered cell" inplace)
                 (const :tag "Edit buffer below the table" buffer)
                 (const :tag "Minibuffer" minibuffer)))

(defcustom mdwt-edit-window-height 8
  "Height in lines of the cell edit window (with `mdwt-edit-method' `buffer')."
  :type 'integer)

(defcustom mdwt-delay 0.3
  "Idle seconds to wait after an edit or resize before re-rendering."
  :type 'number)

(defface mdwt-current-cell '((t :inherit highlight))
  "Face for the cell under the cell cursor.")

(defface mdwt-editing-cell '((t :inherit region))
  "Face for a cell being edited in place.")

;;;; Parsing

(defun mdwt--line ()
  "The current line's text, without properties."
  (buffer-substring-no-properties (line-beginning-position) (line-end-position)))

(defun mdwt--sep-p (line)
  "Non-nil if LINE is a GFM (|---|:--:|) or Org (|---+---|) separator."
  (string-match-p
   "\\`[ \t]*|?[ \t]*:?-+:?[ \t]*\\([|+][ \t]*:?-+:?[ \t]*\\)*|?[ \t]*\\'"
   line))

(defun mdwt--cell-spans (line)
  "Return (START . END) of each cell's trimmed text in table LINE.
Honours \\| escapes and, leniently, unescaped pipes inside `code'."
  (let* ((n (length line))
         (lo (or (string-match-p "[^ \t]" line) n))
         (hi (let ((k n))
               (while (and (> k lo) (memq (aref line (1- k)) '(?\s ?\t))) (cl-decf k))
               k))
         (start (if (and (< lo hi) (eq (aref line lo) ?|)) (1+ lo) lo))
         (stop (if (and (> hi start) (eq (aref line (1- hi)) ?|)
                        (not (and (> (1- hi) start) (eq (aref line (- hi 2)) ?\\))))
                   (1- hi)
                 hi))
         (i start) (cell start) in-code spans)
    (while (< i stop)
      (let ((c (aref line i)))
        (cond
         ((and (eq c ?\\) (< (1+ i) stop) (eq (aref line (1+ i)) ?|)) (cl-incf i))
         ((eq c ?`) (setq in-code (not in-code)))
         ((and (eq c ?|) (not in-code)) (push (cons cell i) spans) (setq cell (1+ i)))))
      (cl-incf i))
    (push (cons cell stop) spans)
    (mapcar (lambda (sp)
              (let ((s (car sp)) (e (cdr sp)))
                (while (and (< s e) (memq (aref line s) '(?\s ?\t))) (cl-incf s))
                (while (and (> e s) (memq (aref line (1- e)) '(?\s ?\t))) (cl-decf e))
                (cons s e)))
            (nreverse spans))))

(defun mdwt--split-row (line)
  "Split table LINE into trimmed cell strings, unescaping \\|."
  (mapcar (lambda (sp)
            (string-replace "\\|" "|" (substring line (car sp) (cdr sp))))
          (mdwt--cell-spans line)))

(defun mdwt--aligns (sep)
  "Column alignments from separator line SEP."
  (mapcar (lambda (c)
            (setq c (string-trim c))
            (cond ((and (string-prefix-p ":" c) (string-suffix-p ":" c)) 'center)
                  ((string-suffix-p ":" c) 'right)
                  (t 'left)))
          (split-string (string-trim sep "[ \t|]+" "[ \t|]+") "[|+]")))

(defun mdwt--tables ()
  "Return a list of (BEG END INDENT LINES) for every pipe table in the buffer.
Tables inside fenced code blocks are skipped."
  (let (tables in-fence)
    (goto-char (point-min))
    (while (not (eobp))
      (let ((line (mdwt--line)))
        (cond
         ((string-match-p "\\`[ \t]*\\(```\\|~~~\\)" line)
          (setq in-fence (not in-fence))
          (forward-line 1))
         ((and (not in-fence)
               (string-match-p "\\`[ \t]*|" line)
               (save-excursion (forward-line 1) (mdwt--sep-p (mdwt--line))))
          (let ((beg (line-beginning-position))
                (indent (if (string-match "\\`[ \t]*" line) (match-string 0 line) ""))
                lines end)
            (while (and (not (eobp)) (string-match-p "\\`[ \t]*|" (mdwt--line)))
              (push (mdwt--line) lines)
              (setq end (line-end-position))
              (forward-line 1))
            (push (list beg end indent (nreverse lines)) tables)))
         (t (forward-line 1)))))
    (nreverse tables)))

;;;; Layout

(defun mdwt--pieces (text)
  "Split cell TEXT on <br> tags (LLMs often emit them)."
  (split-string text "[ \t]*<br[ \t]*/?>[ \t]*"))

(defun mdwt--natural (text)
  "Display width of cell TEXT's widest <br>-separated piece."
  (apply #'max 0 (mapcar #'string-width (mdwt--pieces text))))

(defun mdwt--wrap-piece (text beg end width ln map)
  "Greedily wrap the words of TEXT[BEG,END) to WIDTH display columns.
Return the list of lines, numbered from LN.  Also record in vector MAP,
for each character offset I in the range, the (LINE . CHAR) it is shown
at; collapsed whitespace maps to just after the preceding word."
  (let ((lines nil) (cur "") (j beg))
    (cl-flet ((place (ws w at)
                (dotimes (i (length w)) (aset map (+ ws i) (cons ln (+ at i))))))
      (while (< j end)
        (if (memq (aref text j) '(?\s ?\t))
            (progn (aset map j (cons ln (length cur))) (cl-incf j))
          (let* ((we (or (cl-position-if (lambda (c) (memq c '(?\s ?\t))) text :start j :end end)
                         end))
                 (ws j)
                 (w (substring text j we)))
            ;; Hard-break words longer than the column (URLs, long identifiers).
            (while (> (string-width w) width)
              (unless (string-empty-p cur) (push cur lines) (setq cur "" ln (1+ ln)))
              (let ((head (truncate-string-to-width w width)))
                (when (string-empty-p head) (setq head (substring w 0 1)))
                (place ws head 0)
                (push head lines)
                (setq ln (1+ ln) ws (+ ws (length head)) w (substring w (length head)))))
            (cond ((string-empty-p w))
                  ((string-empty-p cur) (place ws w 0) (setq cur w))
                  ((<= (+ (string-width cur) 1 (string-width w)) width)
                   (place ws w (1+ (length cur)))
                   (setq cur (concat cur " " w)))
                  (t (push cur lines) (setq ln (1+ ln) cur w) (place ws w 0)))
            (setq j we)))))
    (unless (string-empty-p cur) (push cur lines))
    (or (nreverse lines) (list ""))))

(defun mdwt--wrap-map (text width)
  "Word-wrap cell TEXT to WIDTH, breaking at <br> tags.
Return (LINES . MAP): MAP is a vector giving, for every offset 0..(length
TEXT) into TEXT, the (LINE . CHAR) position it is displayed at."
  (let ((map (make-vector (1+ (length text)) nil))
        (all nil) (ln 0) (pos 0) (done nil))
    (while (not done)
      (let* ((m (string-match "[ \t]*<br[ \t]*/?>[ \t]*" text pos))
             (pend (or m (length text)))
             (mend (and m (match-end 0)))
             (pl (mdwt--wrap-piece text pos pend width ln map))
             (endpos (cons (+ ln (length pl) -1) (length (car (last pl))))))
        (setq all (nconc all pl))
        (cl-loop for i from pend below (or mend (1+ pend)) do (aset map i endpos))
        (setq ln (+ ln (length pl)))
        (if m (setq pos mend) (setq done t))))
    ;; Offsets left past a hard-broken final word point at a missing line.
    (let ((last (1- (length all))))
      (cl-loop for i below (length map)
               for p = (aref map i)
               when (> (car p) last)
               do (aset map i (cons last (length (nth last all))))))
    (cons all map)))

(defun mdwt--wrap (text width)
  "Word-wrap cell TEXT to WIDTH; return the list of lines."
  (car (mdwt--wrap-map text width)))

(defun mdwt--fit (natural avail)
  "Shrink the widest columns in NATURAL until their sum fits AVAIL."
  (if (<= (apply #'+ natural) avail)
      natural
    (let ((cap (apply #'max natural)))
      (while (and (> cap mdwt-min-width)
                  (> (apply #'+ (mapcar (lambda (n) (min n cap)) natural)) avail))
        (cl-decf cap))
      (mapcar (lambda (n) (min n cap)) natural))))

(defun mdwt--pad (s width align)
  "Pad S with spaces to WIDTH columns according to ALIGN."
  (let ((gap (max 0 (- width (string-width s)))))
    (pcase align
      ('right (concat (make-string gap ?\s) s))
      ('center (let ((l (/ gap 2)))
                 (concat (make-string l ?\s) s (make-string (- gap l) ?\s))))
      (_ (concat s (make-string gap ?\s))))))

(defun mdwt--rule (widths ch)
  "A horizontal rule drawn with CH for columns of WIDTHS."
  (concat "+" (mapconcat (lambda (w) (make-string (+ w 2) ch)) widths "+") "+"))

(defun mdwt--render-row (cells widths aligns r)
  "Screen lines of row R with CELLS wrapped to WIDTHS and padded per ALIGNS.
Each cell segment carries the text property `mdwt-cell' (R . COL)."
  (let* ((wrapped (cl-loop for w in widths for j from 0
                           collect (mdwt--wrap (or (nth j cells) "") w)))
         (height (apply #'max (mapcar #'length wrapped))))
    (cl-loop for k below height
             collect (concat "|"
                             (mapconcat #'identity
                                        (cl-loop for w in widths for a in aligns for col in wrapped
                                                 for j from 0
                                                 collect (propertize
                                                          (concat " " (mdwt--pad (or (nth k col) "") w a) " ")
                                                          'mdwt-cell (cons r j)))
                                        "|")
                             "|"))))

(defun mdwt--rows (lines)
  "Header and body rows of table LINES, each a list of cell strings."
  (cons (mdwt--split-row (car lines))
        (mapcar #'mdwt--split-row (nthcdr 2 lines))))

(defun mdwt--layout (lines indent avail)
  "Return (ROWS ALIGNS WIDTHS) for table LINES fitting AVAIL columns.
INDENT is the table's leading whitespace."
  (let* ((rows (mdwt--rows lines))
         (ncols (apply #'max (mapcar #'length rows)))
         (sep-aligns (mdwt--aligns (nth 1 lines)))
         (aligns (cl-loop for j below ncols collect (or (nth j sep-aligns) 'left)))
         (natural (cl-loop for j below ncols
                           collect (max 3 (apply #'max (mapcar (lambda (r) (mdwt--natural (or (nth j r) "")))
                                                               rows))))))
    (list rows aligns (mdwt--fit natural (- avail (string-width indent) (1+ (* 3 ncols)))))))

(defun mdwt--render-lines (lines indent avail)
  "Render table LINES as a wrapped grid fitting AVAIL columns.
Each screen line starts with INDENT.  Return one (STRING . ROW) per
screen line; ROW is nil for rules, 0 for the header."
  (pcase-let* ((`(,rows ,aligns ,widths) (mdwt--layout lines indent avail))
               (thin (mdwt--rule widths ?-))
               (out (list (cons thin nil)))
               (body (cdr rows))
               (r 1))
    (dolist (l (mdwt--render-row (car rows) widths aligns 0)) (push (cons l 0) out))
    (push (cons (mdwt--rule widths ?=) nil) out)
    (while body
      (dolist (l (mdwt--render-row (car body) widths aligns r)) (push (cons l r) out))
      (when (and mdwt-row-separators (cdr body)) (push (cons thin nil) out))
      (setq body (cdr body) r (1+ r)))
    (push (cons thin nil) out)
    (mapcar (lambda (x) (cons (concat indent (car x)) (cdr x))) (nreverse out))))

(defun mdwt--render (lines indent avail)
  "Table LINES, indented by INDENT, rendered as one string fitting AVAIL columns."
  (mapconcat #'car (mdwt--render-lines lines indent avail) "\n"))

;;;; Overlays
;;
;; Each table has a container overlay (property `mdwt') holding the
;; rendered screen lines, plus one *slice* overlay per screen line.  Slice
;; I covers the I-th character of the table source and displays screen
;; line I; the last slice covers the remaining source.  Because every
;; screen line starts at a real buffer position, point can sit on any of
;; them and the window can scroll through a table line by line.  The
;; `cursor' text property then draws the cursor in the current cell.

(defvar-local mdwt--revealed nil "Table currently showing raw source.")
(defvar-local mdwt--timer nil)
(defvar-local mdwt--cell-ov nil "Table holding the cell cursor, or nil.")
(defvar-local mdwt--cell nil "(ROW . COL) of the current cell; row 0 is the header.")
(defvar-local mdwt--line nil "Index of the screen line point is on.")
(defvar-local mdwt--pending-col nil "Column to select on the next update (mouse).")
(defvar-local mdwt--painted nil "State the cell cursor was last drawn for.")
(defvar-local mdwt--ip-text nil "Text of the cell being edited in place, or nil.")
(defvar-local mdwt--ip-off 0 "Edit offset into `mdwt--ip-text'.")
(defvar-local mdwt--ip-col 0 "Character position of the edit offset on its wrapped line.")
(defvar-local mdwt--ip-cell nil "(ROW . COL) of the cell being edited in place.")
(defvar-local mdwt--ip-lines nil "Table source lines when in-place editing began.")
(defvar mdwt-mode)

(defun mdwt--avail ()
  "Columns available for tables in the current buffer's window."
  (let ((win (get-buffer-window (current-buffer) t)))
    (- (if win (window-body-width win) 80) mdwt-margin)))

(defun mdwt--colpos (str ncols)
  "Return the index in screen line STR of each of NCOLS columns' text."
  (let ((v (make-vector ncols 0)))
    (dotimes (i (length str))
      (let ((id (get-text-property i 'mdwt-cell str)))
        (when (and id (zerop (aref v (cdr id)))) (aset v (cdr id) (1+ i)))))
    v))

(defun mdwt--build (beg end indent lines avail face)
  "Create the container and slice overlays for the table BEG..END.
LINES are its source lines and INDENT its leading whitespace; it is
rendered to AVAIL columns, with FACE (if non-nil) as the base face."
  (let* ((rendered (mdwt--render-lines lines indent avail))
         (strs (vconcat (mapcar (lambda (x)
                                  (let ((s (car x)))
                                    (when face (add-face-text-property 0 (length s) face t s))
                                    s))
                                rendered)))
         (rows (vconcat (mapcar #'cdr rendered)))
         (ncols (apply #'max (mapcar #'length (mdwt--rows lines))))
         (tbl (make-overlay beg end nil t nil))
         (n (max 1 (min (length strs) (- end beg))))
         (slices (make-vector n nil)))
    (overlay-put tbl 'mdwt t)
    (overlay-put tbl 'evaporate t)
    (overlay-put tbl 'mdwt-src (list lines indent avail face))
    (overlay-put tbl 'mdwt-shape (cons (1- (length lines)) ncols))
    (overlay-put tbl 'mdwt-widths (nth 2 (mdwt--layout lines indent avail)))
    (overlay-put tbl 'mdwt-strs strs)
    (overlay-put tbl 'mdwt-rows rows)
    (overlay-put tbl 'mdwt-colpos
                 (mdwt--colpos (aref strs (cl-position-if #'identity rows)) ncols))
    (dotimes (i n)
      (let ((s (make-overlay (+ beg i) (if (= i (1- n)) end (+ beg i 1)))))
        (overlay-put s 'mdwt-slice t)
        (overlay-put s 'mdwt-index i)
        (overlay-put s 'evaporate t)
        (aset slices i s)))
    (overlay-put tbl 'mdwt-slices slices)
    (mdwt--paint tbl)
    tbl))

(defun mdwt--line-string (tbl k)
  "Screen line K of TBL, with the cell highlight and cursor if they are there."
  (let ((s (aref (overlay-get tbl 'mdwt-strs) k)))
    (if (not (and (eq tbl mdwt--cell-ov) mdwt--cell))
        s
      (setq s (copy-sequence s))
      (let (seg-beg seg-end)
        (when (eql (aref (overlay-get tbl 'mdwt-rows) k) (car mdwt--cell))
          (let ((i 0) (len (length s)))
            (while (< i len)
              (let ((nx (next-single-property-change i 'mdwt-cell s len)))
                (when (equal (get-text-property i 'mdwt-cell s) mdwt--cell)
                  (setq seg-beg i seg-end nx)
                  (add-face-text-property i nx (if mdwt--ip-text 'mdwt-editing-cell 'mdwt-current-cell)
                                          nil s))
                (setq i nx)))))
        (when (eql k mdwt--line)
          (let ((pos (if (and mdwt--ip-text seg-beg)
                         ;; In-place editing: the character at the edit offset.
                         ;; Wrapped lines never start with a space, so the
                         ;; segment's leading blanks are the alignment padding.
                         (let ((pad (or (string-match-p "[^ ]" (substring s (1+ seg-beg) seg-end)) 0)))
                           (min (+ seg-beg 1 pad mdwt--ip-col) (1- seg-end)))
                       (aref (overlay-get tbl 'mdwt-colpos) (cdr mdwt--cell)))))
            (setq pos (min pos (1- (length s))))
            (put-text-property pos (1+ pos) 'cursor t s))))
      s)))

(defun mdwt--paint (tbl)
  "Draw every screen line of TBL, unless TBL is revealed as raw source."
  (when (and tbl (overlay-buffer tbl) (not (eq tbl mdwt--revealed)))
    (let* ((slices (overlay-get tbl 'mdwt-slices))
           (n (length slices))
           (last (1- (length (overlay-get tbl 'mdwt-strs)))))
      (dotimes (i n)
        (overlay-put (aref slices i) 'display
                     (if (< i (1- n))
                         (concat (mdwt--line-string tbl i) "\n")
                       (mapconcat (lambda (k) (mdwt--line-string tbl k))
                                  (number-sequence i last) "\n")))))))

(defun mdwt-refresh ()
  "Re-render every pipe table in the buffer."
  (interactive)
  (let* ((avail (mdwt--avail))
         (face (and (facep 'markdown-table-face) 'markdown-table-face))
         (here (mdwt--table-at-point))
         ;; Keep the raw table being edited, or the cell cursor, across re-renders.
         (keep (and here (eq here mdwt--revealed)))
         (state (and mdwt--cell-ov (eq (mdwt--table-under-point) mdwt--cell-ov)
                     (list (car mdwt--cell) (cdr mdwt--cell)
                           (max 0 (- mdwt--line (mdwt--row-first mdwt--cell-ov (car mdwt--cell))))))))
    (setq mdwt--cell-ov nil mdwt--line nil mdwt--painted nil)
    (save-excursion
      (save-restriction
        (widen)
        (remove-overlays (point-min) (point-max) 'mdwt t)
        (remove-overlays (point-min) (point-max) 'mdwt-slice t)
        (setq mdwt--revealed nil)
        (pcase-dolist (`(,beg ,end ,indent ,lines) (mdwt--tables))
          (mdwt--build beg end indent lines avail face))))
    (cond ((and keep (setq here (mdwt--table-at-point))) (mdwt--show here))
          (state
           (when-let* ((tbl (mdwt--table-under-point)))
             (pcase-let* ((`(,r ,c ,off) state)
                          (`(,nr . ,nc) (overlay-get tbl 'mdwt-shape))
                          (r (min r (1- nr)))
                          (first (mdwt--row-first tbl r))
                          (k (+ first off)))
               (unless (eql (aref (overlay-get tbl 'mdwt-rows) (min k (1- (mdwt--reachable tbl)))) r)
                 (setq k first))
               (setq mdwt--cell-ov tbl mdwt--cell (cons r (min c (1- nc))))
               (mdwt--goto-line tbl k))))))
  (mdwt--reveal))

(defun mdwt--table-at-point ()
  "The table whose source lines include point's line, or nil."
  (cl-find-if (lambda (o) (overlay-get o 'mdwt))
              (overlays-in (line-beginning-position) (line-end-position))))

(defun mdwt--table-under-point ()
  "The table overlay containing point, or nil."
  (cl-find-if (lambda (o) (overlay-get o 'mdwt)) (overlays-at (point))))

(defun mdwt--show (tbl)
  "Display the raw source under TBL."
  (mdwt--hide mdwt--revealed)
  (when (eq tbl mdwt--cell-ov) (mdwt--leave))
  (setq mdwt--revealed tbl)
  (mapc (lambda (s) (overlay-put s 'display nil)) (overlay-get tbl 'mdwt-slices)))

(defun mdwt--hide (tbl)
  "Display the rendered table for TBL again."
  (when (eq tbl mdwt--revealed) (setq mdwt--revealed nil))
  (mdwt--paint tbl))

(defun mdwt--reveal ()
  "Post-command: re-render a raw table point left, then track the cursor.
With `mdwt-reveal-at-point', also reveal any table point moves onto."
  (let ((here (mdwt--table-at-point)))
    (unless (eq here mdwt--revealed)
      (mdwt--hide mdwt--revealed)
      (when (and here mdwt-reveal-at-point) (mdwt--show here))))
  (when mdwt--ip-text (mdwt--ip-check))
  (mdwt--track))

;;;; Cell cursor

(defun mdwt--reachable (tbl)
  "Number of screen lines of TBL that point can reach."
  (length (overlay-get tbl 'mdwt-slices)))

(defun mdwt--content-from (tbl k dir)
  "First non-rule screen line of TBL from K stepping DIR, or nil."
  (let ((rows (overlay-get tbl 'mdwt-rows))
        (n (mdwt--reachable tbl)))
    (while (and (>= k 0) (< k n) (null (aref rows k))) (setq k (+ k dir)))
    (and (>= k 0) (< k n) k)))

(defun mdwt--row-first (tbl r)
  "Index of the first screen line of row R in TBL."
  (or (cl-position r (overlay-get tbl 'mdwt-rows)) 0))

(defun mdwt--goto-line (tbl k)
  "Move point to screen line K of table TBL."
  (let ((slices (overlay-get tbl 'mdwt-slices)))
    (goto-char (overlay-start (aref slices (max 0 (min k (1- (length slices)))))))))

(defun mdwt--track ()
  "Follow point into, through and out of rendered tables."
  (let* ((tbl (mdwt--table-under-point))
         (slice (and tbl (not (eq tbl mdwt--revealed))
                     (cl-find-if (lambda (o) (overlay-get o 'mdwt-slice)) (overlays-at (point))))))
    (if (not slice)
        (mdwt--leave)
      (let* ((k (overlay-get slice 'mdwt-index))
             (entering (not (eq tbl mdwt--cell-ov)))
             (n (mdwt--reachable tbl))
             (dir (if (< (* 2 k) n) 1 -1))
             (col (or mdwt--pending-col (if entering 0 (cdr mdwt--cell))))
             (content (or (mdwt--content-from tbl k dir) (mdwt--content-from tbl k (- dir)) k)))
        ;; Entering on a rule line: step onto the nearest row instead.
        (when entering (setq k content))
        (unless (eq tbl mdwt--cell-ov) (mdwt--leave))
        (setq mdwt--pending-col nil
              mdwt--cell-ov tbl
              mdwt--line k
              mdwt--cell (cons (or (aref (overlay-get tbl 'mdwt-rows) content) 0)
                               (min col (1- (cdr (overlay-get tbl 'mdwt-shape))))))
        (mdwt--goto-line tbl k)
        (let ((state (list tbl mdwt--cell k)))
          (unless (equal state mdwt--painted)
            (setq mdwt--painted state)
            (mdwt--paint tbl)))))))

(defun mdwt--leave ()
  "Drop the cell cursor, redrawing its table plainly."
  (when mdwt--cell-ov
    (let ((tbl mdwt--cell-ov))
      (setq mdwt--cell-ov nil mdwt--line nil mdwt--painted nil)
      (mdwt--paint tbl))))

(defun mdwt--exit (dir)
  "Leave the table: upward if DIR is negative, else downward."
  (let ((tbl mdwt--cell-ov))
    (if (< dir 0)
        (progn (goto-char (overlay-start tbl))
               (if (bobp) (user-error "Beginning of buffer") (forward-line -1)))
      (goto-char (overlay-end tbl))
      (unless (eobp) (forward-line 1)))))

(defun mdwt-cell-down ()
  "Move to the next screen line of the table, or leave it."
  (interactive)
  (let ((k (mdwt--content-from mdwt--cell-ov (1+ mdwt--line) 1)))
    (if k (mdwt--goto-line mdwt--cell-ov k) (mdwt--exit 1))))

(defun mdwt-cell-up ()
  "Move to the previous screen line of the table, or leave it."
  (interactive)
  (let ((k (mdwt--content-from mdwt--cell-ov (1- mdwt--line) -1)))
    (if k (mdwt--goto-line mdwt--cell-ov k) (mdwt--exit -1))))

(defun mdwt-cell-next ()
  "Move to the next cell; past the row's end, the next row's first cell."
  (interactive)
  (pcase-let ((`(,r . ,c) mdwt--cell)
              (`(,nr . ,nc) (overlay-get mdwt--cell-ov 'mdwt-shape)))
    (cond ((< c (1- nc)) (setq mdwt--cell (cons r (1+ c))))
          ((< r (1- nr)) (setq mdwt--pending-col 0)
           (mdwt--goto-line mdwt--cell-ov (mdwt--row-first mdwt--cell-ov (1+ r))))
          (t (mdwt--exit 1)))))

(defun mdwt-cell-prev ()
  "Move to the previous cell; past the row's start, the previous row's last."
  (interactive)
  (pcase-let ((`(,r . ,c) mdwt--cell)
              (`(_ . ,nc) (overlay-get mdwt--cell-ov 'mdwt-shape)))
    (cond ((> c 0) (setq mdwt--cell (cons r (1- c))))
          ((> r 0) (setq mdwt--pending-col (1- nc))
           (mdwt--goto-line mdwt--cell-ov (mdwt--row-first mdwt--cell-ov (1- r))))
          (t (mdwt--exit -1)))))

(defun mdwt-cell-first ()
  "Move to the first cell of the row."
  (interactive)
  (setq mdwt--cell (cons (car mdwt--cell) 0)))

(defun mdwt-cell-last ()
  "Move to the last cell of the row."
  (interactive)
  (setq mdwt--cell (cons (car mdwt--cell) (1- (cdr (overlay-get mdwt--cell-ov 'mdwt-shape))))))

(defun mdwt--text-lines (tbl cell)
  "Return the screen lines of TBL holding CELL's text (its first line if blank)."
  (let ((strs (overlay-get tbl 'mdwt-strs))
        (rows (overlay-get tbl 'mdwt-rows))
        found)
    (dotimes (k (mdwt--reachable tbl))
      (when (eql (aref rows k) (car cell))
        (let* ((s (aref strs k)) (len (length s)) (i 0) text)
          ;; Find CELL's segment (`equal', not `eq': ids are fresh conses).
          (while (< i len)
            (let ((nx (next-single-property-change i 'mdwt-cell s len)))
              (when (equal (get-text-property i 'mdwt-cell s) cell)
                (setq text (substring-no-properties s i nx)))
              (setq i nx)))
          (when (and text (string-match-p "[^ ]" text))
            (push k found)))))
    (or (nreverse found) (list (mdwt--row-first tbl (car cell))))))

(defun mdwt-cell-top ()
  "Move to the first screen line of the current cell's text."
  (interactive)
  (mdwt--goto-line mdwt--cell-ov (car (mdwt--text-lines mdwt--cell-ov mdwt--cell))))

(defun mdwt-cell-bottom ()
  "Move to the last screen line of the current cell's text."
  (interactive)
  (mdwt--goto-line mdwt--cell-ov (car (last (mdwt--text-lines mdwt--cell-ov mdwt--cell)))))

(defun mdwt-row-first ()
  "Move to the first row (the header) of the table, keeping the column."
  (interactive)
  (mdwt--goto-line mdwt--cell-ov (mdwt--row-first mdwt--cell-ov 0)))

(defun mdwt-row-last ()
  "Move to the last row of the table, keeping the column."
  (interactive)
  (mdwt--goto-line mdwt--cell-ov
                   (mdwt--row-first mdwt--cell-ov
                                    (1- (car (overlay-get mdwt--cell-ov 'mdwt-shape))))))

(defun mdwt-cell-blocked ()
  "Refuse to type into the rendered table."
  (interactive)
  (message (substitute-command-keys
            "\\<mdwt-cell-map>\\[mdwt-edit-cell] edits this cell; \
\\<mdwt-mode-map>\\[mdwt-toggle-source] shows the raw table")))

(defun mdwt-mouse-select (event)
  "Set point for mouse EVENT; on a table, select the cell clicked on."
  (interactive "e")
  (when mdwt--ip-text (mdwt--ip-finish t))
  (mouse-set-point event)
  (let* ((s (posn-string (event-start event)))
         (id (and s (cdr s) (get-text-property (cdr s) 'mdwt-cell (car s)))))
    (when id (setq mdwt--pending-col (cdr id)))))

(defun mdwt-mouse-edit (event)
  "Edit the table cell double-clicked on by mouse EVENT."
  (interactive "e")
  (mdwt-mouse-select event)
  (mdwt--track)
  (when mdwt--cell-ov (mdwt-edit-cell)))

(defun mdwt--source-cell (tbl pos)
  "Return the (ROW . COL) of the cell of TBL at raw-source position POS."
  (save-excursion
    (goto-char pos)
    (let* ((li (count-lines (overlay-start tbl) (line-beginning-position)))
           (off (- pos (line-beginning-position)))
           (spans (mdwt--cell-spans (mdwt--line)))
           (c (or (cl-position-if (lambda (sp) (<= (car sp) off)) spans :from-end t) 0)))
      (cons (max 0 (1- li)) (min c (1- (cdr (overlay-get tbl 'mdwt-shape))))))))

(defun mdwt--source-pos (tbl r c)
  "Buffer position of cell (R . C)'s raw text in TBL."
  (save-excursion
    (goto-char (overlay-start tbl))
    (forward-line (if (= r 0) 0 (1+ r)))
    (let ((sp (nth c (mdwt--cell-spans (mdwt--line)))))
      (if sp (+ (line-beginning-position) (car sp)) (line-end-position)))))

(defun mdwt-toggle-source ()
  "Toggle between the rendered table and its raw source at point.
Point moves between a cell and that cell's source text.  The raw source
is re-rendered automatically when point leaves the table."
  (interactive)
  (let ((here (mdwt--table-at-point)))
    (cond ((null here) (user-error "No table at point"))
          ((eq here mdwt--revealed)
           (let ((cell (mdwt--source-cell here (point))))
             (mdwt--hide here)
             (setq mdwt--pending-col (cdr cell))
             (mdwt--goto-line here (mdwt--row-first here (car cell)))
             (mdwt--track)))
          (t
           (let ((cell (and (eq here mdwt--cell-ov) mdwt--cell)))
             (mdwt--show here)
             (when cell (goto-char (mdwt--source-pos here (car cell) (cdr cell)))))))))

(defvar-keymap mdwt-cell-map
  :doc "Keys active while point is in a rendered table."
  "TAB" #'mdwt-cell-next
  "<backtab>" #'mdwt-cell-prev
  "RET" #'mdwt-edit-cell
  "<remap> <forward-char>" #'mdwt-cell-next
  "<remap> <right-char>" #'mdwt-cell-next
  "<remap> <backward-char>" #'mdwt-cell-prev
  "<remap> <left-char>" #'mdwt-cell-prev
  "<remap> <next-line>" #'mdwt-cell-down
  "<remap> <previous-line>" #'mdwt-cell-up
  "C-a" #'mdwt-cell-top
  "C-e" #'mdwt-cell-bottom
  "<remap> <move-beginning-of-line>" #'mdwt-cell-top
  "<remap> <move-end-of-line>" #'mdwt-cell-bottom
  "<remap> <beginning-of-visual-line>" #'mdwt-cell-top
  "<remap> <end-of-visual-line>" #'mdwt-cell-bottom
  "M-a" #'mdwt-cell-first
  "M-e" #'mdwt-cell-last
  "C-M-a" #'mdwt-row-first
  "C-M-e" #'mdwt-row-last
  "<remap> <self-insert-command>" #'mdwt-cell-type
  "<remap> <org-self-insert-command>" #'mdwt-cell-type
  "DEL" #'mdwt-cell-type-backspace
  "<backspace>" #'mdwt-cell-type-backspace
  "<remap> <delete-backward-char>" #'mdwt-cell-type-backspace
  "<remap> <delete-char>" #'mdwt-cell-blocked
  "<remap> <delete-forward-char>" #'mdwt-cell-blocked
  "<remap> <kill-line>" #'mdwt-cell-blocked
  "<remap> <yank>" #'mdwt-cell-blocked)

(defvar-keymap mdwt-inplace-map
  :doc "Keys active while a cell is edited in place."
  "<remap> <self-insert-command>" #'mdwt-ip-insert
  "<remap> <org-self-insert-command>" #'mdwt-ip-insert
  "DEL" #'mdwt-ip-delete-backward
  "<backspace>" #'mdwt-ip-delete-backward
  "<remap> <delete-backward-char>" #'mdwt-ip-delete-backward
  "C-d" #'mdwt-ip-delete-forward
  "<delete>" #'mdwt-ip-delete-forward
  "<remap> <delete-char>" #'mdwt-ip-delete-forward
  "<remap> <delete-forward-char>" #'mdwt-ip-delete-forward
  "C-f" #'mdwt-ip-forward-char
  "<right>" #'mdwt-ip-forward-char
  "<remap> <forward-char>" #'mdwt-ip-forward-char
  "<remap> <right-char>" #'mdwt-ip-forward-char
  "C-b" #'mdwt-ip-backward-char
  "<left>" #'mdwt-ip-backward-char
  "<remap> <backward-char>" #'mdwt-ip-backward-char
  "<remap> <left-char>" #'mdwt-ip-backward-char
  "M-f" #'mdwt-ip-forward-word
  "<remap> <forward-word>" #'mdwt-ip-forward-word
  "M-b" #'mdwt-ip-backward-word
  "<remap> <backward-word>" #'mdwt-ip-backward-word
  "C-n" #'mdwt-ip-next-line
  "<down>" #'mdwt-ip-next-line
  "<remap> <next-line>" #'mdwt-ip-next-line
  "C-p" #'mdwt-ip-previous-line
  "<up>" #'mdwt-ip-previous-line
  "<remap> <previous-line>" #'mdwt-ip-previous-line
  "C-a" #'mdwt-ip-line-start
  "<home>" #'mdwt-ip-line-start
  "<remap> <move-beginning-of-line>" #'mdwt-ip-line-start
  "C-e" #'mdwt-ip-line-end
  "<end>" #'mdwt-ip-line-end
  "<remap> <move-end-of-line>" #'mdwt-ip-line-end
  "C-k" #'mdwt-ip-kill-line
  "<remap> <kill-line>" #'mdwt-ip-kill-line
  "C-y" #'mdwt-ip-yank
  "<remap> <yank>" #'mdwt-ip-yank
  "<remap> <undo>" #'mdwt-ip-undo
  "<remap> <undo-only>" #'mdwt-ip-undo
  "<remap> <undo-redo>" #'mdwt-ip-undo
  "RET" #'mdwt-ip-commit
  "C-c C-c" #'mdwt-ip-commit
  "TAB" #'mdwt-ip-commit-next
  "<backtab>" #'mdwt-ip-commit-prev
  "C-g" #'mdwt-ip-cancel
  "C-c C-k" #'mdwt-ip-cancel
  "<remap> <keyboard-quit>" #'mdwt-ip-cancel)

;; Emulation maps outrank major- and minor-mode maps, so TAB/RET reach us
;; even in modes (and with packages) that bind them.  In-place editing
;; keys come first; anything they don't bind falls through to cell keys.
(defvar mdwt--emulation-alist `((mdwt--ip-text . ,mdwt-inplace-map)
                                (mdwt--cell-ov . ,mdwt-cell-map)))
(add-to-list 'emulation-mode-map-alists 'mdwt--emulation-alist)

;;;; Cell editing

(defvar-local mdwt--edit-origin nil "(MARKER ROW COL) of the cell being edited.")

(defvar-keymap mdwt-cell-edit-mode-map
  "C-c C-c" #'mdwt-edit-commit
  "C-c C-k" #'mdwt-edit-abort)

(define-minor-mode mdwt-cell-edit-mode
  "Minor mode for the buffer editing one table cell."
  :lighter " Cell")

(defun mdwt-edit-cell ()
  "Edit the text of the current cell, as set by `mdwt-edit-method'."
  (interactive)
  (unless mdwt--cell-ov (user-error "No table cell selected"))
  (pcase-let* ((`(,row . ,col) mdwt--cell)
               (lines (car (overlay-get mdwt--cell-ov 'mdwt-src)))
               (text (or (nth col (nth row (mdwt--rows lines))) ""))
               (origin (list (copy-marker (overlay-start mdwt--cell-ov)) row col)))
    (pcase mdwt-edit-method
      ('inplace (set-marker (car origin) nil) (mdwt--ip-start))
      ('minibuffer (mdwt--edit-in-minibuffer origin text))
      (_ (mdwt--edit-in-buffer origin text)))))

(defun mdwt--edit-in-minibuffer (origin text)
  "Read new TEXT for the cell at ORIGIN in the minibuffer and save it."
  (let ((new (condition-case nil
                 (read-from-minibuffer
                  (format "Cell (%d, %d): " (nth 1 origin) (1+ (nth 2 origin)))
                  text)
               (quit (set-marker (car origin) nil) nil))))
    (when new (mdwt--commit origin new))))

(defun mdwt--editor-window (buf)
  "Show BUF in a window directly below the selected (table) window."
  (or (get-buffer-window buf)
      (let ((win (condition-case nil
                     (split-window nil (- (max window-min-height mdwt-edit-window-height)) 'below)
                   ;; Table window too small to split: let Emacs choose.
                   (error nil))))
        (if (not win)
            (display-buffer buf)
          (set-window-buffer win buf)
          (set-window-parameter win 'mdwt-editor t)
          win))))

(defun mdwt--close-editor ()
  "Kill the cell edit buffer; delete its window if we created it."
  (let ((win (selected-window))
        (buf (current-buffer)))
    (if (and (window-parameter win 'mdwt-editor) (not (one-window-p t)))
        (delete-window win)
      (quit-window nil win))
    (kill-buffer buf)))

(defun mdwt--edit-in-buffer (origin text)
  "Open the cell at ORIGIN, holding TEXT, in an edit window below the table."
  (let ((buf (get-buffer-create "*mdwt cell*")))
    (with-current-buffer buf
      (erase-buffer)
      (funcall (if (fboundp 'gfm-mode) #'gfm-mode #'text-mode))
      (insert text)
      (visual-line-mode 1)
      (mdwt-cell-edit-mode 1)
      (setq mdwt--edit-origin origin)
      (setq header-line-format
            (substitute-command-keys
             "\\<mdwt-cell-edit-mode-map>Edit cell: \\[mdwt-edit-commit] save, \\[mdwt-edit-abort] cancel"))
      (set-buffer-modified-p nil)
      (goto-char (point-max)))
    (select-window (mdwt--editor-window buf))))

(defun mdwt--cell-source (text)
  "Turn edited TEXT into one line of pipe-table cell source."
  (string-replace "|" "\\|"
                  (string-trim (replace-regexp-in-string "[ \t]*\n[ \t\n]*" " " text))))

(defun mdwt--write-cell (marker row col src)
  "Replace cell (ROW . COL) of the table starting at MARKER with SRC."
  (save-excursion
    (goto-char marker)
    (forward-line (if (= row 0) 0 (1+ row)))
    (let ((line (mdwt--line))
          (lbp (line-beginning-position)))
      (unless (string-match-p "\\`[ \t]*|" line)
        (user-error "Table changed since editing started; cell not saved"))
      (let ((spans (mdwt--cell-spans line)))
        (if (< col (length spans))
            (pcase-let ((`(,s . ,e) (nth col spans)))
              (unless (equal src (substring line s e))
                (goto-char (+ lbp s))
                (delete-region (+ lbp s) (+ lbp e))
                (insert (if (eq (char-before) ?|) " " "")
                        src
                        (if (eq (char-after) ?|) " " ""))))
          ;; Short row: append the missing cells.
          (goto-char (line-end-position))
          (skip-chars-backward " \t")
          (unless (eq (char-before) ?|) (insert " |"))
          (cl-loop for k from (length spans) to col
                   do (insert (if (= k col) (concat " " src " |") " |"))))))))

(defun mdwt-edit-commit ()
  "Write the edited cell back into the table and close the edit buffer."
  (interactive)
  (let ((origin mdwt--edit-origin)
        (text (buffer-string)))
    (unless (buffer-live-p (marker-buffer (car origin)))
      (user-error "The table's buffer is gone"))
    (mdwt--close-editor)
    (mdwt--commit origin text)))

(defun mdwt--commit (origin text &optional keep-point)
  "Write TEXT into the cell at ORIGIN, (MARKER ROW COL), and re-render.
Unless KEEP-POINT, put point back in the table if the edit moved it out."
  (pcase-let* ((`(,marker ,row ,col) origin)
               (buf (marker-buffer marker)))
    (with-current-buffer buf (mdwt--write-cell marker row col (mdwt--cell-source text)))
    (when-let* ((win (get-buffer-window buf))) (select-window win))
    (with-current-buffer buf
      ;; Point may have shifted with the edit; put it back in the table so
      ;; the refresh restores the cell cursor.
      (unless (or keep-point (mdwt--table-under-point)) (goto-char marker))
      (set-marker marker nil)
      (when mdwt-mode (mdwt-refresh)))))

(defun mdwt-edit-abort ()
  "Close the cell edit buffer without saving."
  (interactive)
  (set-marker (car mdwt--edit-origin) nil)
  (mdwt--close-editor))

;;;; In-place editing
;;
;; The text being edited lives in `mdwt--ip-text'; the buffer is untouched
;; until the edit is saved.  Each keystroke re-renders only this table
;; from its source lines with the cell's text substituted, and
;; `mdwt--wrap-map' locates the edit offset on the wrapped lines so the
;; cursor can be drawn there.

(defvar-local mdwt--ip-history nil "Earlier (TEXT . OFFSET) states, for undo.")

(defun mdwt--set-cell-in-line (line col src)
  "Return table LINE with cell COL's text replaced by SRC."
  (let ((spans (mdwt--cell-spans line)))
    (if (< col (length spans))
        (pcase-let ((`(,s . ,e) (nth col spans)))
          (concat (substring line 0 s)
                  (if (and (> s 0) (eq (aref line (1- s)) ?|)) " " "")
                  src
                  (if (and (< e (length line)) (eq (aref line e) ?|)) " " "")
                  (substring line e)))
      (let ((base (string-trim-right line)))
        (concat base (if (string-suffix-p "|" base) "" " |")
                (mapconcat (lambda (k) (if (= k col) (concat " " src " |") " |"))
                           (number-sequence (length spans) col) ""))))))

(defun mdwt--delete-table (tbl)
  "Delete table TBL's container and slice overlays."
  (mapc #'delete-overlay (overlay-get tbl 'mdwt-slices))
  (delete-overlay tbl))

(defun mdwt--ip-start (&optional at-start)
  "Start editing the current cell in place, at its end (or AT-START)."
  (let* ((cell mdwt--cell)
         (lines (car (overlay-get mdwt--cell-ov 'mdwt-src)))
         (text (or (nth (cdr cell) (nth (car cell) (mdwt--rows lines))) "")))
    (setq mdwt--ip-text text
          mdwt--ip-off (if at-start 0 (length text))
          mdwt--ip-cell cell
          mdwt--ip-lines lines
          mdwt--ip-history nil)
    (mdwt--ip-render)
    (message (substitute-command-keys
              "\\<mdwt-inplace-map>Editing cell: \\[mdwt-ip-commit] or \\[mdwt-ip-commit-next] save, \\[mdwt-ip-cancel] cancel"))))

(defun mdwt--ip-map ()
  "(LINES . MAP) of the edited text wrapped to its column's current width."
  (mdwt--wrap-map mdwt--ip-text
                  (nth (cdr mdwt--ip-cell) (overlay-get mdwt--cell-ov 'mdwt-widths))))

(defun mdwt--ip-render ()
  "Redraw the edited table with the in-progress text; put the cursor at the offset."
  (pcase-let* ((old mdwt--cell-ov)
               (`(_ ,indent ,avail ,face) (overlay-get old 'mdwt-src))
               (`(,r . ,c) mdwt--ip-cell)
               (li (if (= r 0) 0 (1+ r)))
               (lines (copy-sequence mdwt--ip-lines))
               (beg (overlay-start old))
               (end (overlay-end old)))
    (setf (nth li lines)
          (mdwt--set-cell-in-line (nth li lines) c (string-replace "|" "\\|" mdwt--ip-text)))
    (mdwt--delete-table old)
    (setq mdwt--cell-ov (mdwt--build beg end indent lines avail face))
    (pcase-let* ((`(,wl . ,map) (mdwt--ip-map))
                 (`(,l . ,ci) (aref map mdwt--ip-off)))
      (setq mdwt--cell mdwt--ip-cell
            mdwt--ip-col ci
            mdwt--line (+ (mdwt--row-first mdwt--cell-ov r) (min l (1- (length wl)))))
      (mdwt--goto-line mdwt--cell-ov mdwt--line)
      (setq mdwt--painted (list mdwt--cell-ov mdwt--cell mdwt--line))
      (mdwt--paint mdwt--cell-ov))))

(defun mdwt--ip-edit (text off)
  "Replace the edited text with TEXT, offset OFF, keeping undo history."
  (push (cons mdwt--ip-text mdwt--ip-off) mdwt--ip-history)
  (setq mdwt--ip-text text mdwt--ip-off off)
  (mdwt--ip-render))

(defun mdwt--ip-move (off)
  "Move the in-place edit cursor to offset OFF (clamped)."
  (setq mdwt--ip-off (max 0 (min off (length mdwt--ip-text))))
  (mdwt--ip-render))

(defun mdwt--ip-finish (&optional keep-point)
  "Save the in-place edit into the table source.
With KEEP-POINT, don't pull point back into the table afterwards."
  (let ((origin (list (copy-marker (overlay-start mdwt--cell-ov))
                      (car mdwt--ip-cell) (cdr mdwt--ip-cell)))
        (text mdwt--ip-text))
    (setq mdwt--ip-text nil mdwt--ip-history nil)
    (mdwt--commit origin text keep-point)))

(defun mdwt--ip-check ()
  "Post-command: save the in-place edit if point or the cell cursor left it."
  (let* ((tbl (mdwt--table-under-point))
         (slice (and (eq tbl mdwt--cell-ov)
                     (cl-find-if (lambda (o) (overlay-get o 'mdwt-slice)) (overlays-at (point)))))
         (k (and slice (overlay-get slice 'mdwt-index)))
         (rows (and k (overlay-get tbl 'mdwt-rows))))
    (cond ((null k) (mdwt--ip-finish t))
          ((and (eql (aref rows k) (car mdwt--ip-cell))
                (equal mdwt--cell mdwt--ip-cell)
                (null mdwt--pending-col)))
          (t
           ;; Moved elsewhere in the table: save, then land where it went.
           (let ((content (or (mdwt--content-from tbl k 1) (mdwt--content-from tbl k -1) k)))
             (setq mdwt--line k
                   mdwt--cell (cons (or (aref rows content) 0)
                                    (or mdwt--pending-col (cdr mdwt--cell)))
                   mdwt--pending-col nil)
             (mdwt--ip-finish))))))

(defun mdwt-ip-insert (n)
  "Insert the typed character N times into the cell."
  (interactive "p")
  (when (characterp last-command-event)
    (let ((o mdwt--ip-off) (tx mdwt--ip-text))
      (mdwt--ip-edit (concat (substring tx 0 o) (make-string n last-command-event) (substring tx o))
                     (+ o n)))))

(defun mdwt-ip-delete-backward (n)
  "Delete N characters before the cursor."
  (interactive "p")
  (let* ((o mdwt--ip-off) (b (max 0 (- o n))) (tx mdwt--ip-text))
    (mdwt--ip-edit (concat (substring tx 0 b) (substring tx o)) b)))

(defun mdwt-ip-delete-forward (n)
  "Delete N characters after the cursor."
  (interactive "p")
  (let* ((o mdwt--ip-off) (tx mdwt--ip-text) (e (min (length tx) (+ o n))))
    (mdwt--ip-edit (concat (substring tx 0 o) (substring tx e)) o)))

(defun mdwt-ip-forward-char (n) "Move N characters right." (interactive "p") (mdwt--ip-move (+ mdwt--ip-off n)))
(defun mdwt-ip-backward-char (n) "Move N characters left." (interactive "p") (mdwt--ip-move (- mdwt--ip-off n)))

(defun mdwt-ip-forward-word ()
  "Move to the end of the next word."
  (interactive)
  (mdwt--ip-move (if (string-match "\\W*\\w+" mdwt--ip-text mdwt--ip-off)
                     (match-end 0)
                   (length mdwt--ip-text))))

(defun mdwt-ip-backward-word ()
  "Move to the start of the previous word."
  (interactive)
  (let ((o mdwt--ip-off) (tx mdwt--ip-text))
    (while (and (> o 0) (not (eq (char-syntax (aref tx (1- o))) ?w))) (cl-decf o))
    (while (and (> o 0) (eq (char-syntax (aref tx (1- o))) ?w)) (cl-decf o))
    (mdwt--ip-move o)))

(defun mdwt--ip-offsets-on (map l)
  "Offsets whose MAP position is on wrapped line L."
  (cl-loop for i below (length map) when (= (car (aref map i)) l) collect i))

(defun mdwt-ip-line-start ()
  "Move to the start of the cell's current wrapped line."
  (interactive)
  (let ((map (cdr (mdwt--ip-map))))
    (mdwt--ip-move (car (mdwt--ip-offsets-on map (car (aref map mdwt--ip-off)))))))

(defun mdwt-ip-line-end ()
  "Move to the end of the cell's current wrapped line."
  (interactive)
  (let ((map (cdr (mdwt--ip-map))))
    (mdwt--ip-move (car (last (mdwt--ip-offsets-on map (car (aref map mdwt--ip-off))))))))

(defun mdwt--ip-vertical (d)
  "Move D wrapped lines within the cell, keeping the column; nil at an edge."
  (pcase-let* ((`(,wl . ,map) (mdwt--ip-map))
               (`(,l . ,ci) (aref map mdwt--ip-off))
               (target (+ l d)))
    (when (and (>= target 0) (< target (length wl)))
      (let ((offs (mdwt--ip-offsets-on map target)))
        (mdwt--ip-move (or (car (last (cl-remove-if (lambda (i) (> (cdr (aref map i)) ci)) offs)))
                           (car offs)))
        t))))

(defun mdwt-ip-next-line ()
  "Move down a wrapped line in the cell; from its last line, save and move on."
  (interactive)
  (unless (mdwt--ip-vertical 1) (mdwt--ip-finish) (mdwt-cell-down)))

(defun mdwt-ip-previous-line ()
  "Move up a wrapped line in the cell; from its first line, save and move on."
  (interactive)
  (unless (mdwt--ip-vertical -1) (mdwt--ip-finish) (mdwt-cell-up)))

(defun mdwt-ip-kill-line ()
  "Kill the cell text from the cursor to its end."
  (interactive)
  (kill-new (substring mdwt--ip-text mdwt--ip-off))
  (mdwt--ip-edit (substring mdwt--ip-text 0 mdwt--ip-off) mdwt--ip-off))

(defun mdwt-ip-yank ()
  "Insert the last killed text (line breaks become spaces)."
  (interactive)
  (let ((s (replace-regexp-in-string "[ \t]*\n[ \t\n]*" " " (current-kill 0)))
        (o mdwt--ip-off) (tx mdwt--ip-text))
    (mdwt--ip-edit (concat (substring tx 0 o) s (substring tx o)) (+ o (length s)))))

(defun mdwt-ip-undo ()
  "Undo the last change to the cell text."
  (interactive)
  (if (null mdwt--ip-history)
      (message "No further undo information for this cell")
    (pcase-let ((`(,tx . ,o) (pop mdwt--ip-history)))
      (setq mdwt--ip-text tx mdwt--ip-off o)
      (mdwt--ip-render))))

(defun mdwt-ip-commit ()
  "Save the cell into the table source."
  (interactive)
  (mdwt--ip-finish))

(defun mdwt-ip-commit-next ()
  "Save the cell and move to the next one."
  (interactive)
  (mdwt--ip-finish)
  (mdwt-cell-next))

(defun mdwt-ip-commit-prev ()
  "Save the cell and move to the previous one."
  (interactive)
  (mdwt--ip-finish)
  (mdwt-cell-prev))

(defun mdwt-ip-cancel ()
  "Discard the in-place edit."
  (interactive)
  (setq mdwt--ip-text nil mdwt--ip-history nil)
  (mdwt-refresh)
  (message "Cell edit cancelled"))

(defun mdwt-cell-type ()
  "Start editing the cell in place with the typed character.
See `mdwt-edit-method'; other methods refuse typing in the table."
  (interactive)
  (if (not (eq mdwt-edit-method 'inplace))
      (mdwt-cell-blocked)
    (mdwt--ip-start)
    (call-interactively #'mdwt-ip-insert)))

(defun mdwt-cell-type-backspace ()
  "Start editing the cell in place, deleting its last character."
  (interactive)
  (if (not (eq mdwt-edit-method 'inplace))
      (mdwt-cell-blocked)
    (mdwt--ip-start)
    (call-interactively #'mdwt-ip-delete-backward)))

;;;; Mode

(defun mdwt--refresh-buffer (buf)
  "Re-render the tables of BUF, keeping any in-place edit."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (when mdwt-mode
        (if (not mdwt--ip-text)
            (mdwt-refresh)
          ;; Mid in-place edit (e.g. the window was resized): re-render all
          ;; tables for the new width as if not editing, then redraw the
          ;; edited one with the in-progress text on top.
          (let ((text mdwt--ip-text))
            (setq mdwt--ip-text nil)
            (mdwt-refresh)
            (if (not (and mdwt--cell-ov (equal mdwt--cell mdwt--ip-cell)))
                (message "Table changed; in-place cell edit dropped")
              (setq mdwt--ip-text text)
              (mdwt--ip-render))))))))

(defun mdwt--schedule (&rest _)
  "Re-render this buffer's tables after `mdwt-delay' idle seconds."
  (when (timerp mdwt--timer) (cancel-timer mdwt--timer))
  (setq mdwt--timer
        (run-with-idle-timer mdwt-delay nil #'mdwt--refresh-buffer (current-buffer))))

(defun mdwt--on-resize (win)
  "Schedule a re-render of WIN's buffer after a size change."
  (with-current-buffer (window-buffer win) (mdwt--schedule)))

(defvar-keymap mdwt-mode-map
  :doc "Keymap for `mdwt-mode'."
  "<mouse-1>" #'mdwt-mouse-select
  "<double-mouse-1>" #'mdwt-mouse-edit)

;;;###autoload
(define-minor-mode mdwt-mode
  "Display pipe tables with word-wrapped multi-line cells (display only).
In a table the cursor moves cell by cell and line by line:
\\<mdwt-cell-map>\\[mdwt-cell-next] next cell, \\[mdwt-edit-cell] edit the cell.
\\{mdwt-mode-map}"
  :lighter " ⊞"
  (if mdwt-mode
      (progn
        (add-hook 'after-change-functions #'mdwt--schedule nil t)
        (add-hook 'post-command-hook #'mdwt--reveal nil t)
        (add-hook 'window-size-change-functions #'mdwt--on-resize nil t)
        (mdwt-refresh))
    (remove-hook 'after-change-functions #'mdwt--schedule t)
    (remove-hook 'post-command-hook #'mdwt--reveal t)
    (remove-hook 'window-size-change-functions #'mdwt--on-resize t)
    (when (timerp mdwt--timer) (cancel-timer mdwt--timer))
    (setq mdwt--ip-text nil)
    (mdwt--leave)
    (save-restriction
      (widen)
      (remove-overlays (point-min) (point-max) 'mdwt t)
      (remove-overlays (point-min) (point-max) 'mdwt-slice t))
    (setq mdwt--revealed nil)))

(defun mdwt-version ()
  "Show the loaded mdwt version and the file it came from."
  (interactive)
  (message "mdwt %s loaded from %s" mdwt-version mdwt--load-file))

(defun mdwt-unload-function ()
  "Turn `mdwt-mode' off everywhere, so that no stale hooks survive unloading."
  (dolist (buf (buffer-list))
    (with-current-buffer buf
      (when mdwt-mode (mdwt-mode -1))))
  (setq emulation-mode-map-alists
        (delq 'mdwt--emulation-alist emulation-mode-map-alists))
  nil)

(provide 'mdwt)
(mdwt-version)
;;; mdwt.el ends here
