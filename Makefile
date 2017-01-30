DPKG_DEST = ~/build
PREFIX = $(DPKG_DEST)/tails-clone-persistent

BINPREFIX = $(PREFIX)/usr/bin

$(BINPREFIX) :
	sudo mkdir -p $@

install: $(BINPREFIX)
	sudo cp bin/tails-clone-persistent bin/tails-clone-persistent-helper.pl $(BINPREFIX)/
	sudo chmod 755 $(BINPREFIX)/tails-clone-persistent
	sudo chmod 755 $(BINPREFIX)/tails-clone-persistent-helper.pl

clean:
	(cd src && make clean)

deb: install
	vi DEBIAN/control
	sudo rm -rf $(PREFIX)/DEBIAN
	sudo cp -R DEBIAN $(PREFIX)/
	sudo dpkg-deb --build $(PREFIX) $(DPKG_DEST)

deb-clean: clean
	sudo rm -rf $(BINPREFIX)/tails-clone-persistent $(BINPREFIX)/tails-clone-persistent-helper.pl

