/* Test program: prints its running arch, pid, argv and the env vars named by
 * NP_PROBE_VARS (colon separated). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
#if defined(__arm64__)
	printf("arch=arm64\n");
#else
	printf("arch=x86_64\n");
#endif
	printf("pid=%d\n", (int)getpid());
	for (int i = 1; i < argc; i++)
		printf("arg%d=%s\n", i, argv[i]);
	const char *vars = getenv("NP_PROBE_VARS");
	if (vars) {
		char *copy = strdup(vars), *save = NULL;
		for (char *t = strtok_r(copy, ":", &save); t; t = strtok_r(NULL, ":", &save)) {
			const char *v = getenv(t);
			printf("%s=%s\n", t, v ? v : "(unset)");
		}
		free(copy);
	}
	return 0;
}
