BINPREFIX = $(DESTDIR)/usr/bin
ETCPREFIX = $(DESTDIR)/etc
SHAREPREFIX = $(DESTDIR)/usr/share
APPLICATIONS = $(SHAREPREFIX)/applications
SUDOERSD = $(ETCPREFIX)/sudoers.d
POLKITD = $(ETCPREFIX)/polkit-1/localauthority/10-vendor.d

all:

clean:

$(BINPREFIX) $(SUDOERSD) $(POLKITD) $(APPLICATIONS) :
	mkdir -p $@

install: $(BINPREFIX) $(SUDOERSD) $(POLKITD) $(APPLICATIONS)
	cp bin/tails-clone-persistent bin/tails-clone-persistent-helper.pl bin/tails-clone-persistent-helper bin/tails-clone-persistent-sync $(BINPREFIX)/
	cp share/applications/tails-clone-persistent.desktop $(APPLICATIONS)/
	cp zzz_tails-clone-persistent $(SUDOERSD)/
	cp zzz_com.andrewg.tails-clone-persistent.pkla $(POLKITD)/
	chmod 755 $(BINPREFIX)/tails-clone-persistent $(BINPREFIX)/tails-clone-persistent-helper.pl $(BINPREFIX)/tails-clone-persistent-helper $(BINPREFIX)/tails-clone-persistent-sync
	chmod 440 $(SUDOERSD)/zzz_tails-clone-persistent
