// Plug and Play helpers for DeviceKit on Windows: the USB device behind a drive letter, "safely remove",
// and volume arrival notifications. Written in C because Swift's WinSDK module doesn't cover cfgmgr32,
// and importing cfgmgr32.h as a second Clang module clashes with WinSDK's definitions. This header only
// uses plain C types; the Windows headers stay inside CWinDevices.c. Empty on other platforms.
#pragma once
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
/// Vendor id, product id and serial number of the USB device hosting `drive` ('E' for E:).
/// Returns 1 when found. `serial` gets a NUL-terminated UTF-16 string (empty when the device has none).
int ipm_usb_identity(uint16_t drive, uint32_t *vendor, uint32_t *product, uint16_t *serial, size_t serialCapacity);

/// Asks Plug and Play to eject the disk behind `drive`. Returns 1 on success; on refusal `veto` gets the
/// name of what refused (NUL-terminated UTF-16), possibly empty.
int ipm_eject(uint16_t drive, uint16_t *veto, size_t vetoCapacity);

/// Calls `callback(context)` on a thread pool thread whenever a volume arrives or goes away.
/// Returns an opaque handle for ipm_watch_stop, or NULL.
void *ipm_watch_start(void (*callback)(void *context), void *context);

/// Stops the notifications; waits for callbacks in flight, so none runs after it returns.
void ipm_watch_stop(void *handle);
#endif
