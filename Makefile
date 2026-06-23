EMACS ?= emacs

.PHONY: check compile test

check: compile test

compile:
	$(EMACS) -Q --batch -L . -f batch-byte-compile miniflux.el

test:
	$(EMACS) -Q --batch -L . -L test -l test/miniflux-test.el -f ert-run-tests-batch-and-exit
