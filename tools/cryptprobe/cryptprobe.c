/* cryptprobe <hash> — #254 claim-lock fix §11.3 (harness tool, never in an image): does the node's libc crypt()
 * (musl — the one busybox login and dropbear use: busybox USE_BB_CRYPT is off) accept the password on stdin (first
 * line, newline stripped) for <hash>? Prints MATCH / NOMATCH, rc 0 / 1; rc 2 = usage / no password / crypt error.
 * The password never goes on argv. Built static against the image's own musl (scripts/dv-cryptprobe-tools.sh);
 * the harness checks that the toolchain's musl version equals the node's /lib/libc.so before trusting a result. */
#include <crypt.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
	char pw[512];
	size_t n;
	const char *h;

	if (argc != 2) {
		fputs("usage: cryptprobe <hash>  (password on stdin)\n", stderr);
		return 2;
	}
	if (!fgets(pw, sizeof pw, stdin)) {
		fputs("no password on stdin\n", stderr);
		return 2;
	}
	n = strlen(pw);
	if (n && pw[n - 1] == '\n')
		pw[--n] = 0;
	h = crypt(pw, argv[1]);
	memset(pw, 0, sizeof pw);
	if (!h || h[0] == '*') {
		puts("CRYPT-ERROR");
		return 2;
	}
	if (strcmp(h, argv[1]) == 0) {
		puts("MATCH");
		return 0;
	}
	puts("NOMATCH");
	return 1;
}
