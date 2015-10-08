DPKG_DEST=~/build/
PREFIX=$DPKG_DEST/frith/staging

BINPREFIX=$PREFIX/usr/bin
LIBPREFIX=$PREFIX/var/lib/frith
SKEL=$LIBPREFIX/skel

src/tcp-helper: src/tcp-helper.c
	(cd src && make)

all: src/tcp-helper

install: all
	cp bin/frith bin/tails-clone-persistent $BINPREFIX/
	chown root:root $BINPREFIX/frith $BINPREFIX/tails-clone-persistent
	chmod 755 $BINPREFIX/frith $BINPREFIX/tails-clone-persistent
	cp src/tcp-helper $LIBPREFIX/
	chown root:root $LIBPREFIX/tcp-helper
	chmod 4755 $LIBPREFIX/tcp-helper
	cp skel/* $SKEL/
	chown -R root:root $SKEL/
	chmod 600 $SKEL/live-additional-software.conf $SKEL/persistence.conf

install-debbuild: install
	cp DEBIAN $PREFIX/
	dpkg-deb --build $PREFIX $DPKG_DEST

