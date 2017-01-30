#!/usr/bin/perl -T
my $program = 'tails-clone-persistent-helper.pl';
my $version = '0.2';

use strict;
use warnings;

# errors < 65536 are internal

my $_INTERNAL_USAGE 			=	0x0001;
my $_INTERNAL_SANITATION 		=	0x0002;
my $_INTERNAL_PARTED_UNPARSED	= 	0x0003;
my $_INTERNAL_MOUNT 			=	0x0004;

# errors >= 65536 result from failed subprocesses
# high two bytes identify subprocess
# low two bytes give subprocess exit code
# NB: 'dd' subprocess CAN (in theory) fail with error=0

my $_ERR_RSYNC	 				=	0x10000;
my $_ERR_DD 					=	0x20000;
my $_ERR_SETFACL 				=	0x30000;
my $_ERR_CHMOD	 				=	0x40000;
my $_ERR_PARTED_RM 			=	0x50000;
my $_ERR_PARTED_MKPART 		=	0x60000;
my $_ERR_PARTED_NAME 			=	0x70000;
my $_ERR_LUKSCLOSE 			=	0x80000;
my $_ERR_LUKSOPEN 				=	0x90000;
my $_ERR_LUKSFORMAT 			=	0xa0000;
my $_ERR_MKE2FS 				=	0xb0000;
my $_ERR_UNMOUNT 				=	0xc0000;

# global debug flag - we set this based on envar TCP_HELPER_DEBUG
my $_DEBUG=0;

# parted cannot automatically find the beginning of free space, so we
# have to do it ourselves

sub tails_free_start() {
	my $block_device = shift;

	my $persistent_partition_exists=0;
	my $buffer="";
	
	open(PIPE, "-|", "/sbin/parted $block_device p") 
		|| return ("", 0);
		
	# Grep through the parted output to find specific partitions
	while(<PIPE>) { 
		if(/^\s*1\s+[[:digit:]]+[kMGT]?B\s+([[:digit:]]+[kMGT]+B)\s+.*$/) {
			# Matched partition "1"
			$buffer=$1;
			$_DEBUG and warn "Got partition end location: $buffer\n";
		} elsif(/^\s*2\s+[[:digit:]]+[kMGT]?B\s+([[:digit:]]+[kMGT]+B)\s+.*$/) {
			# Matched partition "2"
			$persistent_partition_exists=1;
		} elsif(/^\s*[[:digit:]]+\s+[[:digit:]]+[kMGT]?B\s+([[:digit:]]+[kMGT]+B)\s+.*$/) {
			# Matched any other partition number
			die "Found too many partitions!\n";
		}
	}

	close(PIPE);
	return ($buffer, $persistent_partition_exists);
}


# mount a filesystem and return a string containing the mount point

sub mount_device() {
	my $device = shift;
	
	print "Mounting crypted partition...\n";
	open(PIPE, "-|", "/usr/bin/udisksctl mount --block-device $device") 
		|| return "";

	my $mount_point="";
	while(<PIPE>) {
		if(/^Mounted \S+ at (\S+)$/) {
			$mount_point = $1;
			last;
		}
	}
	close(PIPE);
	
	if($mount_point=="") {
		print "Could not mount filesystem!\n";
		return("");
	}
	
	# Test to see if udisksctl has appended a full stop to the output
	# and delete it. Some versions do, some don't.
	if($mount_point =~ /\.$/) {
		$_DEBUG and warn "Truncating trailing punctuation\n";
		chop $mount_point;
	}
	return($mount_point);
}

# Housekeeping and cleanup

sub luks_close_unmounted() {
	my $crypted_block_device = shift;
	# use this to make sure all data is flushed and cryption stopped
	
	my $err;
	do {
		print "TCPH Attempting to stop device (waiting for buffers to flush)\n";
		$err = system("/sbin/cryptsetup luksClose $crypted_block_device");
	} while( $err == 5 );
	if($err) {
		warn "TCPH_ERROR Failed to lock partition!\nError: $err\n";
		exit((0xffff&$err) + $_ERR_LUKSCLOSE);
	}
}

sub unmount_and_luks_close() {
	my $crypted_block_device = shift;
	my $err;
	$err = system("/usr/bin/udisksctl unmount --force --block-device $crypted_block_device");
	if($err) {
		warn "TCPH_ERROR Failed to unmount partition!\nError: $err\n";
		exit((0xffff&$err) + $_ERR_UNMOUNT);
	}
	&luks_close_unmounted($crypted_block_device);
}


