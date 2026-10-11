// Private entry points of hid_profile.c, for the unit tests in tests/. The shim itself
// only uses np_pad.h.

#ifndef NP_HID_PROFILE_INTERNAL_H
#define NP_HID_PROFILE_INTERNAL_H

#include "np_pad.h"
#include <stddef.h>

// The device-independent core of np_profile_create: descriptor = the HID report
// descriptor bytes (kIOHIDReportDescriptorKey), name = kIOHIDProductKey (may be NULL).
np_profile *np_profile_create_from_descriptor(const uint8_t *descriptor, size_t length,
                                              uint16_t vendor, uint16_t product,
                                              uint16_t version, const char *name);

// Number of SDL axes, buttons and hats the profile sees (SDL IOKit numbering).
void np_profile_counts(const np_profile *profile, int *axes, int *buttons, int *hats);

// np_pad_mode's decision without the process lookups and caching: env = $NP_PAD_MODE
// (NULL when unset), has_unity = a loaded image path contains "UnityPlayer".
int np_pad_mode_from(const char *env, int has_unity);

#endif
