;;; package-lint-batch.el --- Install package-lint and lint files  -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Usage: emacs -Q --batch -l test/package-lint-batch.el FILE...
;; Installs package-lint from MELPA into a throwaway directory (needs
;; network access), then lints FILE... and exits non-zero on any issue.

;;; Code:

(require 'package)

(setq package-user-dir (make-temp-file "mdwt-package-lint-" t)
      package-archives '(("melpa" . "https://melpa.org/packages/")
                         ("gnu" . "https://elpa.gnu.org/packages/")))
(package-initialize)
(package-refresh-contents)
(package-install 'package-lint)
(require 'package-lint)

;; The main file's Package-Requires decides which Emacs features are allowed.
(setq package-lint-main-file (car command-line-args-left))
(package-lint-batch-and-exit)

;;; package-lint-batch.el ends here