# Create a persistent partition, deleting any old ones as necessary.
# This is called for modes "new" and "deniable".
# We luksClose the partition at the end for two reasons:
#
# a) simplicity: do_copy() doesn't need to know if we were called
# b) safety: we found odd problems mounting newly-created partitions 
#    that were solved by forcing a flush to disk
#
# This does mean we end up luksOpening the partition twice. This is
# fine, as we aren't intended to be called directly and Expect doesn't
# care how many times it is prompted for the same passphrase. ;-)

sub make_partition() {
		my $block_device = shift;
		my $partition = shift;
		my $tmp_target_dev_id = shift;
		my $mode = shift;
	my $err;
	my $tmp_target_dev_path = "/dev/mapper/$tmp_target_dev_id";

	print "TCPH Configuring partitions\n";

	# information flag
	my ($start, $persistent_partition_exists) = &tails_free_start($block_device);
	if($start == "") {
		print STDOUT "TCPH_ERROR Could not detect end of tails primary partition\n";
		exit($_INTERNAL_PARTED_UNPARSED);
	}
	
	# if >2 partitions, tails_free_start would have aborted above
	# so safe to assume we need to trash one partition at most
	if($persistent_partition_exists) {
		$_DEBUG and warn "Deleting old second partition\n";
		$err = system("/sbin/parted -s $block_device rm 2");	
		if($err) {
			warn "TCPH_ERROR Could not delete old persistent partition\nError: $err\n";
			exit((0xffff&$err) + $_ERR_PARTED_RM);
		}
	}

	$_DEBUG and warn "Making new secondary partition\n";
	$err = system("/sbin/parted -s $block_device mkpart primary $start 100%");
	if($err) {
		warn "TCPH_ERROR Could not create new partition\nError: $err\n";
		exit((0xffff&$err) + $_ERR_PARTED_MKPART);
	}

	$_DEBUG and warn "Renaming partition label\n";
	$err = system("/sbin/parted -s $block_device name 2 TailsData");
	if($err) {
		warn "TCPH_ERROR Could not rename new partition\nError: $err\n";
		exit((0xffff&$err) + $_ERR_PARTED_NAME);
	}

	print "TCPH Initialising new crypted volume\n";
	$err = system("/sbin/cryptsetup luksFormat $partition");
	if($err) {
		warn "TCPH_ERROR Could not initialise crypted volume\nError: $err\n";
		exit((0xffff&$err) + $_ERR_LUKSFORMAT);
	}

	$_DEBUG and warn "Unlocking new crypted volume\n";
	$err = system("/sbin/cryptsetup luksOpen $partition $tmp_target_dev_id");
	if($err) {
		warn "TCPH_ERROR Could not unlock new crypted volume\nError: $err\n";
		exit((0xffff&$err) + $_ERR_LUKSOPEN);
	}
	
	# plausible deniability
	if($mode == "deniable") {
		print "TCPH Randomising free space for plausible deniability. This may take a while.\n";
		# "a while" =~ 5-10 mins/GB on crappy hardware ;-)
		
		# when we update to coreutils 8.24 we can use status=progress
		$err = system("/bin/dd if=/dev/zero of=$tmp_target_dev_path bs=128M");
		if($err != 256) { 
			# yes, we WANT to fail with "no space left on device"!
			&luks_close_unmounted($tmp_target_dev_path);
			warn "TCPH_ERROR Could not randomise free space on new crypted volume\nError: $err\n";
			exit((0xffff&$err) + $_ERR_DD);		
		}
	}
	
	# If we're called for deniability purposes only, we _could_
	# skip the filesystem creation and save a little time here.
	# This will need a new mode - may not be worth the hassle
	
	print "TCPH Creating filesystem\n";
	$err = system("/sbin/mke2fs -j -t ext4 -L TailsData $tmp_target_dev_path");
	if($err) {
		&luks_close_unmounted($tmp_target_dev_path);
		warn "TCPH_ERROR Could not create filesystem on new crypted volume\nError: $err\n";
		exit((0xffff&$err) + $_ERR_MKE2FS);
	}
	
	# stop the luks device to force a flush on slow devices
	&luks_close_unmounted($tmp_target_dev_path);
}


# rsync files from a location on an already-mounted FS to / on an 
# existing, unmounted FS on a non-running luks partition. 
# This is called only if SOURCE_DIR is non-empty

