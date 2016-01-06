#include <strings.h>
#include <stdlib.h>
#include <unistd.h>
#include <iostream>
#include <string>
#include <cstring>
#include <regex.h>
#include <stdio.h>
#include <sys/stat.h>

// errors < 65536 are internal

#define _INTERNAL_USAGE 			0x0001
#define _INTERNAL_SANITATION 		0x0002
#define _INTERNAL_PARTED_UNPARSED 	0x0003
#define _INTERNAL_MOUNT 			0x0004

// errors >= 65536 result from failed subprocesses
// high two bytes identify subprocess
// low two bytes give subprocess exit code
// NB: 'dd' subprocess CAN (in theory) fail with error=0

#define _ERR_RSYNC	 				0x10000
#define _ERR_DD 					0x20000
#define _ERR_SETFACL 				0x30000
#define _ERR_CHMOD	 				0x40000
#define _ERR_PARTED_RM 				0x50000
#define _ERR_PARTED_MKPART 			0x60000
#define _ERR_PARTED_NAME 			0x70000
#define _ERR_LUKSCLOSE 				0x80000
#define _ERR_LUKSOPEN 				0x90000
#define _ERR_LUKSFORMAT 			0xa0000
#define _ERR_MKE2FS 				0xb0000


// tails uses a 64 bit kernel, but 32bit userspace.
// apt-get install libc6-dev-i386 g++-multilib
// g++ -m32 tcp-helper.c -o tcp-helper

// trick to force string concatenation with +
#define _STR std::string("")
//#define _STR std::string("echo ") //debugging

// global debug flag - we set this based on envar TCP_HELPER_DEBUG
int _DEBUG=0;

// parted cannot automatically find the beginning of free space, so we
// have to do it ourselves
std::string tails_free_start(std::string block_device, int *persistent_partition_exists) {
	*persistent_partition_exists=0;
	
	FILE *pipe = popen((_STR + 
		"/sbin/parted " + block_device + " p").c_str(), "r");
	if(!pipe) return("");
	
	size_t len, offset;
	char *line, buffer[100];
	line = (char *)malloc(1000);
	buffer[0]='\0';
	
	// fast-forward past the disk info until we find a blank line
	while(fgets(line, 1000, pipe)) {
		if(strlen(line) < 3) break;
		if(_DEBUG) std::cerr << "Skipping line: " << line;
	}

	// find the location of /End .*(?=Size )/ in the line buffer
	// if this succeeds, then overwrite the line buffer with the next 
	// line and copy out what falls in the same window
	// this should be "2621MB\s+" or similar
	
	if(fgets(line, 1000, pipe)) {
		if(_DEBUG) std::cerr << "Got input: " << line;
		std::string temp = line;
		if((offset=temp.find("End ")) && 
				(len=temp.find("Size ")-offset)) {
			if(fgets(line, 1000, pipe)) {
				strncpy(buffer, line+offset, len);
				// make double sure it's properly null terminated
				buffer[len]='\0';
				
				if(_DEBUG) std::cerr << "Got partition end location: " << buffer <<"\n";
				// check to see if a second partition exists
				if(fgets(line, 1000, pipe)) {
					if(strlen(line) > 3) {
						*persistent_partition_exists=1;
						// sanity check that no more partitions exist
						if(fgets(line, 1000, pipe)) {
							if(strlen(line) > 3) {
								std::cerr << "Found too many partitions!\n";
								buffer[0]='\0';
							}
						}
					}
				}
			}
		}
	}
	fclose(pipe);
	
	return _STR + buffer;
}

std::string mount_device(std::string device) {
	char *mount_point=NULL;
	
	std::cerr << "Mounting crypted partition...\n";
	FILE *pipe = popen((_STR + "/usr/bin/udisksctl mount --block-device " + device).c_str(), "r");
	if(!pipe) return("");

	char line[1000];
	while(fgets(line, 1000, pipe)) {
		if(_DEBUG) std::cerr << "Got input: " << line;
		char *bookmark, *bit1, *bit2, *bit3;
		// don't test the result of bit2, as it is unpredictable
		if(!strcmp(bit1=strtok_r(line, " ", &bookmark), "Mounted") &&
			(bit2=strtok_r(0, " ", &bookmark)) &&
			!strcmp(bit3=strtok_r(0, " ", &bookmark), "at")) {
				mount_point = strtok_r(0, "\n", &bookmark);
		} else {
			// remind me again why this is here?
			// if(_DEBUG) std::cerr << "Parsed output: " << bit1 << "::"<<bit2<<"::"<<bit3<<"::"<<mount_point<<"\n";
		}
	}
	fclose(pipe);
	
	if(mount_point==NULL) {
		std::cerr << "Could not mount filesystem!\n";
		return("");
	}
	
	// Test to see if udisksctl has appended a full stop to the output
	// and delete it. Some versions do, some don't.
	if(mount_point[strlen(mount_point)-1]=='.') {
		if(_DEBUG) std::cerr << "Truncating trailing punctuation\n";
		mount_point[strlen(mount_point)-1] = '\0';
	}
	return(_STR + mount_point);
}

