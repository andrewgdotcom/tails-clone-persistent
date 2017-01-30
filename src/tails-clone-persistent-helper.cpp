#include <strings.h>
#include <stdlib.h>
#include <string>
#include <cstring>
#include <unistd.h>

int main(int ARGC, char **ARGV) {	
	// Transpose our arguments, if they exist
	std::string arg1, arg2, arg3;
	if(ARGC >1) arg1 = ARGV[1];
	if(ARGC >2) arg1 = ARGV[2];
	if(ARGC >3) arg1 = ARGV[3];
	
	// Bake in our setuid
	setreuid(0,0);
	
	// Now call our perl script and let it handle any syntax errors
	system((std::string("/usr/bin/tails-clone-persistent-helper.pl ")
			+ arg1 + " " + arg2 + " " + arg3).c_str());
}
