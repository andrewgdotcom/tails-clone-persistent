#include <strings.h>
#include <stdlib.h>
#include <unistd.h>
#include <iostream>
#include <string>
#include <cstring>
#include <regex.h>
#include <stdio.h>
#include <sys/stat.h>

#define _DEBUG false

// can we detect this instead of hard coding it?
#define _TAILS_FREE_START std::string("2621")

// tails uses a 64 bit kernel, but 32bit userspace.
// apt-get install libc6-dev-i386 g++-multilib
// g++ -m32 tcp-helper.c -o tcp-helper

// trick to force string concatenation with +
#define _STR std::string("")
//#define _STR std::string("echo ")

std::string mount_device(std::string device) {
	std::string mount_point ("");
	
	std::cerr << "Mounting crypted partition...\n";
	FILE *pipe = popen((_STR + 
//"\"\\nfoo\\n\" Mounted /dev/mapper/TailsData_target at /media/foobar " +
	"/usr/bin/udisks --mount " + device).c_str(), "r");
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
	std::string partition = block_device + "2";

	if(mode.compare("--existing")==0) {
		std::cout << "Using existing partition\n";
		system((_STR + "/sbin/cryptsetup luksOpen " + partition + " TailsData_target").c_str());
	} else if(mode.compare("--new")==0) {
		std::cout << "Creating new partition\n";
		system((_STR + "/sbin/parted -s " + block_device + " mkpart primary " + _TAILS_FREE_START + " 100%").c_str());
		system((_STR + "/sbin/parted -s " + block_device + " name 2 TailsData").c_str());
		system((_STR + "/sbin/cryptsetup luksFormat " + partition).c_str());
		system((_STR + "/sbin/cryptsetup luksOpen " + partition + " TailsData_target").c_str());
		system((_STR + "/sbin/mke2fs -j -t ext4 -L TailsData /dev/mapper/TailsData_target").c_str());
	}
	
	std::string mount_point = mount_device("/dev/mapper/TailsData_target");
	if(mount_point.compare("")==0) {
		std::cerr << "Could not mount crypted volume\n";
		exit(1);
	}
	if(_DEBUG) std::cerr << "Crypted volume mounted on " << mount_point << "\n";

	// run rsync to copy files. Note that --delete does NOT delete
	// --exclude'd files on the target. This is fine: lost+found should
	// be kept, and random_seed does no harm. Does it?
	std::cout << "Copying files...";
	system((_STR + "/usr/bin/rsync -a --delete --exclude=gnupg/random_seed --exclude=lost+found " + source_location + "/ " + mount_point).c_str());
	std::cout << "done\n";
	
	// ensure correct permissions on the root of the persistent disk
	// after rsync mucks them about - otherwise tails will barf. See
	// https://tails.boum.org/contribute/design/persistence/#security
	int err = chmod(mount_point.c_str(), 0775);
	if(err != 0){
		std::cerr << "Could not set permissions on " << mount_point << "\n";
		std::cerr << "Disk is still mounted\n";
		exit(1);
	}
	system((_STR + "/usr/bin/setfacl -m user:tails-persistence-setup:rwx " + mount_point).c_str());

	system((_STR + "/usr/bin/udisks --unmount /dev/mapper/TailsData_target").c_str());
	do {
		std::cout << "Attempting to stop device (waiting for buffers to flush)\n";
	} while( system((_STR + "/sbin/cryptsetup luksClose TailsData_target").c_str()) );
	std::cout << "Copy complete\n";
}

int main(int ARGC, char **ARGV) {
	if(ARGC != 4 || !(!strcmp(ARGV[3], "--existing") || !strcmp(ARGV[3], "--new")) ){
		std::cerr << "Usage: " << ARGV[0] << " SOURCE_DIR BLOCK_DEVICE (--existing|--new)\n";
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
