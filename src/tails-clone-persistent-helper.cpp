#include <strings.h>
#include <stdlib.h>
#include <string>
#include <cstring>
#include <unistd.h>

int main(int ARGC, char **ARGV) {		
	// Bake in our setuid
	setreuid(0,0);
	
	// Now call our perl script and let it handle any syntax errors
	if(ARGC==4) {
		system((std::string("/usr/bin/tails-clone-persistent-helper.pl ")
			+ ARGV[1] + " " + ARGV[2] + " " + ARGV[3]).c_str());
	} else {
		// call with no arguments to get the usage summary
		system(std::string("/usr/bin/tails-clone-persistent-helper.pl").c_str())
	}
}
