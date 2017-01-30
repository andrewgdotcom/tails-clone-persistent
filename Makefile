DPKG_DEST = ~/build
PREFIX = $(DPKG_DEST)/tails-clone-persistent

BINPREFIX = $(PREFIX)/usr/bin

all: src/tails-clone-persistent-helper

$(BINPREFIX) :
	sudo mkdir -p $@

src/tails-clone-persistent-helper: src/tails-clone-persistent-helper.cpp
	echo "Entering src/"
	(cd src && make)
	echo "Exiting src/"

install: all $(BINPREFIX)
	sudo cp bin/tails-clone-persistent bin/tails-clone-persistent-helper.pl src/tails-clone-persistent-helper $(BINPREFIX)/
	sudo chmod 755 $(BINPREFIX)/tails-clone-persistent $(BINPREFIX)/tails-clone-persistent-helper.pl
	sudo chmod 4755 $(BINPREFIX)/tails-clone-persistent-helper

clean:
	(cd src && make clean)

deb: install
	vi DEBIAN/control
	sudo cp -R DEBIAN $(PREFIX)/
	sudo dpkg-deb --build $(PREFIX) $(DPKG_DEST)

deb-clean: clean
	sudo rm -rf $(BINPREFIX)/tails-clone-persistent*

