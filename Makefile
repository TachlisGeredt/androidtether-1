PREFIX ?= /usr/local
LIBUSB_PREFIX ?= $(shell brew --prefix libusb 2>/dev/null || echo /opt/homebrew)
CFLAGS ?= -O2 -Wall -Wextra

all: androidtetherd androidtether-ui

androidtetherd: awp_rndisd.c
	cc $(CFLAGS) -I$(LIBUSB_PREFIX)/include/libusb-1.0 -o $@ $< $(LIBUSB_PREFIX)/lib/libusb-1.0.a -framework IOKit -framework CoreFoundation -framework Security -lobjc -lpthread

androidtether-ui: awp_menubar.m
	cc $(CFLAGS) -fobjc-arc -o $@ $< -framework Cocoa -framework SystemConfiguration

install: all
	install -d $(PREFIX)/sbin $(PREFIX)/bin
	install -m 755 androidtetherd $(PREFIX)/sbin/androidtetherd
	install -m 755 androidtether-ui $(PREFIX)/bin/androidtether-ui

clean:
	rm -f androidtetherd androidtether-ui

.PHONY: all install clean
