EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L .

PKG   = mdwt.el
TESTS = test/mdwt-test.el

.PHONY: all compile checkdoc lint test clean

all: compile checkdoc test

# Byte-compile with every warning treated as an error.
compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(PKG)

# Fail on any checkdoc warning.
checkdoc:
	$(BATCH) -l test/checkdoc-batch.el $(PKG)

# MELPA conventions (installs package-lint from MELPA; needs network).
lint:
	$(BATCH) -l test/package-lint-batch.el $(PKG)

test:
	$(BATCH) -L test -l $(TESTS) -f ert-run-tests-batch-and-exit

clean:
	rm -f *.elc test/*.elc
