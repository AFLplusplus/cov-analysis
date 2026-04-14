DESTDIR     =
PREFIX      = /usr/local
BINDIR      = $(DESTDIR)$(PREFIX)/bin

SCRIPTS     = afl-cov afl-cov-build.sh afl-stat.sh

all:
	@echo "Run 'sudo make install' to install to $(BINDIR)"

install: $(SCRIPTS)
	install -m 0755 $(SCRIPTS) $(BINDIR)

uninstall:
	cd $(BINDIR) && rm -f $(SCRIPTS)

.PHONY: all install uninstall