void luks_close_and_spinlock(std::string block_device) {
	// use this to make sure all data is flushed and cryption stopped
	int err;
	do {
		std::cout << "Attempting to stop device (waiting for buffers to flush)\n";
		err = system((_STR + "/sbin/cryptsetup luksClose " + block_device).c_str());
	} while( err == 5 );
	if(err) {
		std::cerr << "Failed to lock partition! PANIC!\nError: " << err << "\n";
		exit((0xffff&err) + _ERR_LUKSCLOSE);
	}
}

void do_copy(std::string source_location, std::string block_device, std::string mode) {
	int err;
	std::string partition = block_device + "2";

	if(mode.compare("existing")==0) {
		
		std::cout << "Using existing partition\n";

	} else if(mode.compare("new")==0 || mode.compare("deniable")==0) {

		// call-by-ref information flag
		int persistent_partition_exists = 0;
		std::string start = tails_free_start(block_device, &persistent_partition_exists);
		if(start.compare("")==0) {
			std::cerr << "Could not detect end of tails primary partition\n";
			exit(_INTERNAL_PARTED_UNPARSED);
		}
		
		// if >2 partitions, tails_free_start would have aborted above
		// so safe to assume we need to trash one partition at most
		if(persistent_partition_exists) {
			if(_DEBUG) std::cerr << "Deleting old second partition\n";
			err = system((_STR + "/sbin/parted -s " + block_device + " rm 2").c_str() );	
			if(err) {
				std::cerr << "Could not delete old persistent partition\nError: " << err << "\n";
				exit((0xffff&err) + _ERR_PARTED_RM);
			}
		}

		if(_DEBUG) std::cerr << "Making new secondary partition\n";
		err = system((_STR + "/sbin/parted -s " + block_device + " mkpart primary " + start + " 100%").c_str() );
		if(err) {
			std::cerr << "Could not create new partition\nError: " << err << "\n";
			exit((0xffff&err) + _ERR_PARTED_MKPART);
		}

		if(_DEBUG) std::cerr << "Renaming partition label\n";
		err = system((_STR + "/sbin/parted -s " + block_device + " name 2 TailsData").c_str() );
		if(err) {
			std::cerr << "Could not rename new partition\nError: " << err << "\n";
			exit((0xffff&err) + _ERR_PARTED_NAME);
		}

		if(_DEBUG) std::cerr << "Initialising new crypted volume\n";
		err = system((_STR + "/sbin/cryptsetup luksFormat " + partition).c_str() );
		if(err) {
			std::cerr << "Could not initialise crypted volume\nError: " << err << "\n";
			exit((0xffff&err) + _ERR_LUKSFORMAT);
		}

		if(_DEBUG) std::cerr << "Unlocking new crypted volume\n";
		err = system((_STR + "/sbin/cryptsetup luksOpen " + partition + " TailsData_target").c_str() );
		if(err) {
			std::cerr << "Could not unlock new crypted volume\nError: " << err << "\n";
			exit((0xffff&err) + _ERR_LUKSOPEN);
		}
		
		// plausible deniability
		if(mode.compare("deniable")==0) {
			std::cout << "Randomising free space for plausible deniability. This may take a while.\n";
			// "a while" =~ 5-10 mins/GB on crappy hardware ;-)
			
			err = system((_STR + "/bin/dd if=/dev/zero of=/dev/mapper/TailsData_target bs=8192").c_str() );
			if(err != 256) { 
				// yes, we WANT to fail with "no space left on device"!
				std::cerr << "Could not randomise free space on new crypted volume\nError: " << err << "\n";
				luks_close_and_spinlock("/dev/mapper/TailsData_target");
				exit((0xffff&err) + _ERR_DD);		
			}
		}
		
		// if we're called for deniability purposes only, we _could_
		// call luksClose right now and prematurely return(), shaving
		// some time off the process - this will need a new mode
		// may not be worth the complexity for such a small benefit?
		
		if(_DEBUG) std::cerr << "Creating filesystem\n";
		err = system((_STR + "/sbin/mke2fs -j -t ext4 -L TailsData /dev/mapper/TailsData_target").c_str() );
		if(err) {
			std::cerr << "Could not create filesystem on new crypted volume\nError: " << err << "\n";
			luks_close_and_spinlock("/dev/mapper/TailsData_target");
			exit((0xffff&err) + _ERR_MKE2FS);
		}
		
		// stop the luks device to force a flush on slow devices
		luks_close_and_spinlock("/dev/mapper/TailsData_target");
	}

	// (re)open the crypted device
	err = system((_STR + "/sbin/cryptsetup luksOpen " + partition + " TailsData_target").c_str());
	if(err) {
		std::cerr << "Could not unlock crypted volume\nError: " << err << "\n";
		exit((0xffff&err) + _ERR_LUKSOPEN);
	}

	std::string mount_point = mount_device("/dev/mapper/TailsData_target");
	if(mount_point.compare("")==0) {
		std::cerr << "Could not mount crypted volume\n";
		luks_close_and_spinlock("/dev/mapper/TailsData_target");
		exit(_INTERNAL_MOUNT);
	}
	if(_DEBUG) std::cerr << "Crypted volume mounted on " << mount_point << "\n";

	// if we are told to copy nothing, skip the rsync
	if(source_location.compare("")!=0) {
		// run rsync to copy files. Note that --delete does NOT delete
		// --exclude'd files on the target.
		std::cout << "Copying files...";
		err = system((_STR + "/usr/bin/rsync -a --delete --exclude=gnupg/random_seed --exclude=lost+found " + source_location + "/ " + mount_point).c_str());
		if(err) {
			std::cerr << "Error syncing files\nError: " << err << "\n";
			luks_close_and_spinlock("/dev/mapper/TailsData_target");
			exit((0xffff&err) + _ERR_RSYNC);
		}
		std::cout << "done\n";
	} else {
		std::cout << "Not copying any files, as requested\n";
	}
	
	// ensure correct permissions on the root of the persistent disk
	// after rsync mucks them about - otherwise tails will barf. See
	// https://tails.boum.org/contribute/design/persistence/#security
	err = chmod(mount_point.c_str(), 0775);
	if(err){
		std::cerr << "Could not set permissions on " << mount_point << "\nError: " << err << "\n";
		system((_STR + "/usr/bin/udisksctl unmount --force --block-device /dev/mapper/TailsData_target").c_str());
		luks_close_and_spinlock("/dev/mapper/TailsData_target");
		exit((0xffff&err) + _ERR_CHMOD);
	}
	err = system((_STR + "/usr/bin/setfacl -m user:tails-persistence-setup:rwx " + mount_point).c_str());
	if(err){
		std::cerr << "Could not set ACLs on " << mount_point << "\nError: " << err << "\n";
		system((_STR + "/usr/bin/udisksctl unmount --force --block-device /dev/mapper/TailsData_target").c_str());
		luks_close_and_spinlock("/dev/mapper/TailsData_target");
		exit((0xffff&err) + _ERR_SETFACL);
	}

	system((_STR + "/usr/bin/udisksctl unmount --block-device /dev/mapper/TailsData_target").c_str());
	luks_close_and_spinlock("/dev/mapper/TailsData_target");
	
	std::cout << "Copy complete\n";
}

