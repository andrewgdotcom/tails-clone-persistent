DPKG_DEST = ~/build
PREFIX = $(DPKG_DEST)/frith

BINPREFIX = $(PREFIX)/usr/bin
SBINPREFIX = $(PREFIX)/usr/sbin
LIBPREFIX = $(PREFIX)/var/lib/frith
SKEL = $(LIBPREFIX)/skel

all: src/tcp-helper

$(BINPREFIX) $(SBINPREFIX) $(LIBPREFIX) $(SKEL):
	sudo mkdir -p $@

src/tcp-helper:
	(cd src && make)

install: all $(BINPREFIX) $(SBINPREFIX) $(LIBPREFIX) $(SKEL)
	sudo cp bin/frith bin/tails-clone-persistent $(BINPREFIX)/
	sudo chmod 755 $(BINPREFIX)/frith $(BINPREFIX)/tails-clone-persistent
	sudo cp src/tcp-helper $(SBINPREFIX)/
	sudo chmod 4755 $(SBINPREFIX)/tcp-helper
	sudo cp -R skel/* $(SKEL)/
	sudo chmod 600 $(SKEL)/live-additional-software.conf $(SKEL)/persistence.conf

clean:
	(cd src && make clean)

deb: install
	sudo cp -R DEBIAN $(PREFIX)/
	sudo dpkg-deb --build $(PREFIX) $(DPKG_DEST)

deb-clean: clean
	sudo rm -rf $(BINPREFIX)/frith $(BINPREFIX)/tails-clone-persistent \
		$(LIBPREFIX)/tcp-helper $(SKEL)

