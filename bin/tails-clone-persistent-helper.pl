#!/usr/bin/perl -T
my $program = 'tails-clone-persistent-helper.pl';
my $version = '0.2';

use strict;
use warnings;

# Secure our path
$ENV{'PATH'} = '/bin:/usr/bin:/sbin:/usr/sbin';

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

	open(PIPE, "-|", "/usr/bin/sudo /sbin/parted -s $block_device p")
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
			die "TCPH_ERROR Found too many partitions!\n";
		}
	}

	close(PIPE);
	return ($buffer, $persistent_partition_exists);
}


# mount a filesystem and return a string containing the mount point

sub mount_device() {
	my $device = shift;

	print "TCPH Mounting crypted partition...\n";
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

	if($mount_point eq "") {
		print "TCPH_ERROR Could not mount filesystem!\n";
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

# unlock a filesystem and return a string containing the devicemapper device

sub unlock_device() {
	my $device = shift;

	print "TCPH Unlocking crypted partition...\n";
	open(PIPE, "-|", "/usr/bin/udisksctl unlock --block-device $device")
		|| return "";

	my $dm_device="";
	while(<PIPE>) {
		if(/^Unlocked \S+ as (\S+)$/) {
			$dm_device = $1;
			last;
		}
	}
	close(PIPE);

	if($dm_device eq "") {
		print "TCPH_ERROR Could not unlock partition!\n";
		return("");
	}

	# Test to see if udisksctl has appended a full stop to the output
	# and delete it. Some versions do, some don't.
	if($dm_device =~ /\.$/) {
		$_DEBUG and warn "Truncating trailing punctuation\n";
		chop $dm_device;
	}
	return($dm_device);
}


# Housekeeping and cleanup

sub lock_device() {
	my $block_device = shift;
	my $err;
	$err = system("/usr/bin/udisksctl", "lock", "--block-device", $block_device);
	if($err) {
		warn "TCPH_ERROR Failed to lock partition!\nError: $err\n";
		exit((0xffff&$err) + $_ERR_LUKSCLOSE);
	}
}

sub unmount_device() {
	my $crypted_block_device = shift;
	my $err;
	$err = system("/usr/bin/udisksctl", "unmount", "--block-device", $crypted_block_device);
	if($err) {
		warn "TCPH_ERROR Failed to unmount partition!\nError: $err\n";
		exit((0xffff&$err) + $_ERR_UNMOUNT);
	}
}


# Create a persistent partition, deleting any old ones as necessary.
# This is called for modes "new" and "deniable".
# We lock the partition at the end for two reasons:
#
# a) simplicity: do_copy() doesn't need to know if we were called
# b) safety: we found odd problems mounting newly-created partitions 
#    that were solved by forcing a flush to disk
#
# This does mean we end up unlocking the partition twice. This is
# fine, as we aren't intended to be called directly and Expect doesn't
# care how many times it is prompted for the same passphrase. ;-)

sub make_partition() {
		my $block_device = shift;
		my $partition = shift;
		my $mode = shift;
	my $err;

	print "TCPH Configuring partitions\n";

	# information flag
	my ($start, $persistent_partition_exists) = &tails_free_start($block_device);
	if($start eq "") {
		print STDOUT "TCPH_ERROR Could not detect end of tails primary partition\n";
		exit($_INTERNAL_PARTED_UNPARSED);
	}

	# if >2 partitions, tails_free_start would have aborted above
	# so safe to assume we need to trash one partition at most
	if($persistent_partition_exists) {
		$_DEBUG and warn "Deleting old second partition\n";
		$err = system('/usr/bin/sudo', '/sbin/parted', '-s', $block_device, 'rm', '2');
		if($err) {
			warn "TCPH_ERROR Could not delete old persistent partition\nError: $err\n";
			exit((0xffff&$err) + $_ERR_PARTED_RM);
		}
	}

	$_DEBUG and warn "Making new secondary partition\n";
	$err = system('/usr/bin/sudo', '/sbin/parted', '-s', $block_device, 'mkpart', 'primary', $start, '100%');
	if($err) {
		warn "TCPH_ERROR Could not create new partition\nError: $err\n";
		exit((0xffff&$err) + $_ERR_PARTED_MKPART);
	}

	$_DEBUG and warn "Renaming partition label\n";
	$err = system('/usr/bin/sudo', '/sbin/parted', '-s', $block_device, 'name', '2', 'TailsData');
	if($err) {
		warn "TCPH_ERROR Could not rename new partition\nError: $err\n";
		exit((0xffff&$err) + $_ERR_PARTED_NAME);
	}

	print "TCPH Initialising new crypted volume\n";
	$err = system('/usr/bin/sudo', '/sbin/cryptsetup', 'luksFormat', $partition);
	if($err) {
		warn "TCPH_ERROR Could not initialise crypted volume\nError: $err\n";
		exit((0xffff&$err) + $_ERR_LUKSFORMAT);
	}

	$_DEBUG and warn "Unlocking new crypted volume\n";
	my $tmp_target_dev_path = &unlock_device($partition);
	if($tmp_target_dev_path eq "") {
		&lock_device($tmp_target_dev_path);
		warn "TCPH_ERROR Could not unlock crypted volume\n";
		exit($_INTERNAL_MOUNT);
	}
	$_DEBUG and warn "Crypted volume unlocked at $tmp_target_dev_path\n";

	# plausible deniability
	if($mode eq "deniable") {
		print "TCPH Randomising free space for plausible deniability. This may take a while.\n";
		# "a while" =~ 5-10 mins/GB on crappy hardware ;-)
		
		# when we update to coreutils 8.24 we can use status=progress
		$err = system('/usr/bin/sudo', '/bin/dd', 'if=/dev/zero', "of=$tmp_target_dev_path", 'bs=128M');
		if($err != 256) { 
			# yes, we WANT to fail with "no space left on device"!
			&lock_device($tmp_target_dev_path);
			warn "TCPH_ERROR Could not randomise free space on new crypted volume\nError: $err\n";
			exit((0xffff&$err) + $_ERR_DD);		
		}
	}

	# If we're called for deniability purposes only, we _could_
	# skip the filesystem creation and save a little time here.
	# This will need a new mode - may not be worth the hassle

	print "TCPH Creating filesystem\n";
	$err = system('/usr/bin/sudo', '/sbin/mke2fs', '-j', '-t', 'ext4', '-L', 'TailsData', $tmp_target_dev_path);
	if($err) {
		&lock_device($tmp_target_dev_path);
		warn "TCPH_ERROR Could not create filesystem on new crypted volume\nError: $err\n";
		exit((0xffff&$err) + $_ERR_MKE2FS);
	}

	# stop the device to force a flush on slow devices
	print "TCPH Flushing to disk\n";
	&lock_device($partition);
}


# rsync files from a location on an already-mounted FS to / on an 
# existing, unmounted FS on a non-running luks partition. 
# This is called only if SOURCE_DIR is non-empty

sub do_copy() {
		my $source_dir = shift;
		my $partition = shift;
	my $err;

	# (re)open the crypted device
	my $tmp_target_dev_path = &unlock_device($partition);
	if($tmp_target_dev_path eq "") {
		warn "TCPH_ERROR Could not unlock crypted volume\n";
		exit($_INTERNAL_MOUNT);
	}
	$_DEBUG and warn "Crypted volume unlocked at $tmp_target_dev_path\n";

	my $mount_point = &mount_device($tmp_target_dev_path);
	if($mount_point eq "") {
		&lock_device($tmp_target_dev_path);
		warn "TCPH_ERROR Could not mount crypted volume\n";
		exit($_INTERNAL_MOUNT);
	}
	$_DEBUG and warn "Crypted volume mounted on $mount_point\n";

	# The above should mount the persistent partition on a predictable
	# mount point. If it does not, there is something badly wrong.
	# The sudo tools have the target mount point hard coded to prevent
	# them being used to overwrite parts of the system.

	if($mount_point ne "/media/tails-persistence-setup/TailsData") {
		warn "TCPH_ERROR Crypted volume mounted on unexpected mount point $mount_point. Aborting!";
		exit($_INTERNAL_MOUNT);
	}

	# Call syncer to copy files. This needs to escalate privileges in
	# order to read system files on the live persistent volume

	print "TCPH Copying files...\n";
	$err = system('/usr/bin/sudo', '/usr/bin/tails-clone-persistent-sync', "$source_dir");
	if($err) {
		&unmount_device($tmp_target_dev_path);
		&lock_device($partition);
		warn "TCPH_ERROR Error syncing files\nError: $err\n";
		exit((0xffff&$err) + $_ERR_RSYNC);
	}

	# ensure correct permissions on the root of the persistent disk
	# after rsync mucks them about - otherwise tails will barf. See
	# https://tails.boum.org/contribute/design/persistence/#security

	$err = system('/usr/bin/sudo', '/usr/bin/tails-fix-persistent-volume-permissions');
	if($err){
		&unmount_device($tmp_target_dev_path);
		&lock_device($partition);
		warn "TCPH_ERROR Could not set ACLs on $mount_point\nError: $err\n";
		exit((0xffff&$err) + $_ERR_SETFACL);
	}

	print "TCPH Unmounting and flushing data to disk\n";
	&unmount_device($tmp_target_dev_path);
	&lock_device($partition);

	print "TCPH Copy complete\n";
}

# Main routine
		
sub tails_clone_persistent_helper() {
	my $source_dir = shift;
	my $block_device = shift;
	my $mode = shift;

	if($ENV{"TCP_HELPER_DEBUG"}) {
		$_DEBUG=1;
	}

	$_DEBUG and warn "Args: ${source_dir} ${block_device} ${mode}\n";
	# sanitize our input
	if($source_dir =~ m!^([A-Za-z0-9.,=+_/-]*)$!) {
		$source_dir=$1;
	} else {
		print "Unsafe characters detected in SOURCE_DIR. Aborting\n";
		exit($_INTERNAL_SANITATION);
	}
	if($block_device =~ m!^([A-Za-z0-9.,=+_/-]*)$!) {
		$block_device=$1;
	} else {
		print "Unsafe characters detected in BLOCK_DEVICE. Aborting\n";
		exit($_INTERNAL_SANITATION);
	}

	my $partition = "${block_device}2";

	if($mode eq "new" || $mode eq "deniable") {
		if($block_device !~ m!^/dev/!) {
			print "Invalid BLOCK_DEVICE specified. Aborting\n";
			exit($_INTERNAL_SANITATION);
		}
		&make_partition($block_device, $partition, $mode);
	}
	# if we are told to copy nothing, quit early
	if($source_dir eq "") {
		print "TCPH Not copying any files, as requested\n";
	} else {
		&do_copy($source_dir, $partition);
	}
}


# START


if(@ARGV != 3 || $ARGV[2] !~ /^(existing|new|deniable)$/ ){
	warn <<EOF;
Usage: tails_clone_persistent_helper.pl SOURCE_DIR BLOCK_DEVICE MODE

"rsync --delete" the contents of SOURCE_DIR to a new or existing
persistent partition on the tails drive BLOCK_DEVICE

SOURCE_DIR: directory to be rsynced (without trailing /)
 (If the empty string is given, rsync is skipped)

BLOCK_DEVICE: the target Tails drive (NOT partition!)
 (e.g. "/dev/sdb")
 NB The target partition should be neither unlocked nor mounted

MODE: one of
 existing: update the contents of an existing persistent partition
 new:      delete any existing persistent partition and make a new one
 deniable: as "new", but randomise partition before making filesystem
            (can take a long time, perhaps several minutes/GB)
EOF
	exit($_INTERNAL_USAGE);
} else {
	&tails_clone_persistent_helper($ARGV[0], $ARGV[1], $ARGV[2]);
}
