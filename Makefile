DPKG_DEST = ~/build
PREFIX = $(DPKG_DEST)/tails-clone-persistent

BINPREFIX = $(PREFIX)/usr/bin
SBINPREFIX = $(PREFIX)/usr/sbin

all: src/tails-clone-persistent-helper

$(BINPREFIX) $(SBINPREFIX) :
	sudo mkdir -p $@

src/tails-clone-persistent-helper:
	echo "Entering src/"
	(cd src && make)
	echo "Exiting src/"

install: all $(BINPREFIX) $(SBINPREFIX)
	sudo cp bin/tails-clone-persistent $(BINPREFIX)/
	sudo chmod 755 $(BINPREFIX)/tails-clone-persistent
	sudo cp src/tails-clone-persistent-helper $(SBINPREFIX)/
	sudo chmod 4755 $(SBINPREFIX)/tails-clone-persistent-helper

clean:
	(cd src && make clean)

deb: install
	vi DEBIAN/control
	sudo cp -R DEBIAN $(PREFIX)/
	sudo dpkg-deb --build $(PREFIX) $(DPKG_DEST)

deb-clean: clean
	sudo rm -rf $(BINPREFIX)/tails-clone-persistent $(SBINPREFIX)/tails-clone-persistent-helper

