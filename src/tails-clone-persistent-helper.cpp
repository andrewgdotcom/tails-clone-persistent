#include <stdlib.h>
#include <unistd.h>

int main(int ARGC, char **ARGV) {		
	// Bake in our setuid
	setreuid(0,0);
	
	// Now call our perl script and let it handle any syntax errors
	if(ARGC==4) {
		execl("/usr/bin/tails-clone-persistent-helper.pl",
			"tails-clone-persistent-helper.pl",
			ARGV[1], ARGV[2], ARGV[3], (char *)NULL);
	} else {
		// call with no arguments to get the usage summary
		execl("/usr/bin/tails-clone-persistent-helper.pl",
			"tails-clone-persistent-helper.pl", (char *)NULL);
	}
}