int main(int ARGC, char **ARGV) {
	if(getenv("TCP_HELPER_DEBUG")) {
		_DEBUG=1;
	}
	if(ARGC != 4 || (
			strcmp(ARGV[3], "existing") && 
			strcmp(ARGV[3], "new") && 
			strcmp(ARGV[3], "deniable") )){
		std::cerr << 
"Usage: " << ARGV[0] << " SOURCE_DIR BLOCK_DEVICE MODE\n" <<
"\n" <<
"\"rsync --delete\" the contents of SOURCE_DIR to a new or existing\n" <<
"persistent partition on the tails drive BLOCK_DEVICE\n" <<
"\n" <<
"SOURCE_DIR: directory to be rsynced (without trailing /)\n" <<
" (If the empty string is given, rsync is skipped)\n" <<
"\n" <<
"BLOCK_DEVICE: the target Tails drive (NOT partition!)\n" <<
" (e.g. \"/dev/sdb\")\n" <<
"\n" <<
"MODE: one of\n" <<
" existing: update the contents of an existing persistent partition\n" <<
" new:      delete any existing persistent partition and make a new one\n" <<
" deniable: as \"new\", but randomise partition before making filesystem\n" <<
"            (can take a long time, perhaps several minutes/GB)\n" <<
"\n";

		exit(_INTERNAL_USAGE);
	} else {
		if(_DEBUG) std::cerr << "Args: " << std::string(ARGV[1]) <<" "<< std::string(ARGV[2]) <<" "<< std::string(ARGV[3]) << "\n";
		// sanitize our input
		regex_t bad_chars[100];
		regcomp(bad_chars, "[^A-Za-z0-9.,=+_/-]", REG_NOSUB);
		for(int i=1; i<=2; i++) {
			int safe = regexec(bad_chars, ARGV[i], 0, 0, 0);
			if(!safe) {
				std::cerr << "Unsafe characters detected in filename. Aborting\n";
				exit(_INTERNAL_SANITATION);
			}
		}
		setreuid(0,0);
		do_copy(std::string(ARGV[1]), std::string(ARGV[2]), std::string(ARGV[3]));
	}
}
