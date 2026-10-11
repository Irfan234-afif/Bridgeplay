/* Tiny injectable dylib: reports that dyld loaded it. */
#include <stdio.h>

#ifndef MARKER
#define MARKER "marker"
#endif

__attribute__((constructor)) static void np_marker_loaded(void)
{
	fprintf(stderr, "loaded:%s\n", MARKER);
}
