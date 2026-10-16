;;; mdwt-test.el --- Tests for mdwt  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Mo Hossny

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; ERT tests for mdwt.  Run with `make test', or:
;;
;;   emacs -Q --batch -L . -l test/mdwt-test.el \
;;         -f ert-run-tests-batch-and-exit
;;
;; Display itself cannot be observed in batch mode, so the tests inspect
;; the overlays' display strings, the `cursor' property placement, point
;; and the cell-cursor state the package keeps.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'mdwt)

;;;; Helpers

(defmacro mdwt-test--check (label form)
  "Assert FORM, reporting LABEL if it fails."
  (declare (indent 1))
  `(ert-info (,label) (should ,form)))

(defun mdwt-test--cmd (fn &optional char)
  "Run command FN as if typed (as CHAR), then the post-command hook.
Table commands are skipped once the cursor has left the table, as their
keymap would then be inactive."
  (when (or mdwt--cell-ov (eq fn 'mdwt-toggle-source))
    (let ((last-command-event (or char last-command-event)))
      (call-interactively fn)))
  (mdwt--reveal))

(defun mdwt-test--slice-display ()
  "Display string of the slice overlay at point."
  (overlay-get (cl-find-if (lambda (o) (overlay-get o 'mdwt-slice)) (overlays-at (point)))
               'display))

(defun mdwt-test--cursor-col ()
  "Index of the `cursor' property in the current screen line."
  (let ((s (mdwt-test--slice-display)))
    (text-property-any 0 (length s) 'cursor t s)))

(defun mdwt-test--char-under-cursor ()
  "Character the cursor is drawn on."
  (let* ((s (mdwt-test--slice-display))
         (p (text-property-any 0 (length s) 'cursor t s)))
    (and p (aref s p))))

(defun mdwt-test--shown ()
  "The current table as displayed."
  (mapconcat (lambda (s) (overlay-get s 'display)) (overlay-get mdwt--cell-ov 'mdwt-slices) ""))

(defun mdwt-test--faced-ids (face)
  "Cells drawn with FACE anywhere in the current table."
  (let (ids)
    (mapc (lambda (sl)
            (let ((s (overlay-get sl 'display)))
              (dotimes (i (length s))
                (when (memq face (ensure-list (get-text-property i 'face s)))
                  (cl-pushnew (get-text-property i 'mdwt-cell s) ids :test #'equal)))))
          (overlay-get mdwt--cell-ov 'mdwt-slices))
    ids))

(defun mdwt-test--edit-with (text &optional abort)
  "Edit the current cell in the edit buffer: replace with TEXT, save or ABORT.
Return the text the edit buffer started with."
  (let ((src (current-buffer)) initial)
    (mdwt-edit-cell)
    (with-current-buffer "*mdwt cell*"
      (setq initial (buffer-string))
      (erase-buffer)
      (insert text)
      (if abort (mdwt-edit-abort) (mdwt-edit-commit)))
    (set-buffer src)
    initial))

(defmacro mdwt-test--with-table (text &rest body)
  "Run BODY in a temp buffer holding TEXT with `mdwt-mode' on."
  (declare (indent 1))
  `(with-temp-buffer
     (buffer-enable-undo)
     (insert ,text)
     (mdwt-mode 1)
     ,@body))

(defconst mdwt-test--long
  (mapconcat #'identity (make-list 40 "word") " ")
  "A cell long enough to wrap over several lines.")

;;;; Parsing and layout

(ert-deftest mdwt-test-split-row ()
  (should (equal (mdwt--split-row "| a | b c |") '("a" "b c")))
  (should (equal (mdwt--split-row "| a \\| b | c |") '("a | b" "c")))
  (should (equal (mdwt--split-row "| `x|y` | c |") '("`x|y`" "c")))
  (should (equal (mdwt--split-row "  | a | b") '("a" "b")))
  (should (equal (mdwt--split-row "| a |  | c |") '("a" "" "c"))))

(ert-deftest mdwt-test-rule-order ()
  (let ((r (mdwt--render-lines '("| A | B |" "|---|---|" "| x | y |") "" 80)))
    (should (= (length r) 5))
    (should (string-prefix-p "+-" (car (nth 0 r))))
    (should (eql (cdr (nth 1 r)) 0))
    (should (string-prefix-p "+=" (car (nth 2 r))))
    (should (eql (cdr (nth 3 r)) 1))
    (should (string-prefix-p "+-" (car (nth 4 r))))))

(defun mdwt-test--reference-wrap (text width)
  "The original greedy wrapper, kept as a reference for TEXT and WIDTH."
  (cl-mapcan
   (lambda (piece)
     (let (lines (cur ""))
       (dolist (w (split-string piece "[ \t]+" t))
         (while (> (string-width w) width)
           (unless (string-empty-p cur) (push cur lines) (setq cur ""))
           (let ((head (truncate-string-to-width w width)))
             (when (string-empty-p head) (setq head (substring w 0 1)))
             (push head lines)
             (setq w (substring w (length head)))))
         (cond ((string-empty-p w))
               ((string-empty-p cur) (setq cur w))
               ((<= (+ (string-width cur) 1 (string-width w)) width)
                (setq cur (concat cur " " w)))
               (t (push cur lines) (setq cur w))))
       (unless (string-empty-p cur) (push cur lines))
       (or (nreverse lines) (list ""))))
   (mdwt--pieces text)))

(ert-deftest mdwt-test-wrap-map ()
  "The wrapper matches the reference and maps every character to its place."
  (random "mdwt")
  (let ((alphabet ["a" "bb" "ccc" "x" "longwordthatbreaks" " " " " "  "
                   "<br>" " <br/> " "é" "の"]))
    (dotimes (_ 3000)
      (let* ((text (apply #'concat (cl-loop repeat (random 12)
                                            collect (aref alphabet (random (length alphabet))))))
             (width (+ 3 (random 12)))
             (res (mdwt--wrap-map text width))
             (lines (car res))
             (map (cdr res))
             (tags nil)
             (p 0))
        (ert-info ((format "text %S width %d" text width))
          (should (equal lines (mdwt-test--reference-wrap text width)))
          (should (cl-every #'identity map))
          (while (string-match "[ \t]*<br[ \t]*/?>[ \t]*" text p)
            (push (cons (match-beginning 0) (match-end 0)) tags)
            (setq p (match-end 0)))
          (dotimes (i (length text))
            (unless (or (memq (aref text i) '(?\s ?\t))
                        (cl-some (lambda (tg) (and (>= i (car tg)) (< i (cdr tg)))) tags))
              (pcase-let ((`(,l . ,c) (aref map i)))
                (should (< l (length lines)))
                (should (< c (length (nth l lines))))
                (should (eq (aref (nth l lines) c) (aref text i)))))))))))

;;;; Cell cursor and navigation

(ert-deftest mdwt-test-navigation ()
  (let ((mdwt-edit-method 'buffer))
    (mdwt-test--with-table
        (concat "intro\n\n| H1 | H2 |\n|---|---|\n| a1 | " mdwt-test--long
                " |\n| b1 | b2 |\n\noutro\n")
      (let* ((tbl (progn (goto-char (point-min)) (forward-line 2) (mdwt--table-at-point)))
             (rows (overlay-get tbl 'mdwt-rows))
             (a-lines (cl-count 1 rows))
             (cmd #'mdwt-test--cmd))
        (mdwt-test--check "one slice per screen line"
          (= (length (overlay-get tbl 'mdwt-slices)) (length rows)))
        (mdwt-test--check "long cell wraps over several screen lines" (> a-lines 3))
        (goto-char (overlay-start tbl))
        (mdwt--reveal)
        (mdwt-test--check "entering from above: header row, line 1"
          (and (equal mdwt--cell '(0 . 0)) (= mdwt--line 1)))
        (mdwt-test--check "point is on a real slice start"
          (= (point) (1+ (overlay-start tbl))))
        (mdwt-test--check "cursor placed in cell 0's text"
          (= (mdwt-test--cursor-col) (aref (overlay-get tbl 'mdwt-colpos) 0)))
        (mdwt-test--check "header cell highlighted"
          (equal (mdwt-test--faced-ids 'mdwt-current-cell) '((0 . 0))))
        (mdwt-test--check "cell keys bound"
          (equal (mapcar (lambda (k) (key-binding (kbd k)))
                         '("TAB" "C-n" "x" "C-a" "C-e" "M-a" "M-e" "C-M-a" "C-M-e"))
                 '(mdwt-cell-next mdwt-cell-down mdwt-cell-type mdwt-cell-top mdwt-cell-bottom
                   mdwt-cell-first mdwt-cell-last mdwt-row-first mdwt-row-last)))
        (funcall cmd #'mdwt-cell-next)
        (mdwt-test--check "right: (0 . 1), same line"
          (and (equal mdwt--cell '(0 . 1)) (= mdwt--line 1)))
        (mdwt-test--check "cursor moved to column 1"
          (= (mdwt-test--cursor-col) (aref (overlay-get tbl 'mdwt-colpos) 1)))
        (funcall cmd #'mdwt-cell-down)
        (mdwt-test--check "down skips the === rule into row 1"
          (and (equal mdwt--cell '(1 . 1)) (= mdwt--line 3)))
        (funcall cmd #'mdwt-cell-down)
        (funcall cmd #'mdwt-cell-down)
        (mdwt-test--check "down moves line by line inside the tall cell"
          (and (equal mdwt--cell '(1 . 1)) (= mdwt--line 5)))
        (mdwt-test--check "whole tall cell highlighted, and only it"
          (equal (mdwt-test--faced-ids 'mdwt-current-cell) '((1 . 1))))
        (funcall cmd #'mdwt-cell-bottom)
        (mdwt-test--check "C-e: last screen line of the tall cell"
          (and (equal mdwt--cell '(1 . 1)) (= mdwt--line (+ 3 a-lines -1))))
        (funcall cmd #'mdwt-cell-top)
        (mdwt-test--check "C-a: first screen line of the tall cell"
          (and (equal mdwt--cell '(1 . 1)) (= mdwt--line 3)))
        (funcall cmd #'mdwt-cell-first)
        (mdwt-test--check "M-a: first cell of row" (equal mdwt--cell '(1 . 0)))
        (funcall cmd #'mdwt-cell-bottom)
        (mdwt-test--check "C-e on a one-line cell stays on its text line" (= mdwt--line 3))
        (funcall cmd #'mdwt-cell-last)
        (mdwt-test--check "M-e: last cell of row" (equal mdwt--cell '(1 . 1)))
        (funcall cmd #'mdwt-row-last)
        (mdwt-test--check "C-M-e: last row, same column" (equal mdwt--cell '(2 . 1)))
        (funcall cmd #'mdwt-row-first)
        (mdwt-test--check "C-M-a: header row, same column"
          (and (equal mdwt--cell '(0 . 1)) (= mdwt--line 1)))
        (dotimes (_ (1+ a-lines)) (funcall cmd #'mdwt-cell-down))
        (mdwt-test--check "down past the tall cell reaches row 2" (equal (car mdwt--cell) 2))
        (funcall cmd #'mdwt-cell-up)
        (mdwt-test--check "up goes to the last line of the tall cell"
          (and (equal (car mdwt--cell) 1) (= mdwt--line (+ 3 a-lines -1))))
        (funcall cmd #'mdwt-cell-first)
        (funcall cmd #'mdwt-cell-prev)
        (mdwt-test--check "left at row start: previous row's last cell, first line"
          (and (equal mdwt--cell '(0 . 1)) (= mdwt--line 1)))
        (funcall cmd #'mdwt-cell-next)
        (mdwt-test--check "TAB at row end: next row, first cell"
          (and (equal mdwt--cell '(1 . 0)) (= mdwt--line 3)))
        (dotimes (_ (+ a-lines 2)) (funcall cmd #'mdwt-cell-down))
        (mdwt-test--check "down past the last row leaves the table"
          (and (null mdwt--cell-ov) (looking-at "$")))
        (mdwt-test--check "leaving removes the cursor property"
          (cl-notany (lambda (sl) (let ((s (overlay-get sl 'display)))
                                    (text-property-any 0 (length s) 'cursor t s)))
                     (overlay-get tbl 'mdwt-slices)))
        (goto-char (overlay-start (aref (overlay-get tbl 'mdwt-slices) (1- (length rows)))))
        (mdwt--reveal)
        (mdwt-test--check "entering from below selects the last row"
          (equal (car mdwt--cell) 2))
        (goto-char (+ (overlay-start tbl) 6))
        (mdwt--reveal)
        (mdwt-test--check "landing on any line (scroll, click) tracks the row"
          (and (= mdwt--line 6) (equal (car mdwt--cell) 1)))))))

(ert-deftest mdwt-test-leave-at-end-of-buffer ()
  (mdwt-test--with-table "| A |\n|---|\n| x |"
    (goto-char (point-min))
    (mdwt--reveal)
    (mdwt-test--cmd #'mdwt-cell-down)
    (mdwt-test--cmd #'mdwt-cell-down)
    (should (null mdwt--cell-ov))))

(ert-deftest mdwt-test-toggle-source-and-refresh ()
  (mdwt-test--with-table "| A | B |\n|---|---|\n| x | yy zz |\n| b1 | b2 |\n"
    (goto-char (point-min))
    (mdwt--reveal)
    (mdwt-test--cmd #'mdwt-row-last)
    (mdwt-test--cmd #'mdwt-cell-last)
    (mdwt-test--cmd #'mdwt-toggle-source)
    (mdwt-test--check "raw source shown, point at the cell's source"
      (and (eq mdwt--revealed (mdwt--table-at-point)) (looking-at "b2")))
    (forward-char 1)
    (mdwt-test--cmd #'mdwt-toggle-source)
    (mdwt-test--check "toggling back selects the same cell"
      (and mdwt--cell-ov (equal mdwt--cell '(2 . 1))))
    (let ((line mdwt--line))
      (mdwt-refresh)
      (mdwt-test--check "refresh keeps cell and line"
        (and (equal mdwt--cell '(2 . 1)) (= mdwt--line line))))
    (mdwt-mode -1)
    (mdwt-test--check "mode off removes all overlays"
      (null (cl-remove-if-not (lambda (o) (or (overlay-get o 'mdwt) (overlay-get o 'mdwt-slice)))
                              (overlays-in (point-min) (point-max)))))))

;;;; Edit buffer and minibuffer methods

(ert-deftest mdwt-test-edit-buffer ()
  (let ((mdwt-edit-method 'buffer))
    (mdwt-test--with-table "| A | B |\n|---|---|\n| x | yy |\n| b1 | b2 |\n"
      (goto-char (point-min))
      (mdwt--reveal)
      (mdwt-test--cmd #'mdwt-row-last)
      (mdwt-test--cmd #'mdwt-cell-last)
      (mdwt-test--check "edit buffer holds the cell text"
        (equal (mdwt-test--edit-with "new | text\nsecond line") "b2"))
      (mdwt-test--check "edit written, pipe escaped, line break joined"
        (string-match-p "^| b1 | new \\\\| text second line |$" (buffer-string)))
      (mdwt-test--check "cell cursor restored on the edited cell"
        (equal mdwt--cell '(2 . 1)))
      (let ((before (buffer-string)))
        (mdwt-test--edit-with "zzz" t)
        (mdwt-test--check "abort leaves the source unchanged"
          (equal before (buffer-string)))))))

(ert-deftest mdwt-test-edit-short-row-and-empty-cell ()
  (let ((mdwt-edit-method 'buffer))
    (mdwt-test--with-table "| A | B | C |\n|---|---|---|\n| x |\n"
      (goto-char (point-min))
      (mdwt--reveal)
      (mdwt-test--cmd #'mdwt-cell-down)
      (mdwt-test--cmd #'mdwt-cell-last)
      (mdwt-test--edit-with "z")
      (should (string-match-p "^| x | | z |$" (buffer-string))))
    (mdwt-test--with-table "| A | B |\n|---|---|\n| x ||\n"
      (goto-char (point-min))
      (mdwt--reveal)
      (mdwt-test--cmd #'mdwt-cell-down)
      (mdwt-test--cmd #'mdwt-cell-next)
      (mdwt-test--edit-with "y")
      (should (string-match-p "^| x | y |$" (buffer-string))))))

(ert-deftest mdwt-test-editor-placement ()
  "The edit window opens right below the table window, ignoring display rules."
  (let ((mdwt-edit-method 'buffer)
        (display-buffer-alist '(("\\*mdwt cell\\*" (display-buffer-in-side-window) (side . left))))
        (tbuf (get-buffer-create " *mdwt-test-table*")))
    (unwind-protect
        (progn
          (delete-other-windows)
          (switch-to-buffer tbuf)
          (insert "| A | B |\n|---|---|\n| x | y |\n")
          (mdwt-mode 1)
          (let* ((top (selected-window))
                 (bottom (split-window top nil 'below)))
            (set-window-buffer bottom (get-buffer-create " *mdwt-test-other*"))
            (goto-char (point-min))
            (mdwt--reveal)
            (mdwt-test--cmd #'mdwt-cell-down)
            (mdwt-edit-cell)
            (let ((ed (selected-window)))
              (mdwt-test--check "editor shows *mdwt cell*"
                (equal (buffer-name (window-buffer ed)) "*mdwt cell*"))
              (mdwt-test--check "editor directly below the table window"
                (eq (window-in-direction 'below top) ed))
              (mdwt-test--check "editor is not a side window"
                (null (window-parameter ed 'window-side)))
              (mdwt-test--check "editor height from `mdwt-edit-window-height'"
                (<= (abs (- (window-total-height ed) mdwt-edit-window-height)) 1))
              (mdwt-edit-commit)
              (mdwt-test--check "save deletes the editor window"
                (and (not (window-live-p ed)) (eq (selected-window) top))))))
      (kill-buffer tbuf)
      (when (get-buffer " *mdwt-test-other*") (kill-buffer " *mdwt-test-other*"))
      (delete-other-windows))))

(ert-deftest mdwt-test-minibuffer-method ()
  (let ((mdwt-edit-method 'minibuffer))
    (mdwt-test--with-table "| A | B |\n|---|---|\n| x | y |\n"
      (goto-char (point-min))
      (mdwt--reveal)
      (mdwt-test--cmd #'mdwt-cell-down)
      (mdwt-test--cmd #'mdwt-cell-next)
      (let (seen)
        (cl-letf (((symbol-function 'read-from-minibuffer)
                   (lambda (_prompt init &rest _) (setq seen init) "via | mini")))
          (mdwt-edit-cell))
        (mdwt-test--check "minibuffer prefilled with the cell text" (equal seen "y")))
      (mdwt-test--check "minibuffer edit saved"
        (string-match-p "^| x | via \\\\| mini |$" (buffer-string)))
      (mdwt-test--check "cell cursor kept" (equal mdwt--cell '(1 . 1)))
      (let ((before (buffer-string)))
        (cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) (signal 'quit nil))))
          (mdwt-edit-cell))
        (mdwt-test--check "C-g leaves the source unchanged"
          (equal before (buffer-string))))
      (cl-letf (((symbol-function 'read-from-minibuffer) (lambda (&rest _) "m")))
        (mdwt-test--cmd #'mdwt-cell-type ?q))
      (mdwt-test--check "typing doesn't start an in-place edit" (null mdwt--ip-text)))))

;;;; In-place editing

(ert-deftest mdwt-test-inplace-editing ()
  (let ((mdwt-edit-method 'inplace)
        (cmd #'mdwt-test--cmd))
    (mdwt-test--with-table
        (concat "intro\n\n| H1 | H2 |\n|---|---|\n| a1 | hello world |\n| b1 | "
                (mapconcat #'identity (make-list 30 "word") " ") " |\n\noutro\n")
      (let ((orig (buffer-string)))
        (goto-char (point-min))
        (forward-line 2)
        (mdwt--reveal)
        (funcall cmd #'mdwt-cell-down)
        (funcall cmd #'mdwt-cell-next)
        (funcall cmd #'mdwt-edit-cell)
        (mdwt-test--check "RET starts an in-place edit, offset at the end"
          (and (equal mdwt--ip-text "hello world") (= mdwt--ip-off 11)))
        (mdwt-test--check "editing keys bound; others fall through to cell keys"
          (equal (mapcar (lambda (k) (key-binding (kbd k))) '("x" "C-f" "RET" "C-g" "M-a" "C-/"))
                 '(mdwt-ip-insert mdwt-ip-forward-char mdwt-ip-commit mdwt-ip-cancel
                   mdwt-cell-first mdwt-ip-undo)))
        (funcall cmd #'mdwt-ip-insert ?!)
        (mdwt-test--check "typed char shows in the rendered cell"
          (string-match-p "hello world!" (mdwt-test--shown)))
        (mdwt-test--check "buffer untouched while editing" (equal orig (buffer-string)))
        (mdwt-test--check "cell drawn with the editing face"
          (equal (mdwt-test--faced-ids 'mdwt-editing-cell) '((1 . 1))))
        (funcall cmd #'mdwt-ip-line-start)
        (mdwt-test--check "C-a: offset 0, cursor on 'h'"
          (and (= mdwt--ip-off 0) (eq (mdwt-test--char-under-cursor) ?h)))
        (funcall cmd #'mdwt-ip-insert ?X)
        (funcall cmd #'mdwt-ip-forward-word)
        (mdwt-test--check "M-f: after 'Xhello', cursor on the space"
          (and (= mdwt--ip-off 6) (eq (mdwt-test--char-under-cursor) ?\s)))
        (funcall cmd #'mdwt-ip-delete-forward)
        (mdwt-test--check "C-d deletes the space" (equal mdwt--ip-text "Xhelloworld!"))
        (funcall cmd #'mdwt-ip-undo)
        (mdwt-test--check "cell undo restores it" (equal mdwt--ip-text "Xhello world!"))
        (funcall cmd #'mdwt-ip-backward-char)
        (funcall cmd #'mdwt-ip-delete-backward)
        (mdwt-test--check "C-b then DEL deletes the char before the cursor"
          (equal mdwt--ip-text "Xhelo world!"))
        (funcall cmd #'mdwt-ip-insert ?|)
        (funcall cmd #'mdwt-ip-commit)
        (mdwt-test--check "RET saves into the source, | escaped"
          (string-match-p "^| a1 | Xhel\\\\|o world! |$" (buffer-string)))
        (mdwt-test--check "editing ended, cell cursor kept"
          (and (null mdwt--ip-text) (equal mdwt--cell '(1 . 1))))
        (let ((before (buffer-string)))
          (funcall cmd #'mdwt-edit-cell)
          (funcall cmd #'mdwt-ip-insert ?Q)
          (funcall cmd #'mdwt-ip-cancel)
          (mdwt-test--check "C-g cancels: source and display unchanged"
            (and (equal before (buffer-string)) (null mdwt--ip-text)
                 (not (string-match-p "Q" (mdwt-test--shown))))))
        (funcall cmd #'mdwt-cell-type ?Z)
        (mdwt-test--check "typing in a cell starts an in-place edit"
          (equal mdwt--ip-text "Xhel|o world!Z"))
        (funcall cmd #'mdwt-cell-first)
        (mdwt-test--check "a cell key while editing saves, then moves"
          (and (null mdwt--ip-text) (equal mdwt--cell '(1 . 0))
               (string-match-p "world!Z |$" (buffer-string))))
        (funcall cmd #'mdwt-cell-down)
        (funcall cmd #'mdwt-cell-next)
        (funcall cmd #'mdwt-edit-cell)
        (funcall cmd #'mdwt-ip-line-start)
        (let ((line0 mdwt--line) (off0 mdwt--ip-off))
          (funcall cmd #'mdwt-ip-previous-line)
          (mdwt-test--check "C-p moves up a wrapped line inside the cell"
            (and mdwt--ip-text (= mdwt--line (1- line0)) (< mdwt--ip-off off0)))
          (funcall cmd #'mdwt-ip-next-line)
          (mdwt-test--check "C-n moves back down, same column"
            (and (= mdwt--line line0) (= mdwt--ip-off off0)))
          (mdwt-test--check "cursor on the 'w' starting the line"
            (eq (mdwt-test--char-under-cursor) ?w))
          (funcall cmd #'mdwt-ip-line-end)
          (mdwt-test--check "C-e: end of the same wrapped line"
            (and (= mdwt--line line0) (> mdwt--ip-off off0)
                 (eq (mdwt-test--char-under-cursor) ?\s))))
        (undo-boundary)
        (funcall cmd #'mdwt-ip-insert ?K)
        (goto-char (point-max))
        (mdwt--reveal)
        (mdwt-test--check "moving point off the table saves the edit"
          (and (null mdwt--ip-text) (string-match-p "wordK" (buffer-string))))
        (mdwt-test--check "...and point stays where it went" (= (point) (point-max)))
        (primitive-undo 1 buffer-undo-list)
        (mdwt-test--check "one undo step reverts the saved cell edit"
          (not (string-match-p "wordK" (buffer-string))))))))

(ert-deftest mdwt-test-inplace-resize ()
  "A window resize mid-edit re-renders for the new width and keeps the edit."
  (let ((mdwt-edit-method 'inplace))
    (mdwt-test--with-table
        "| A | B |\n|---|---|\n| x | some fairly long cell text here to wrap |\n| y | z |\n"
      (goto-char (point-min))
      (mdwt--reveal)
      (mdwt-test--cmd #'mdwt-cell-down)
      (mdwt-test--cmd #'mdwt-cell-next)
      (mdwt-test--cmd #'mdwt-edit-cell)
      (mdwt-test--cmd #'mdwt-ip-insert ?Q)
      (let ((orig (buffer-string))
            (w-before (nth 1 (overlay-get mdwt--cell-ov 'mdwt-widths)))
            (off mdwt--ip-off))
        (cl-letf (((symbol-function 'mdwt--avail) (lambda () 30)))
          (mdwt--refresh-buffer (current-buffer)))
        (mdwt-test--check "column re-fitted to the new width"
          (< (nth 1 (overlay-get mdwt--cell-ov 'mdwt-widths)) w-before))
        (mdwt-test--check "edit still in progress, text and offset kept"
          (and (equal mdwt--ip-text "some fairly long cell text here to wrapQ")
               (= mdwt--ip-off off)))
        (mdwt-test--check "in-progress text drawn in the re-rendered table"
          (string-match-p "wrapQ" (mdwt-test--shown)))
        (mdwt-test--check "buffer still untouched" (equal orig (buffer-string)))
        (mdwt-test--check "cursor line belongs to the edited row"
          (eql (aref (overlay-get mdwt--cell-ov 'mdwt-rows) mdwt--line) 1))
        (mdwt-test--cmd #'mdwt-ip-commit)
        (mdwt-test--check "saving after the resize writes the edit"
          (string-match-p "to wrapQ |$" (buffer-string)))))))

;;;; Loading

(ert-deftest mdwt-test-unload ()
  "Unloading leaves no stale hooks behind in buffers using the mode."
  (unwind-protect
      (with-temp-buffer
        (insert "| a | b |\n|---|---|\n| x | y |\n")
        (mdwt-mode 1)
        (unload-feature 'mdwt t)
        ;; Only mdwt's own functions must be gone; other modes (e.g.
        ;; `global-eldoc-mode' on Emacs 29) keep theirs in these hooks.
        (dolist (hook '(post-command-hook after-change-functions window-size-change-functions))
          (ert-info ((format "%s" hook))
            (should-not (memq 'mdwt--reveal (symbol-value hook)))
            (should-not (memq 'mdwt--schedule (symbol-value hook)))
            (should-not (memq 'mdwt--on-resize (symbol-value hook)))
            (should-not (memq 'mdwt--reveal (default-value hook)))))
        (should-not (memq 'mdwt--emulation-alist emulation-mode-map-alists)))
    ;; Reload even if an assertion failed, so later tests still have mdwt.
    (require 'mdwt)))

(provide 'mdwt-test)
;;; mdwt-test.el ends here