sub do_copy() {
		my $source_dir = shift;
		my $partition = shift;
		my $tmp_target_dev_id = shift;
	my $err;
	my $tmp_target_dev_path = "/dev/mapper/$tmp_target_dev_id";
	
	print "Unlocking crypted partition\n";

	# (re)open the crypted device
	$err = system("/sbin/cryptsetup luksOpen $partition $tmp_target_dev_id");
	if($err) {
		warn "TCPH_ERROR Could not unlock crypted volume\nError: $err\n";
		exit((0xffff&$err) + $_ERR_LUKSOPEN);
	}

	my $mount_point = &mount_device($tmp_target_dev_path);
	if($mount_point=="") {
		&luks_close_unmounted($tmp_target_dev_path);
		warn "TCPH_ERROR Could not mount crypted volume\n";
		exit($_INTERNAL_MOUNT);
	}
	$_DEBUG and warn "Crypted volume mounted on $mount_point\n";

		
	# run rsync to copy files. Note that --delete does NOT delete
	# --exclude'd files on the target.
	print "TCPH Copying files...\n";
	$err = system("/usr/bin/rsync -a --delete --exclude=gnupg/random_seed --exclude=lost+found $source_dir/ $mount_point");
	if($err) {
		&unmount_and_luks_close($tmp_target_dev_path);
		warn "TCPH_ERROR Error syncing files\nError: $err\n";
		exit((0xffff&$err) + $_ERR_RSYNC);
	}
	
	# ensure correct permissions on the root of the persistent disk
	# after rsync mucks them about - otherwise tails will barf. See
	# https://tails.boum.org/contribute/design/persistence/#security
	
	$err = chmod($mount_point, 0775);
	if($err){
		&unmount_and_luks_close($tmp_target_dev_path);
		warn "TCPH_ERROR Could not set permissions on $mount_point\nError: $err\n";
		exit((0xffff&$err) + $_ERR_CHMOD);
	}
	
	$err = system("/usr/bin/setfacl -b $mount_point");
	if($err){
		&unmount_and_luks_close($tmp_target_dev_path);
		warn "TCPH_ERROR Could not clear ACLs on $mount_point\nError: $err\n";
		exit((0xffff&$err) + $_ERR_SETFACL);
	}

	$err = system("/usr/bin/setfacl -m user:tails-persistence-setup:rwx $mount_point");
	if($err){
		&unmount_and_luks_close($tmp_target_dev_path);
		warn "TCPH_ERROR Could not set ACLs on $mount_point\nError: $err\n";
		exit((0xffff&$err) + $_ERR_SETFACL);
	}

	print "TCPH Unmounting and flushing data to disk\n";
	&unmount_and_luks_close($tmp_target_dev_path);
	
	print "TCPH Copy complete\n";
}

# Main routine
		
sub tails_clone_persistent_helper() {
	my $source_dir = shift;
	my $block_device = shift;
	my $mode = shift;
		
	if(getenv("TCP_HELPER_DEBUG")) {
		$_DEBUG=1;
	}
	
	$_DEBUG and warn "Args: $\n";
	# sanitize our input
	if($source_dir =~ m![^A-Za-z0-9.,=+_/-]! ||
		$block_device =~ m![^A-Za-z0-9.,=+_/-]!) {
		print "Unsafe characters detected in filename. Aborting\n";
		exit($_INTERNAL_SANITATION);
	}
	
	my $partition = "${block_device}2";
	
	# temp ID by which the target crypt drive will be known
	# should probably randomise this to prevent clashing
	my $tmp_target_dev_id = "TailsData_target";

	if($mode=="new" || $mode=="deniable") {
		&make_partition($block_device, $partition, $tmp_target_dev_id, $mode);
	}
	# if we are told to copy nothing, quit early
	if($source_dir=="") {
		print "TCPH Not copying any files, as requested\n";
	} else {
		&do_copy($source_dir, $partition, $tmp_target_dev_id);
	}
}


# START


if($ARGV != 4 || $ARGV[3] !~ /^(existing|new|deniable)$/ ){
	warn <<EOF;
Usage: &tails_clone_persistent_helper.pl(SOURCE_DIR BLOCK_DEVICE MODE)

"rsync --delete" the contents of SOURCE_DIR to a new or existing
persistent partition on the tails drive BLOCK_DEVICE

SOURCE_DIR: directory to be rsynced (without trailing /)
 (If the empty string is given, rsync is skipped)

BLOCK_DEVICE: the target Tails drive (NOT partition!)
 (e.g. "/dev/sdb")
 NB It should be neither luksOpened nor mounted

MODE: one of
 existing: update the contents of an existing persistent partition
 new:      delete any existing persistent partition and make a new one
 deniable: as "new", but randomise partition before making filesystem
            (can take a long time, perhaps several minutes/GB)
EOF
	exit($_INTERNAL_USAGE);
} else {
	&tails_clone_persistent_helper($ARGV[1], $ARGV[2], $ARGV[3]);
}
