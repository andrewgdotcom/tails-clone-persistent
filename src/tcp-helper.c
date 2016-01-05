#include <strings.h>
#include <stdlib.h>
#include <unistd.h>
#include <iostream>
#include <string>
#include <cstring>
#include <regex.h>
#include <stdio.h>
#include <sys/stat.h>

int _DEBUG;

// tails uses a 64 bit kernel, but 32bit userspace.
// apt-get install libc6-dev-i386 g++-multilib
// g++ -m32 tcp-helper.c -o tcp-helper

// trick to force string concatenation with +
#define _STR std::string("")
//#define _STR std::string("echo ") //debugging

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

	// find the location of the string "End\s+" in the line buffer
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
	std::string mount_point ("");
	
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
			if(_DEBUG) std::cerr << "Parsed output: " << bit1 << "::"<<bit2<<"::"<<bit3<<"::"<<mount_point<<"\n";
		}
	}
	fclose(pipe);
	return(mount_point);
}

void do_copy(std::string source_location, std::string block_device, std::string mode) {
	int err;
	std::string partition = block_device + "2";

	if(mode.compare("existing")==0) {
		
		std::cout << "Using existing partition\n";
		system((_STR + "/sbin/cryptsetup luksOpen " + partition + " TailsData_target").c_str());

	} else if(mode.compare("new")==0 || mode.compare("deniable")==0) {

		int persistent_partition_exists = 0;
		std::string start = tails_free_start(block_device, &persistent_partition_exists);
		if(start.compare("")==0) {
			std::cerr << "Could not detect start of free space\n";
			exit(1);
		}
		std::cout << "Creating new partition\n";
		
		// if >2 partitions, tails_free_start would have aborted above
		// so safe to assume we need to trash one partition at most
		if(persistent_partition_exists) {
			system((_STR + "/sbin/parted -s " + block_device + " rm 2").c_str());
		}

		system((_STR + "/sbin/parted -s " + block_device + " mkpart primary " + start + " 100%").c_str());
		system((_STR + "/sbin/parted -s " + block_device + " name 2 TailsData").c_str());
		system((_STR + "/sbin/cryptsetup luksFormat " + partition).c_str());
		system((_STR + "/sbin/cryptsetup luksOpen " + partition + " TailsData_target").c_str());
		
		// plausible deniability
		if(mode.compare("deniable")==0) {
			std::cout << "Randomising free space for plausible deniability.";
			system((_STR + "/bin/dd if=/dev/zero of=/dev/mapper/TailsData_target").c_str());	
		}
		
		// if we're called for deniability purposes only, we _could_
		// call luksClose right now and prematurely return(), shaving
		// some time off the process - this will need a new mode
		// may not be worth the complexity for such a small benefit?
		
		system((_STR + "/sbin/mke2fs -j -t ext4 -L TailsData /dev/mapper/TailsData_target").c_str());
	}

	std::string mount_point = mount_device("/dev/mapper/TailsData_target");
	if(mount_point.compare("")==0) {
		std::cerr << "Could not mount crypted volume\n";
		exit(1);
	}
	if(_DEBUG) std::cerr << "Crypted volume mounted on " << mount_point << "\n";

	// if we are told to copy nothing, skip the rsync
	if(source_location.compare("")!=0) {
		// run rsync to copy files. Note that --delete does NOT delete
		// --exclude'd files on the target.
		std::cout << "Copying files...";
		system((_STR + "/usr/bin/rsync -a --delete --exclude=gnupg/random_seed --exclude=lost+found " + source_location + "/ " + mount_point).c_str());
		std::cout << "done\n";
	}
	
	// ensure correct permissions on the root of the persistent disk
	// after rsync mucks them about - otherwise tails will barf. See
	// https://tails.boum.org/contribute/design/persistence/#security
	err = chmod(mount_point.c_str(), 0775);
	if(err != 0){
		std::cerr << "Could not set permissions on " << mount_point << "\n";
		system((_STR + "/usr/bin/udisksctl unmount --force --block-device /dev/mapper/TailsData_target").c_str());
		exit(1);
	}
	err = system((_STR + "/usr/bin/setfacl -m user:tails-persistence-setup:rwx " + mount_point).c_str());
	if(err != 0){
		std::cerr << "Could not set ACLs on " << mount_point << "\n";
		system((_STR + "/usr/bin/udisksctl unmount --force --block-device /dev/mapper/TailsData_target").c_str());
		exit(1);
	}

	system((_STR + "/usr/bin/udisksctl unmount --block-device /dev/mapper/TailsData_target").c_str());

	do {
		std::cout << "Attempting to stop device (waiting for buffers to flush)\n";
	} while( system((_STR + "/sbin/cryptsetup luksClose TailsData_target").c_str()) );
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
		std::cerr << "Usage: " << ARGV[0] << 
			" SOURCE_DIR BLOCK_DEVICE (existing|new|deniable)\n";
		exit(-1);
	} else {
		if(_DEBUG) std::cerr << "Args: " << std::string(ARGV[1]) <<" "<< std::string(ARGV[2]) <<" "<< std::string(ARGV[3]) << "\n";
		// sanitize our input
		regex_t bad_chars[100];
		regcomp(bad_chars, "[^A-Za-z0-9.,=+_/-]", REG_NOSUB);
		for(int i=1; i<=2; i++) {
			int error = regexec(bad_chars, ARGV[i], 0, 0, 0);
			if(!error) {
				std::cerr << "Unsafe characters detected in filename. Aborting\n";
				exit(-1);
			}
		}
		setreuid(0,0);
		do_copy(std::string(ARGV[1]), std::string(ARGV[2]), std::string(ARGV[3]));
	}
}
