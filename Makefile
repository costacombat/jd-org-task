EMACS ?= emacs

.PHONY: test compile

compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile jd-org.el

test: compile
	$(EMACS) -Q --batch -L . -L test -l jd-org-test -f ert-run-tests-batch-and-exit
