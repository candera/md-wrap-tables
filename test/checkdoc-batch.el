;;; checkdoc-batch.el --- Run checkdoc, exit non-zero on warnings  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Usage: emacs -Q --batch -l test/checkdoc-batch.el FILE...

;;; Code:

(require 'checkdoc)

(let ((checkdoc-arguments-in-order-flag nil)
      (warnings 0))
  (advice-add 'checkdoc-create-error :after
              (lambda (&rest _) (setq warnings (1+ warnings))))
  (dolist (file command-line-args-left)
    (checkdoc-file file))
  (setq command-line-args-left nil)
  (message "checkdoc: %d warning(s)" warnings)
  (kill-emacs (if (zerop warnings) 0 1)))

;;; checkdoc-batch.el ends here
