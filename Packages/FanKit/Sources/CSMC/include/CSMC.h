#ifndef CSMC_H
#define CSMC_H

#include <stdint.h>
#include <stdbool.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t  dataAttributes;
} CSMCKeyInfo;

/// Opens a connection to AppleSMC. Returns 0 on failure.
io_connect_t csmc_open(void);
void csmc_close(io_connect_t conn);

/// Reads a key. `out` must hold 32 bytes. Returns kIOReturnSuccess on success.
kern_return_t csmc_read(io_connect_t conn, uint32_t key, CSMCKeyInfo *info, uint8_t out[32]);
/// Reads a key whose size is already known (one kernel call instead of two).
kern_return_t csmc_read_sized(io_connect_t conn, uint32_t key, uint32_t size, uint8_t out[32]);
/// Writes `size` bytes to a key (requires root).
kern_return_t csmc_write(io_connect_t conn, uint32_t key, const uint8_t *bytes, uint32_t size);
kern_return_t csmc_key_info(io_connect_t conn, uint32_t key, CSMCKeyInfo *info);
/// Key at index (for enumerating all keys).
kern_return_t csmc_key_at_index(io_connect_t conn, uint32_t index, uint32_t *key);

/// Highest temperature among HID sensors whose product name starts with `prefix`, or -1 if none.
/// The matching services are discovered once and cached.
double csmc_hid_max_temperature(const char *prefix);

/// Apple Silicon HID temperature sensors. Returns a CFArray of CFDictionary {name: CFString, value: CFNumber(double)}.
/// Caller owns the result. May return NULL.
CFArrayRef csmc_copy_hid_temperatures(void);

#endif
