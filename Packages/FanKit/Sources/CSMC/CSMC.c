#include "CSMC.h"
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_WRITE_BYTES 6
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } SMCKeyInfoRaw;

typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimitData;
    SMCKeyInfoRaw keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

io_connect_t csmc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    io_connect_t conn = 0;
    kern_return_t r = IOServiceOpen(service, mach_task_self(), 0, &conn);
    IOObjectRelease(service);
    return r == kIOReturnSuccess ? conn : 0;
}

void csmc_close(io_connect_t conn) {
    if (conn) IOServiceClose(conn);
}

static kern_return_t call(io_connect_t conn, SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, sizeof(SMCKeyData), out, &outSize);
}

kern_return_t csmc_key_info(io_connect_t conn, uint32_t key, CSMCKeyInfo *info) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    kern_return_t r = call(conn, &in, &out);
    if (r != kIOReturnSuccess) return r;
    if (out.result != 0) return kIOReturnNotFound;
    info->dataSize = out.keyInfo.dataSize;
    info->dataType = out.keyInfo.dataType;
    info->dataAttributes = (uint8_t)out.keyInfo.dataAttributes;
    return kIOReturnSuccess;
}

kern_return_t csmc_read(io_connect_t conn, uint32_t key, CSMCKeyInfo *info, uint8_t outBytes[32]) {
    kern_return_t r = csmc_key_info(conn, key, info);
    if (r != kIOReturnSuccess) return r;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key;
    in.keyInfo.dataSize = info->dataSize;
    in.data8 = SMC_CMD_READ_BYTES;
    r = call(conn, &in, &out);
    if (r != kIOReturnSuccess) return r;
    if (out.result != 0) return kIOReturnError;
    memcpy(outBytes, out.bytes, 32);
    return kIOReturnSuccess;
}

kern_return_t csmc_read_sized(io_connect_t conn, uint32_t key, uint32_t size, uint8_t outBytes[32]) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key;
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_READ_BYTES;
    kern_return_t r = call(conn, &in, &out);
    if (r != kIOReturnSuccess) return r;
    if (out.result != 0) return kIOReturnError;
    memcpy(outBytes, out.bytes, 32);
    return kIOReturnSuccess;
}

kern_return_t csmc_write(io_connect_t conn, uint32_t key, const uint8_t *bytes, uint32_t size) {
    CSMCKeyInfo info;
    kern_return_t r = csmc_key_info(conn, key, &info);
    if (r != kIOReturnSuccess) return r;
    if (info.dataSize != size || size > 32) return kIOReturnBadArgument;
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = key;
    in.data8 = SMC_CMD_WRITE_BYTES;
    in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    r = call(conn, &in, &out);
    if (r != kIOReturnSuccess) return r;
    return out.result == 0 ? kIOReturnSuccess : kIOReturnError;
}

kern_return_t csmc_key_at_index(io_connect_t conn, uint32_t index, uint32_t *key) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.data8 = SMC_CMD_READ_INDEX;
    in.data32 = index;
    kern_return_t r = call(conn, &in, &out);
    if (r != kIOReturnSuccess) return r;
    *key = out.key;
    return kIOReturnSuccess;
}

// MARK: - HID temperature sensors (Apple Silicon)

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef property);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define IOHIDEventFieldBase(type) ((type) << 16)

static IOHIDEventSystemClientRef sharedClient(void) {
    static IOHIDEventSystemClientRef client = NULL;
    if (client) return client;
    client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!client) return NULL;
    int page = 0xff00, usage = 5;
    CFNumberRef pageNum = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usageNum = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *vals[] = { pageNum, usageNum };
    CFDictionaryRef match = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(client, match);
    CFRelease(match); CFRelease(pageNum); CFRelease(usageNum);
    return client;
}

CFArrayRef csmc_copy_hid_temperatures(void) {
    IOHIDEventSystemClientRef client = sharedClient();
    if (!client) return NULL;
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (!services) return NULL;
    CFMutableArrayRef result = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFIndex count = CFArrayGetCount(services);
    for (CFIndex i = 0; i < count; i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        CFTypeRef name = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
        if (!name) continue;
        if (CFGetTypeID(name) != CFStringGetTypeID()) { CFRelease(name); continue; }
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(svc, kIOHIDEventTypeTemperature, 0, 0);
        if (!event) { CFRelease(name); continue; }
        double value = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
        CFRelease((CFTypeRef)event);
        CFNumberRef num = CFNumberCreate(NULL, kCFNumberDoubleType, &value);
        const void *keys[] = { CFSTR("name"), CFSTR("value") };
        const void *vals[] = { name, num };
        CFDictionaryRef d = CFDictionaryCreate(NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFArrayAppendValue(result, d);
        CFRelease(d); CFRelease(num); CFRelease(name);
    }
    CFRelease(services);
    return result;
}

double csmc_hid_max_temperature(const char *prefix) {
    static CFMutableArrayRef cached = NULL;
    static char cachedPrefix[32] = {0};
    if (!cached || strncmp(cachedPrefix, prefix, sizeof cachedPrefix) != 0) {
        IOHIDEventSystemClientRef client = sharedClient();
        if (!client) return -1;
        CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
        if (!services) return -1;
        if (cached) CFRelease(cached);
        cached = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        strncpy(cachedPrefix, prefix, sizeof cachedPrefix - 1);
        CFStringRef cfPrefix = CFStringCreateWithCString(NULL, prefix, kCFStringEncodingUTF8);
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
            CFTypeRef name = IOHIDServiceClientCopyProperty(svc, CFSTR("Product"));
            if (name && CFGetTypeID(name) == CFStringGetTypeID() && CFStringHasPrefix((CFStringRef)name, cfPrefix)) {
                CFArrayAppendValue(cached, svc);
            }
            if (name) CFRelease(name);
        }
        CFRelease(cfPrefix);
        CFRelease(services);
    }
    double best = -1;
    for (CFIndex i = 0; i < CFArrayGetCount(cached); i++) {
        IOHIDServiceClientRef svc = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(cached, i);
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(svc, kIOHIDEventTypeTemperature, 0, 0);
        if (!event) continue;
        double v = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
        CFRelease((CFTypeRef)event);
        if (v > best) best = v;
    }
    return best;
}
