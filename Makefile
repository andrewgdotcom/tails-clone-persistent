DPKG_DEST = ~/build
PREFIX = $(DPKG_DEST)/tails-clone-persistent

BINPREFIX = $(PREFIX)/usr/bin
SBINPREFIX = $(PREFIX)/usr/sbin

all: src/tcp-helper

$(BINPREFIX) $(SBINPREFIX) :
	sudo mkdir -p $@

src/tcp-helper: src/tcp-helper.c
	(cd src && make)

install: all $(BINPREFIX) $(SBINPREFIX)
	sudo cp bin/tails-clone-persistent $(BINPREFIX)/
	sudo chmod 755 $(BINPREFIX)/tails-clone-persistent
	sudo cp src/tcp-helper $(SBINPREFIX)/
	sudo chmod 4755 $(SBINPREFIX)/tcp-helper

clean:
	(cd src && make clean)

deb: install
	sudo cp -R DEBIAN $(PREFIX)/
	sudo dpkg-deb --build $(PREFIX) $(DPKG_DEST)

deb-clean: clean
	sudo rm -rf $(BINPREFIX)/tails-clone-persistent $(SBINPREFIX)/tcp-helper

