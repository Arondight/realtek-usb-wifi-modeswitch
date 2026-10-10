# Makefile for realtek-usb-wifi-modeswitch
#
#   make test        run the smoke and unit tests
#   make lint        run shellcheck (required by make check)
#   make fmt         format the shell scripts with shfmt (3.14 or newer)
#   make fmt-check   verify formatting with shfmt (used by make check)
#   make check       lint + fmt-check + test
#   make install     install into $(PREFIX), supports DESTDIR/BINDIR/MANDIR
#   make uninstall   remove installed files
#   make help        show this help

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
MANDIR ?= $(PREFIX)/share/man/man8
PROG   := modeswitch

SHFMT_FLAGS := -i 4 -ci
SCRIPTS := $(PROG).sh install.sh tests/smoke.sh tests/unit.sh

.PHONY: all test lint fmt fmt-check check install uninstall clean help

all: check

test:
	bash tests/smoke.sh
	bash tests/unit.sh

lint:
	shellcheck $(SCRIPTS)

fmt:
	shfmt $(SHFMT_FLAGS) -w $(SCRIPTS)

fmt-check:
	shfmt $(SHFMT_FLAGS) -d $(SCRIPTS)

check: lint fmt-check test

install:
	install -d "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(MANDIR)"
	install -m 0755 $(PROG).sh "$(DESTDIR)$(BINDIR)/$(PROG)"
	install -m 0644 man/$(PROG).8 "$(DESTDIR)$(MANDIR)/$(PROG).8"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(PROG)" "$(DESTDIR)$(MANDIR)/$(PROG).8"

clean:
	rm -f *.tmp

help:
	@sed -n 's/^#   //p' $(MAKEFILE_LIST)
