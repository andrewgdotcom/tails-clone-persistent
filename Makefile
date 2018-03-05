DPKG_DEST = ~/build
PREFIX = $(DPKG_DEST)/tails-clone-persistent

BINPREFIX = $(PREFIX)/usr/bin
SUDOERSD = $(PREFIX)/etc/sudoers.d

all:

clean:

$(BINPREFIX) $(SUDOERSD) :
	sudo mkdir -p $@

install: $(BINPREFIX) $(SUDOERSD)
	sudo cp bin/tails-clone-persistent bin/tails-clone-persistent-helper.pl $(BINPREFIX)/tails-clone-persistent-helper $(BINPREFIX)/tails-clone-persistent-sync $(BINPREFIX)/
	sudo cp zzz_tails-clone-persistent $(SUDOERSD)/
	sudo chmod 755 $(BINPREFIX)/tails-clone-persistent $(BINPREFIX)/tails-clone-persistent-helper.pl $(BINPREFIX)/tails-clone-persistent-helper $(BINPREFIX)/tails-clone-persistent-sync
	sudo chmod 440 $(SUDOERSD)/zzz_tails-clone-persistent

deb: install
	vi DEBIAN/control
	sudo rm -rf $(PREFIX)/DEBIAN
	sudo cp -R DEBIAN $(PREFIX)/
	sudo dpkg-deb --build $(PREFIX) $(DPKG_DEST)

deb-clean: clean
	sudo rm -rf $(BINPREFIX)/tails-clone-persistent* $(SUDOERSD)/zzz_tails-clone-persistent
