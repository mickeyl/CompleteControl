#include "KontrolUSB.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/usb/IOUSBHostFamilyDefinitions.h>
#include <IOKit/usb/USBSpec.h>
#include <libusb.h>
#include <mach/mach_error.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define KONTROL_VID 0x17cc
#define KONTROL_PID 0x1340
#define KONTROL_INTERFACE 2
#define KONTROL_EP_OUT 0x02
#define KONTROL_EP_IN 0x84
#define KONTROL_NO_INTERFACE 0xff
#define KONTROL_NO_ENDPOINT 0x00

typedef enum {
    KONTROL_DEVICE_MK1 = 1,
    KONTROL_DEVICE_MK2 = 2,
} KontrolDeviceGeneration;

typedef struct {
    uint16_t productID;
    const char *name;
    KontrolDeviceGeneration generation;
    uint8_t keyCount;
    int8_t lightGuideNoteOffset;
    uint8_t claimInterface;
    uint8_t interruptInputEndpointFallback;
    uint8_t interruptOutputEndpointFallback;
    uint8_t displayInterface;
    uint8_t displayOutputEndpointFallback;
} KontrolDeviceDescriptor;

static const KontrolDeviceDescriptor kKontrolDevices[] = {
    {0x1340, "Komplete Kontrol S25 MK1", KONTROL_DEVICE_MK1, 25, -21, 2, 0x84, 0x02, KONTROL_NO_INTERFACE, KONTROL_NO_ENDPOINT},
    {0x1610, "Komplete Kontrol S49 MK2", KONTROL_DEVICE_MK2, 49, -36, 3, KONTROL_NO_ENDPOINT, KONTROL_NO_ENDPOINT, 3, 0x03},
    {0x1620, "Komplete Kontrol S61 MK2", KONTROL_DEVICE_MK2, 61, -36, 3, KONTROL_NO_ENDPOINT, KONTROL_NO_ENDPOINT, 3, 0x03},
    {0x1630, "Komplete Kontrol S88 MK2", KONTROL_DEVICE_MK2, 88, -21, 3, KONTROL_NO_ENDPOINT, KONTROL_NO_ENDPOINT, 3, 0x03},
};

static const size_t kKontrolDeviceCount = sizeof(kKontrolDevices) / sizeof(kKontrolDevices[0]);

static const KontrolDeviceDescriptor *kontrol_device_for_product(uint16_t productID) {
    for (size_t i = 0; i < kKontrolDeviceCount; i++) {
        if (kKontrolDevices[i].productID == productID) {
            return &kKontrolDevices[i];
        }
    }
    return NULL;
}

typedef struct {
    IOUSBInterfaceInterface **iface;
    uint8_t pipeRef;
    uint8_t endpointAddress;
    uint8_t numEndpoints;
} OpenedKontrolUSB;

typedef struct {
    libusb_context *ctx;
    libusb_device_handle *handle;
    const KontrolDeviceDescriptor *device;
    uint8_t claimedInterface;
    uint8_t surfaceInterface;
    uint8_t surfaceClaimed;
    uint8_t auxSurfaceInterface;
    uint8_t auxSurfaceClaimed;
    uint8_t inputEndpoint;
    uint8_t auxInputEndpoint;
    uint8_t outputEndpoint;
    uint8_t displayInterface;
    uint8_t displayOutputEndpoint;
    uint8_t midiInterface;
    uint8_t midiInputEndpoint;
    uint8_t midiClaimed;
    /* Async state */
    struct libusb_transfer *inputTransfer;
    struct libusb_transfer *auxInputTransfer;
    struct libusb_transfer *midiTransfer;
    KontrolUSBInputCallback inputCallback;
    void *inputUserData;
    KontrolUSBInputCallback midiCallback;
    void *midiUserData;
    int inputTransferStatus;
    int auxInputTransferStatus;
    int midiTransferStatus;
    int inputTransferPending;
    int auxInputTransferPending;
    int midiTransferPending;
    int closing;
    uint8_t inputBuffer[256];
    uint8_t auxInputBuffer[256];
    uint8_t midiBuffer[256];
} KontrolLibUSBSession;

#ifdef KK_DEBUG
#define KK_USB_LOG_QUEUE_CAPACITY 1024
#define KK_USB_LOG_LINE_MAX 1024

static pthread_mutex_t kk_usb_log_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t kk_usb_log_cond = PTHREAD_COND_INITIALIZER;
static char *kk_usb_log_queue[KK_USB_LOG_QUEUE_CAPACITY];
static int kk_usb_log_head = 0;
static int kk_usb_log_tail = 0;
static int kk_usb_log_count = 0;
static int kk_usb_log_started = 0;
static unsigned int kk_usb_log_dropped = 0;

static void *kk_usb_log_worker(void *unused) {
    (void)unused;
#if defined(__APPLE__)
    pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);
#endif
    while (1) {
        pthread_mutex_lock(&kk_usb_log_mutex);
        while (kk_usb_log_count == 0) {
            pthread_cond_wait(&kk_usb_log_cond, &kk_usb_log_mutex);
        }
        char *line = kk_usb_log_queue[kk_usb_log_head];
        kk_usb_log_queue[kk_usb_log_head] = NULL;
        kk_usb_log_head = (kk_usb_log_head + 1) % KK_USB_LOG_QUEUE_CAPACITY;
        kk_usb_log_count--;
        pthread_mutex_unlock(&kk_usb_log_mutex);

        if (line != NULL) {
            fputs(line, stderr);
            fflush(stderr);
            free(line);
        }
    }
    return NULL;
}

static void kk_usb_log_start_locked(void) {
    if (kk_usb_log_started) {
        return;
    }
    pthread_t thread;
    if (pthread_create(&thread, NULL, kk_usb_log_worker, NULL) == 0) {
        pthread_detach(thread);
        kk_usb_log_started = 1;
    }
}

static void kk_usb_log_enqueue(const char *line) {
    char *copy = strdup(line);
    if (copy == NULL) {
        return;
    }

    pthread_mutex_lock(&kk_usb_log_mutex);
    kk_usb_log_start_locked();
    if (!kk_usb_log_started || kk_usb_log_count >= KK_USB_LOG_QUEUE_CAPACITY) {
        kk_usb_log_dropped++;
        pthread_mutex_unlock(&kk_usb_log_mutex);
        free(copy);
        return;
    }
    if (kk_usb_log_dropped > 0) {
        char droppedLine[160];
        snprintf(droppedLine,
                 sizeof(droppedLine),
                 "timestamp=unknown group=usb-log level=TRACE message=droppedLogs=%u\n",
                 kk_usb_log_dropped);
        char *droppedCopy = strdup(droppedLine);
        if (droppedCopy != NULL && kk_usb_log_count < KK_USB_LOG_QUEUE_CAPACITY - 1) {
            kk_usb_log_queue[kk_usb_log_tail] = droppedCopy;
            kk_usb_log_tail = (kk_usb_log_tail + 1) % KK_USB_LOG_QUEUE_CAPACITY;
            kk_usb_log_count++;
            kk_usb_log_dropped = 0;
        }
    }
    kk_usb_log_queue[kk_usb_log_tail] = copy;
    kk_usb_log_tail = (kk_usb_log_tail + 1) % KK_USB_LOG_QUEUE_CAPACITY;
    kk_usb_log_count++;
    pthread_cond_signal(&kk_usb_log_cond);
    pthread_mutex_unlock(&kk_usb_log_mutex);
}

static int kk_usb_debug_flag_enabled(const char *value) {
    return value != NULL
        && value[0] != '\0'
        && strcmp(value, "0") != 0
        && strcasecmp(value, "false") != 0
        && strcasecmp(value, "no") != 0;
}

static int kk_usb_debug_enabled(void) {
    const char *level = getenv("LOGLEVEL");
    return kk_usb_debug_flag_enabled(getenv("KK_USB_DEBUG"))
        || kk_usb_debug_flag_enabled(getenv("KK_DAEMON_DEBUG"))
        || (level != NULL && strcasecmp(level, "TRACE") == 0);
}

static void kk_usb_debug_log(const char *group, const char *level, const char *format, ...) {
    if (!kk_usb_debug_enabled()) {
        return;
    }

    struct timeval tv;
    gettimeofday(&tv, NULL);

    struct tm tm;
    gmtime_r(&tv.tv_sec, &tm);

    char timestamp[40];
    snprintf(timestamp,
             sizeof(timestamp),
             "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
             tm.tm_year + 1900,
             tm.tm_mon + 1,
             tm.tm_mday,
             tm.tm_hour,
             tm.tm_min,
             tm.tm_sec,
             (int)(tv.tv_usec / 1000));

    char line[KK_USB_LOG_LINE_MAX];
    int offset = snprintf(line, sizeof(line), "timestamp=%s group=%s level=%s message=", timestamp, group, level);
    if (offset < 0 || offset >= (int)sizeof(line)) {
        return;
    }

    va_list args;
    va_start(args, format);
    int written = vsnprintf(line + offset, sizeof(line) - (size_t)offset, format, args);
    va_end(args);
    if (written < 0) {
        return;
    }
    size_t used = strnlen(line, sizeof(line));
    if (used >= sizeof(line) - 2) {
        used = sizeof(line) - 16;
        memcpy(line + used, " ...[truncated]", 16);
        used += 15;
    }
    line[used++] = '\n';
    line[used] = '\0';
    kk_usb_log_enqueue(line);
}

static void kk_usb_debug_head(char *out, size_t outLen, const uint8_t *data, int length) {
    if (outLen == 0) {
        return;
    }
    out[0] = '\0';
    if (data == NULL || length <= 0) {
        return;
    }

    size_t used = 0;
    int limit = length < 12 ? length : 12;
    for (int i = 0; i < limit && used < outLen; i++) {
        int written = snprintf(out + used, outLen - used, "%s%02x", i == 0 ? "" : " ", data[i]);
        if (written < 0) {
            out[0] = '\0';
            return;
        }
        used += (size_t)written;
    }
}
#else
#define kk_usb_debug_log(...) do { } while (0)
#endif

static void result_append(KontrolUSBResult *result, const char *format, ...) {
    size_t used = strnlen(result->message, sizeof(result->message));
    if (used >= sizeof(result->message) - 1) {
        return;
    }

    va_list args;
    va_start(args, format);
    vsnprintf(result->message + used, sizeof(result->message) - used, format, args);
    va_end(args);
}

static const char *status_string(IOReturn status) {
    const char *text = mach_error_string(status);
    return text != NULL ? text : "unknown";
}

static int int_property(io_service_t service, const char *key, int *out) {
    CFStringRef keyRef = CFStringCreateWithCStringNoCopy(kCFAllocatorDefault, key, kCFStringEncodingUTF8, kCFAllocatorNull);
    if (keyRef == NULL) {
        return 0;
    }

    CFTypeRef value = IORegistryEntryCreateCFProperty(service, keyRef, kCFAllocatorDefault, 0);
    CFRelease(keyRef);
    if (value == NULL) {
        return 0;
    }

    int ok = 0;
    if (CFGetTypeID(value) == CFNumberGetTypeID()) {
        ok = CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, out);
    }
    CFRelease(value);
    return ok;
}

static int is_kontrol_hid_interface(io_service_t service) {
    int vid = 0;
    int pid = 0;
    int interfaceNumber = 0;
    return int_property(service, kUSBHostMatchingPropertyVendorID, &vid)
        && int_property(service, kUSBHostMatchingPropertyProductID, &pid)
        && int_property(service, kUSBHostMatchingPropertyInterfaceNumber, &interfaceNumber)
        && vid == KONTROL_VID
        && pid == KONTROL_PID
        && interfaceNumber == KONTROL_INTERFACE;
}

static io_service_t find_interface(KontrolUSBResult *result) {
    CFMutableDictionaryRef match = IOServiceMatching(kIOUSBHostInterfaceClassName);
    if (match == NULL) {
        result->status = kIOReturnNoMemory;
        snprintf(result->message, sizeof(result->message), "IOServiceMatching(%s) failed", kIOUSBHostInterfaceClassName);
        return IO_OBJECT_NULL;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn status = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator);
    if (status != kIOReturnSuccess) {
        result->status = status;
        snprintf(result->message, sizeof(result->message), "IOServiceGetMatchingServices failed 0x%08x (%s)", status, status_string(status));
        return IO_OBJECT_NULL;
    }

    io_service_t service = IO_OBJECT_NULL;
    io_service_t candidate = IO_OBJECT_NULL;
    while ((candidate = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        if (is_kontrol_hid_interface(candidate)) {
            service = candidate;
            break;
        }
        IOObjectRelease(candidate);
    }
    IOObjectRelease(iterator);

    if (service == IO_OBJECT_NULL) {
        result->status = kIOReturnNotFound;
        snprintf(result->message, sizeof(result->message), "USB interface not found: VID 0x%04x PID 0x%04x interface %d", KONTROL_VID, KONTROL_PID, KONTROL_INTERFACE);
        return IO_OBJECT_NULL;
    }

    CFTypeRef owner = IORegistryEntryCreateCFProperty(service, CFSTR(kUSBHostPropertyExclusiveOwner), kCFAllocatorDefault, 0);
    if (owner != NULL) {
        if (CFGetTypeID(owner) == CFStringGetTypeID()) {
            char ownerText[160] = {0};
            CFStringGetCString((CFStringRef)owner, ownerText, sizeof(ownerText), kCFStringEncodingUTF8);
            result_append(result, "exclusiveOwner=%s; ", ownerText);
        }
        CFRelease(owner);
    }

    return service;
}

static IOReturn create_interface(io_service_t service, IOUSBInterfaceInterface ***ifaceOut, KontrolUSBResult *result) {
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    IOReturn status = IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    if (status != kIOReturnSuccess || plugin == NULL) {
        result_append(result, "IOCreatePlugInInterfaceForService -> 0x%08x (%s); ", status, status_string(status));
        return status != kIOReturnSuccess ? status : kIOReturnError;
    }

    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (LPVOID *)ifaceOut);
    IODestroyPlugInInterface(plugin);

    if (hr != S_OK || *ifaceOut == NULL) {
        result_append(result, "QueryInterface(IOUSBInterfaceInterface) -> 0x%08x; ", (unsigned int)hr);
        return kIOReturnUnsupported;
    }

    return kIOReturnSuccess;
}

static IOReturn find_out_pipe(IOUSBInterfaceInterface **iface, OpenedKontrolUSB *opened, KontrolUSBResult *result) {
    UInt8 endpoints = 0;
    IOReturn status = (*iface)->GetNumEndpoints(iface, &endpoints);
    if (status != kIOReturnSuccess) {
        result_append(result, "GetNumEndpoints -> 0x%08x (%s); ", status, status_string(status));
        return status;
    }

    result->numEndpoints = endpoints;
    opened->numEndpoints = endpoints;
    result_append(result, "endpoints=%u; ", endpoints);

    for (UInt8 pipe = 1; pipe <= endpoints; pipe++) {
        UInt8 direction = 0;
        UInt8 number = 0;
        UInt8 transferType = 0;
        UInt16 maxPacketSize = 0;
        UInt8 interval = 0;
        status = (*iface)->GetPipeProperties(iface, pipe, &direction, &number, &transferType, &maxPacketSize, &interval);
        if (status != kIOReturnSuccess) {
            result_append(result, "pipe%u GetPipeProperties -> 0x%08x; ", pipe, status);
            continue;
        }

        uint8_t address = (uint8_t)((direction == kUSBIn ? 0x80 : 0x00) | number);
        result_append(result, "pipe%u=ep0x%02x type%u max%u; ", pipe, address, transferType, maxPacketSize);
        if (address == KONTROL_EP_OUT && transferType == kUSBInterrupt) {
            opened->pipeRef = pipe;
            opened->endpointAddress = address;
            result->pipeRef = pipe;
            result->endpointAddress = address;
            return kIOReturnSuccess;
        }
    }

    return kIOReturnNotFound;
}

static IOReturn open_kontrol(OpenedKontrolUSB *opened, KontrolUSBResult *result) {
    memset(opened, 0, sizeof(*opened));

    io_service_t service = find_interface(result);
    if (service == IO_OBJECT_NULL) {
        return result->status;
    }

    IOReturn status = create_interface(service, &opened->iface, result);
    IOObjectRelease(service);
    if (status != kIOReturnSuccess) {
        result->status = status;
        return status;
    }

    status = (*opened->iface)->USBInterfaceOpenSeize(opened->iface);
    result_append(result, "USBInterfaceOpenSeize -> 0x%08x (%s); ", status, status_string(status));
    if (status != kIOReturnSuccess) {
        IOReturn fallback = (*opened->iface)->USBInterfaceOpen(opened->iface);
        result_append(result, "USBInterfaceOpen -> 0x%08x (%s); ", fallback, status_string(fallback));
        if (fallback != kIOReturnSuccess) {
            result->status = status;
            (*opened->iface)->Release(opened->iface);
            opened->iface = NULL;
            return status;
        }
        status = fallback;
    }

    result->opened = 1;
    status = find_out_pipe(opened->iface, opened, result);
    if (status != kIOReturnSuccess) {
        result_append(result, "endpoint 0x%02x interrupt OUT not found; ", KONTROL_EP_OUT);
        result->status = status;
    }

    return status;
}

static void close_kontrol(OpenedKontrolUSB *opened) {
    if (opened->iface != NULL) {
        (*opened->iface)->USBInterfaceClose(opened->iface);
        (*opened->iface)->Release(opened->iface);
        opened->iface = NULL;
    }
}

static IOReturn write_report(OpenedKontrolUSB *opened, uint8_t reportID, const uint8_t *payload, uint32_t payloadLen, KontrolUSBResult *result) {
    uint8_t buffer[256] = {0};
    uint32_t totalLen = payloadLen + 1;
    if (totalLen > sizeof(buffer)) {
        result_append(result, "report 0x%02x too large (%u bytes); ", reportID, totalLen);
        return kIOReturnOverrun;
    }

    buffer[0] = reportID;
    if (payloadLen > 0 && payload != NULL) {
        memcpy(buffer + 1, payload, payloadLen);
    }

    IOReturn status = (*opened->iface)->WritePipeTO(opened->iface, opened->pipeRef, buffer, totalLen, 50, 50);
    result_append(result, "WritePipeTO ep0x%02x report0x%02x len%u -> 0x%08x (%s); ",
                  opened->endpointAddress, reportID, totalLen, status, status_string(status));
    return status;
}

KontrolUSBResult KontrolUSBWriteReport(uint8_t reportID, const uint8_t *payload, uint32_t payloadLen) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = kIOReturnError;

    OpenedKontrolUSB opened;
    IOReturn status = open_kontrol(&opened, &result);
    if (status == kIOReturnSuccess) {
        status = write_report(&opened, reportID, payload, payloadLen, &result);
        result.status = status;
    }
    close_kontrol(&opened);

    return result;
}

KontrolUSBResult KontrolUSBRunDemo(void) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = kIOReturnError;

    OpenedKontrolUSB opened;
    IOReturn status = open_kontrol(&opened, &result);
    if (status != kIOReturnSuccess) {
        close_kontrol(&opened);
        return result;
    }

    const uint8_t init[] = {0x00, 0x00};
    status = write_report(&opened, 0xa0, init, sizeof(init), &result);
    usleep(60000);

    uint8_t keys[75] = {0};
    for (int i = 0; i < 25; i++) {
        keys[i * 3 + 0] = (uint8_t)(i < 9 ? 0xff : 0x00);
        keys[i * 3 + 1] = (uint8_t)(i >= 8 && i < 17 ? 0xff : 0x00);
        keys[i * 3 + 2] = (uint8_t)(i >= 16 ? 0xff : 0x00);
    }
    IOReturn latest = write_report(&opened, 0x82, keys, sizeof(keys), &result);
    if (latest != kIOReturnSuccess) {
        status = latest;
    }

    uint8_t buttons[25];
    memset(buttons, 0x7f, sizeof(buttons));
    latest = write_report(&opened, 0x80, buttons, sizeof(buttons), &result);
    if (latest != kIOReturnSuccess) {
        status = latest;
    }

    uint8_t display[248] = {0};
    display[4] = 0x48;
    display[6] = 0x01;
    memset(display + 8, 0xff, sizeof(display) - 8);
    latest = write_report(&opened, 0xe0, display, sizeof(display), &result);
    if (latest != kIOReturnSuccess) {
        status = latest;
    }

    result.status = status;
    close_kontrol(&opened);
    return result;
}

static void libusb_append(KontrolUSBResult *result, const char *label, int status) {
    result_append(result, "%s -> %d (%s); ", label, status, status < 0 ? libusb_error_name(status) : "OK");
}

static int libusb_async_status_to_error(int status) {
    if (status == LIBUSB_TRANSFER_COMPLETED || status == 0) {
        return 0;
    }
    if (status < 0) {
        return status;
    }
    switch (status) {
        case LIBUSB_TRANSFER_ERROR:
            return LIBUSB_ERROR_IO;
        case LIBUSB_TRANSFER_TIMED_OUT:
            return LIBUSB_ERROR_TIMEOUT;
        case LIBUSB_TRANSFER_CANCELLED:
            return LIBUSB_ERROR_INTERRUPTED;
        case LIBUSB_TRANSFER_STALL:
            return LIBUSB_ERROR_PIPE;
        case LIBUSB_TRANSFER_NO_DEVICE:
            return LIBUSB_ERROR_NO_DEVICE;
        case LIBUSB_TRANSFER_OVERFLOW:
            return LIBUSB_ERROR_OVERFLOW;
        default:
            return LIBUSB_ERROR_OTHER;
    }
}

static libusb_device_handle *libusb_open_known_device(libusb_context *ctx, uint16_t requestedProductID, const KontrolDeviceDescriptor **deviceOut, KontrolUSBResult *result) {
    if (deviceOut != NULL) {
        *deviceOut = NULL;
    }

    if (requestedProductID != 0) {
        const KontrolDeviceDescriptor *device = kontrol_device_for_product(requestedProductID);
        if (device == NULL) {
            result_append(result, "unsupported product 0x%04x; ", requestedProductID);
            return NULL;
        }
        libusb_device_handle *handle = libusb_open_device_with_vid_pid(ctx, KONTROL_VID, requestedProductID);
        if (handle != NULL && deviceOut != NULL) {
            *deviceOut = device;
        }
        return handle;
    }

    for (size_t i = 0; i < kKontrolDeviceCount; i++) {
        libusb_device_handle *handle = libusb_open_device_with_vid_pid(ctx, KONTROL_VID, kKontrolDevices[i].productID);
        if (handle != NULL) {
            if (deviceOut != NULL) {
                *deviceOut = &kKontrolDevices[i];
            }
            return handle;
        }
    }
    return NULL;
}

static int libusb_open_claim_device(uint16_t productID, libusb_context **ctxOut, libusb_device_handle **handleOut, const KontrolDeviceDescriptor **deviceOut, KontrolUSBResult *result) {
    *ctxOut = NULL;
    *handleOut = NULL;
    if (deviceOut != NULL) {
        *deviceOut = NULL;
    }

    int status = libusb_init(ctxOut);
    libusb_append(result, "libusb_init", status);
    if (status != 0) {
        result->status = status;
        return status;
    }

    libusb_set_option(*ctxOut, LIBUSB_OPTION_LOG_LEVEL, LIBUSB_LOG_LEVEL_NONE);

    const KontrolDeviceDescriptor *device = NULL;
    libusb_device_handle *handle = libusb_open_known_device(*ctxOut, productID, &device, result);
    if (handle == NULL) {
        if (productID != 0) {
            result_append(result, "open 0x%04x:0x%04x -> NULL; ", KONTROL_VID, productID);
        } else {
            result_append(result, "open known Native Instruments Kontrol device -> NULL; ");
        }
        result->status = LIBUSB_ERROR_NO_DEVICE;
        libusb_exit(*ctxOut);
        *ctxOut = NULL;
        return LIBUSB_ERROR_NO_DEVICE;
    }
    *handleOut = handle;
    if (deviceOut != NULL) {
        *deviceOut = device;
    }
    result->opened = 1;
    result->endpointAddress = device != NULL ? device->interruptOutputEndpointFallback : KONTROL_EP_OUT;
    result_append(result, "device=%s pid=0x%04x generation=mk%d claimInterface=%u; ",
                  device != NULL ? device->name : "unknown",
                  device != NULL ? device->productID : productID,
                  device != NULL ? device->generation : 0,
                  device != NULL ? device->claimInterface : KONTROL_INTERFACE);

    uint8_t claimInterface = device != NULL ? device->claimInterface : KONTROL_INTERFACE;
    status = libusb_kernel_driver_active(handle, claimInterface);
    result_append(result, "kernel_driver_active interface%u -> %d (%s); ",
                  claimInterface, status, status < 0 ? libusb_error_name(status) : "OK");

    status = libusb_detach_kernel_driver(handle, claimInterface);
    result_append(result, "detach_kernel_driver interface%u -> %d (%s); ",
                  claimInterface, status, status < 0 ? libusb_error_name(status) : "OK");
    if (status != 0 && status != LIBUSB_ERROR_NOT_FOUND && status != LIBUSB_ERROR_NOT_SUPPORTED) {
        if (status == LIBUSB_ERROR_ACCESS) {
            result_append(result, "requires root/admin privileges or com.apple.vm.device-access; ");
        }
        result->status = status;
        return status;
    }

    status = libusb_claim_interface(handle, claimInterface);
    result_append(result, "claim_interface %u -> %d (%s); ",
                  claimInterface, status, status < 0 ? libusb_error_name(status) : "OK");
    if (status != 0) {
        result->status = status;
        libusb_attach_kernel_driver(handle, claimInterface);
        return status;
    }

    result->pipeRef = 1;
    result->status = 0;
    return 0;
}

static int libusb_open_claim(libusb_context **ctxOut, libusb_device_handle **handleOut, KontrolUSBResult *result) {
    const KontrolDeviceDescriptor *device = NULL;
    return libusb_open_claim_device(KONTROL_PID, ctxOut, handleOut, &device, result);
}

static void libusb_find_transfer_endpoints(libusb_device_handle *handle, uint8_t interfaceNumber, uint8_t transferTypeFilter, uint8_t *inputOut, uint8_t *outputOut, KontrolUSBResult *result) {
    if (inputOut != NULL) {
        *inputOut = 0;
    }
    if (outputOut != NULL) {
        *outputOut = 0;
    }
    libusb_device *device = libusb_get_device(handle);
    if (device == NULL) {
        return;
    }

    struct libusb_config_descriptor *config = NULL;
    int status = libusb_get_active_config_descriptor(device, &config);
    if (status != 0 || config == NULL) {
        libusb_append(result, "get_active_config_descriptor", status);
        return;
    }

    for (uint8_t interfaceIndex = 0; interfaceIndex < config->bNumInterfaces; interfaceIndex++) {
        const struct libusb_interface *interface = &config->interface[interfaceIndex];
        for (int altIndex = 0; altIndex < interface->num_altsetting; altIndex++) {
            const struct libusb_interface_descriptor *alt = &interface->altsetting[altIndex];
            if (alt->bInterfaceNumber != interfaceNumber) {
                continue;
            }
            result_append(result, "interface%d alt%d endpoints=%u; ", alt->bInterfaceNumber, alt->bAlternateSetting, alt->bNumEndpoints);
            for (uint8_t endpointIndex = 0; endpointIndex < alt->bNumEndpoints; endpointIndex++) {
                const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[endpointIndex];
                uint8_t address = endpoint->bEndpointAddress;
                uint8_t transferType = endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;
                result_append(result, "ep0x%02x attr0x%02x max%u interval%u; ",
                              address, endpoint->bmAttributes, endpoint->wMaxPacketSize, endpoint->bInterval);
                if (transferType != transferTypeFilter) {
                    continue;
                }
                if ((address & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_IN && inputOut != NULL) {
                    *inputOut = address;
                } else if ((address & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_OUT && outputOut != NULL) {
                    *outputOut = address;
                }
            }
        }
    }

    libusb_free_config_descriptor(config);
    result_append(result, "selected in=0x%02x out=0x%02x; ",
                  inputOut != NULL ? *inputOut : 0,
                  outputOut != NULL ? *outputOut : 0);
}

static void libusb_find_interrupt_endpoints(libusb_device_handle *handle, const KontrolDeviceDescriptor *device, uint8_t *inputOut, uint8_t *outputOut, KontrolUSBResult *result) {
    uint8_t fallbackIn = device != NULL ? device->interruptInputEndpointFallback : KONTROL_EP_IN;
    uint8_t fallbackOut = device != NULL ? device->interruptOutputEndpointFallback : KONTROL_EP_OUT;
    uint8_t interfaceNumber = device != NULL ? device->claimInterface : KONTROL_INTERFACE;
    libusb_find_transfer_endpoints(handle, interfaceNumber, LIBUSB_TRANSFER_TYPE_INTERRUPT, inputOut, outputOut, result);
    if (inputOut != NULL && *inputOut == 0) {
        *inputOut = fallbackIn;
    }
    if (outputOut != NULL && *outputOut == 0) {
        *outputOut = fallbackOut;
    }
}

static void libusb_find_bulk_display_endpoint(libusb_device_handle *handle, const KontrolDeviceDescriptor *device, uint8_t *outputOut, KontrolUSBResult *result) {
    if (outputOut != NULL) {
        *outputOut = 0;
    }
    if (device == NULL || device->displayInterface == KONTROL_NO_INTERFACE) {
        result_append(result, "no display bulk interface for device; ");
        return;
    }
    uint8_t unusedInput = 0;
    libusb_find_transfer_endpoints(handle, device->displayInterface, LIBUSB_TRANSFER_TYPE_BULK, &unusedInput, outputOut, result);
    if (outputOut != NULL && *outputOut == 0) {
        *outputOut = device->displayOutputEndpointFallback;
    }
}

static void libusb_find_hid_surface_endpoints(libusb_device_handle *handle,
                                              uint8_t *interfaceOut,
                                              uint8_t *inputOut,
                                              uint8_t *outputOut,
                                              uint8_t *auxInterfaceOut,
                                              uint8_t *auxInputOut,
                                              KontrolUSBResult *result) {
    if (interfaceOut != NULL) {
        *interfaceOut = 0xff;
    }
    if (auxInterfaceOut != NULL) {
        *auxInterfaceOut = 0xff;
    }
    if (inputOut != NULL) {
        *inputOut = 0;
    }
    if (auxInputOut != NULL) {
        *auxInputOut = 0;
    }
    if (outputOut != NULL) {
        *outputOut = 0;
    }

    libusb_device *device = libusb_get_device(handle);
    if (device == NULL) {
        return;
    }

    struct libusb_config_descriptor *config = NULL;
    int status = libusb_get_active_config_descriptor(device, &config);
    if (status != 0 || config == NULL) {
        libusb_append(result, "get_active_config_descriptor hid", status);
        return;
    }

    uint8_t primaryInterface = 0xff;
    uint8_t primaryInput = 0;
    uint8_t primaryOutput = 0;
    uint8_t auxInterface = 0xff;
    uint8_t auxInput = 0;

    for (uint8_t interfaceIndex = 0; interfaceIndex < config->bNumInterfaces; interfaceIndex++) {
        const struct libusb_interface *interface = &config->interface[interfaceIndex];
        for (int altIndex = 0; altIndex < interface->num_altsetting; altIndex++) {
            const struct libusb_interface_descriptor *alt = &interface->altsetting[altIndex];
            result_append(result,
                          "cfg interface%d alt%d class=0x%02x sub=0x%02x proto=0x%02x endpoints=%u; ",
                          alt->bInterfaceNumber,
                          alt->bAlternateSetting,
                          alt->bInterfaceClass,
                          alt->bInterfaceSubClass,
                          alt->bInterfaceProtocol,
                          alt->bNumEndpoints);
            if (alt->bInterfaceClass != LIBUSB_CLASS_HID) {
                continue;
            }

            uint8_t firstInput = 0;
            uint8_t secondInput = 0;
            uint8_t selectedOutput = 0;
            for (uint8_t endpointIndex = 0; endpointIndex < alt->bNumEndpoints; endpointIndex++) {
                const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[endpointIndex];
                uint8_t address = endpoint->bEndpointAddress;
                uint8_t transferType = endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;
                result_append(result,
                              "hid ep0x%02x attr0x%02x max%u interval%u; ",
                              address,
                              endpoint->bmAttributes,
                              endpoint->wMaxPacketSize,
                              endpoint->bInterval);
                if (transferType != LIBUSB_TRANSFER_TYPE_INTERRUPT) {
                    continue;
                }
                if ((address & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_IN) {
                    if (firstInput == 0) {
                        firstInput = address;
                    } else if (secondInput == 0) {
                        secondInput = address;
                    }
                } else {
                    selectedOutput = address;
                }
            }

            if (firstInput != 0 && primaryInput == 0) {
                primaryInterface = alt->bInterfaceNumber;
                primaryInput = firstInput;
                primaryOutput = selectedOutput;
            } else if (firstInput != 0 && auxInput == 0) {
                auxInterface = alt->bInterfaceNumber;
                auxInput = firstInput;
            }
            if (secondInput != 0 && auxInput == 0) {
                auxInterface = alt->bInterfaceNumber;
                auxInput = secondInput;
            }
        }
    }

    libusb_free_config_descriptor(config);
    if (primaryInput == 0) {
        result_append(result, "no HID interrupt-IN surface endpoint; ");
        return;
    }

    if (interfaceOut != NULL) {
        *interfaceOut = primaryInterface;
    }
    if (inputOut != NULL) {
        *inputOut = primaryInput;
    }
    if (outputOut != NULL) {
        *outputOut = primaryOutput;
    }
    if (auxInterfaceOut != NULL) {
        *auxInterfaceOut = auxInterface;
    }
    if (auxInputOut != NULL) {
        *auxInputOut = auxInput;
    }
    result_append(result,
                  "selected hid primary interface=%u in=0x%02x out=0x%02x; ",
                  primaryInterface,
                  primaryInput,
                  primaryOutput);
    if (auxInput != 0) {
        result_append(result, "selected hid aux interface=%u in=0x%02x; ", auxInterface, auxInput);
    }
}

static int libusb_claim_interface_detaching(libusb_device_handle *handle, uint8_t interfaceNumber, const char *label, KontrolUSBResult *result) {
    int status = libusb_kernel_driver_active(handle, interfaceNumber);
    result_append(result, "kernel_driver_active %s%u -> %d (%s); ",
                  label, interfaceNumber, status, status < 0 ? libusb_error_name(status) : "OK");

    status = libusb_detach_kernel_driver(handle, interfaceNumber);
    result_append(result, "detach_kernel_driver %s%u -> %d (%s); ",
                  label, interfaceNumber, status, status < 0 ? libusb_error_name(status) : "OK");
    if (status != 0 && status != LIBUSB_ERROR_NOT_FOUND && status != LIBUSB_ERROR_NOT_SUPPORTED) {
        return status;
    }

    status = libusb_claim_interface(handle, interfaceNumber);
    result_append(result, "claim_interface %s%u -> %d (%s); ",
                  label, interfaceNumber, status, status < 0 ? libusb_error_name(status) : "OK");
    return status;
}

static int libusb_claim_hid_surface(KontrolLibUSBSession *session, KontrolUSBResult *result) {
    session->surfaceInterface = 0xff;
    session->surfaceClaimed = 0;
    session->auxSurfaceInterface = 0xff;
    session->auxSurfaceClaimed = 0;
    session->inputEndpoint = 0;
    session->auxInputEndpoint = 0;
    session->outputEndpoint = 0;

    libusb_find_hid_surface_endpoints(
        session->handle,
        &session->surfaceInterface,
        &session->inputEndpoint,
        &session->outputEndpoint,
        &session->auxSurfaceInterface,
        &session->auxInputEndpoint,
        result
    );
    if (session->surfaceInterface == 0xff || session->inputEndpoint == 0) {
        return LIBUSB_ERROR_NOT_FOUND;
    }

    int status = 0;
    if (session->surfaceInterface == session->claimedInterface) {
        session->surfaceClaimed = 1;
    } else {
        status = libusb_claim_interface_detaching(session->handle, session->surfaceInterface, "surface", result);
        if (status == 0) {
            session->surfaceClaimed = 1;
        } else {
            return status;
        }
    }

    if (session->auxInputEndpoint != 0 && session->auxSurfaceInterface != 0xff) {
        if (session->auxSurfaceInterface == session->claimedInterface || session->auxSurfaceInterface == session->surfaceInterface) {
            session->auxSurfaceClaimed = 1;
        } else {
            status = libusb_claim_interface_detaching(session->handle, session->auxSurfaceInterface, "surfaceAux", result);
            if (status == 0) {
                session->auxSurfaceClaimed = 1;
            } else {
                result_append(result, "MK2 aux HID claim unavailable status=%d (%s); ",
                              status,
                              status < 0 ? libusb_error_name(status) : "OK");
                session->auxInputEndpoint = 0;
            }
        }
    }
    return 0;
}

static void libusb_find_midi_streaming_endpoint(libusb_device_handle *handle, uint8_t *interfaceOut, uint8_t *inputOut, KontrolUSBResult *result) {
    if (interfaceOut != NULL) {
        *interfaceOut = 0xff;
    }
    if (inputOut != NULL) {
        *inputOut = 0;
    }

    libusb_device *device = libusb_get_device(handle);
    if (device == NULL) {
        return;
    }

    struct libusb_config_descriptor *config = NULL;
    int status = libusb_get_active_config_descriptor(device, &config);
    if (status != 0 || config == NULL) {
        libusb_append(result, "get_active_config_descriptor midi", status);
        return;
    }

    for (uint8_t interfaceIndex = 0; interfaceIndex < config->bNumInterfaces; interfaceIndex++) {
        const struct libusb_interface *interface = &config->interface[interfaceIndex];
        for (int altIndex = 0; altIndex < interface->num_altsetting; altIndex++) {
            const struct libusb_interface_descriptor *alt = &interface->altsetting[altIndex];
            if (alt->bInterfaceClass != LIBUSB_CLASS_AUDIO || alt->bInterfaceSubClass != 3) {
                continue;
            }
            result_append(result, "midi interface%d alt%d endpoints=%u; ", alt->bInterfaceNumber, alt->bAlternateSetting, alt->bNumEndpoints);
            for (uint8_t endpointIndex = 0; endpointIndex < alt->bNumEndpoints; endpointIndex++) {
                const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[endpointIndex];
                uint8_t address = endpoint->bEndpointAddress;
                uint8_t transferType = endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;
                result_append(result, "midi ep0x%02x attr0x%02x max%u interval%u; ",
                              address, endpoint->bmAttributes, endpoint->wMaxPacketSize, endpoint->bInterval);
                if ((address & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_IN
                    && (transferType == LIBUSB_TRANSFER_TYPE_BULK || transferType == LIBUSB_TRANSFER_TYPE_INTERRUPT)) {
                    uint8_t selectedInterface = alt->bInterfaceNumber;
                    uint8_t selectedInput = address;
                    if (interfaceOut != NULL) {
                        *interfaceOut = selectedInterface;
                    }
                    if (inputOut != NULL) {
                        *inputOut = selectedInput;
                    }
                    libusb_free_config_descriptor(config);
                    result_append(result, "selected midi interface=%u in=0x%02x; ", selectedInterface, selectedInput);
                    return;
                }
            }
        }
    }

    libusb_free_config_descriptor(config);
    result_append(result, "no USB-MIDI streaming IN endpoint; ");
}

static int libusb_claim_midi_streaming(KontrolLibUSBSession *session, KontrolUSBResult *result) {
    session->midiInterface = 0xff;
    session->midiInputEndpoint = 0;
    session->midiClaimed = 0;

    libusb_find_midi_streaming_endpoint(session->handle, &session->midiInterface, &session->midiInputEndpoint, result);
    if (session->midiInterface == 0xff || session->midiInputEndpoint == 0) {
        return LIBUSB_ERROR_NOT_FOUND;
    }

    int status = libusb_kernel_driver_active(session->handle, session->midiInterface);
    libusb_append(result, "kernel_driver_active midi", status);

    status = libusb_detach_kernel_driver(session->handle, session->midiInterface);
    libusb_append(result, "detach_kernel_driver midi", status);
    if (status != 0 && status != LIBUSB_ERROR_NOT_FOUND && status != LIBUSB_ERROR_NOT_SUPPORTED) {
        return status;
    }

    status = libusb_claim_interface(session->handle, session->midiInterface);
    libusb_append(result, "claim_interface midi", status);
    if (status == 0) {
        session->midiClaimed = 1;
    }
    return status;
}

static int libusb_write_report(libusb_device_handle *handle, uint8_t endpoint, uint8_t reportID, const uint8_t *payload, uint32_t payloadLen, KontrolUSBResult *result) {
    uint8_t buffer[256] = {0};
    uint32_t totalLen = payloadLen + 1;
    if (totalLen > sizeof(buffer)) {
        result_append(result, "report 0x%02x too large (%u bytes); ", reportID, totalLen);
        return LIBUSB_ERROR_OVERFLOW;
    }
    if (endpoint == 0) {
        result_append(result, "no interrupt-OUT endpoint discovered; ");
        return LIBUSB_ERROR_NOT_FOUND;
    }

    buffer[0] = reportID;
    if (payloadLen > 0 && payload != NULL) {
        memcpy(buffer + 1, payload, payloadLen);
    }

    int transferred = 0;
    int status = libusb_interrupt_transfer(handle, endpoint, buffer, (int)totalLen, &transferred, 50);
    result_append(result, "interrupt_transfer ep0x%02x report0x%02x len%u -> %d (%s) transferred=%d; ",
                  endpoint, reportID, totalLen, status, status < 0 ? libusb_error_name(status) : "OK", transferred);
    return status;
}

static int libusb_write_hid_report_control(libusb_device_handle *handle, uint8_t interfaceNumber, uint8_t reportID, const uint8_t *payload, uint32_t payloadLen, KontrolUSBResult *result) {
    uint8_t buffer[512] = {0};
    uint32_t totalLen = payloadLen + 1;
    if (totalLen > sizeof(buffer)) {
        result_append(result, "control report 0x%02x too large (%u bytes); ", reportID, totalLen);
        return LIBUSB_ERROR_OVERFLOW;
    }

    buffer[0] = reportID;
    if (payloadLen > 0 && payload != NULL) {
        memcpy(buffer + 1, payload, payloadLen);
    }

    int status = libusb_control_transfer(
        handle,
        LIBUSB_REQUEST_TYPE_CLASS | LIBUSB_RECIPIENT_INTERFACE | LIBUSB_ENDPOINT_OUT,
        0x09,
        (uint16_t)((2 << 8) | reportID),
        interfaceNumber,
        buffer,
        (uint16_t)totalLen,
        100
    );
    result_append(result,
                  "hid control SET_REPORT interface%u report0x%02x len%u -> %d (%s); ",
                  interfaceNumber,
                  reportID,
                  totalLen,
                  status,
                  status < 0 ? libusb_error_name(status) : "OK");
    return status < 0 ? status : 0;
}

static void libusb_close_claim_interface(libusb_context *ctx, libusb_device_handle *handle, uint8_t interfaceNumber, KontrolUSBResult *result) {
    if (handle != NULL) {
        if (result->pipeRef != 0) {
            libusb_release_interface(handle, interfaceNumber);
            int status = libusb_attach_kernel_driver(handle, interfaceNumber);
            result_append(result, "attach_kernel_driver interface%u -> %d (%s); ",
                          interfaceNumber, status, status < 0 ? libusb_error_name(status) : "OK");
        }
        libusb_close(handle);
    }
    if (ctx != NULL) {
        libusb_exit(ctx);
    }
}

static void libusb_close_claim(libusb_context *ctx, libusb_device_handle *handle, KontrolUSBResult *result) {
    libusb_close_claim_interface(ctx, handle, KONTROL_INTERFACE, result);
}

KontrolUSBResult KontrolUSBLibUSBWriteReport(uint8_t reportID, const uint8_t *payload, uint32_t payloadLen) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = LIBUSB_ERROR_OTHER;

    libusb_context *ctx = NULL;
    libusb_device_handle *handle = NULL;
    int status = libusb_open_claim(&ctx, &handle, &result);
    if (status == 0) {
        uint8_t inputEndpoint = 0;
        uint8_t outputEndpoint = 0;
        libusb_find_interrupt_endpoints(handle, kontrol_device_for_product(KONTROL_PID), &inputEndpoint, &outputEndpoint, &result);
        result.endpointAddress = outputEndpoint;
        status = libusb_write_report(handle, outputEndpoint, reportID, payload, payloadLen, &result);
        result.status = status;
    }
    libusb_close_claim(ctx, handle, &result);

    return result;
}

KontrolUSBResult KontrolUSBLibUSBSessionOpenForProduct(uint16_t productID, KontrolUSBLibUSBSessionRef *sessionOut) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = LIBUSB_ERROR_OTHER;
    if (sessionOut == NULL) {
        result.status = LIBUSB_ERROR_INVALID_PARAM;
        return result;
    }
    *sessionOut = NULL;

    KontrolLibUSBSession *session = calloc(1, sizeof(KontrolLibUSBSession));
    if (session == NULL) {
        result.status = LIBUSB_ERROR_NO_MEM;
        return result;
    }

    const KontrolDeviceDescriptor *device = NULL;
    int status = libusb_open_claim_device(productID, &session->ctx, &session->handle, &device, &result);
    if (status != 0) {
        if (session->handle != NULL || session->ctx != NULL) {
            libusb_close_claim(session->ctx, session->handle, &result);
        }
        free(session);
        result.status = status;
        return result;
    }

    session->device = device;
    session->claimedInterface = device != NULL ? device->claimInterface : KONTROL_INTERFACE;
    session->surfaceInterface = 0xff;
    session->surfaceClaimed = 0;
    session->auxSurfaceInterface = 0xff;
    session->auxSurfaceClaimed = 0;
    session->auxInputEndpoint = 0;
    session->displayInterface = device != NULL ? device->displayInterface : KONTROL_NO_INTERFACE;
    session->displayOutputEndpoint = 0;

    if (device == NULL || device->generation == KONTROL_DEVICE_MK1) {
        libusb_find_interrupt_endpoints(session->handle, device, &session->inputEndpoint, &session->outputEndpoint, &result);
    } else {
        libusb_find_bulk_display_endpoint(session->handle, device, &session->displayOutputEndpoint, &result);
        int surfaceStatus = libusb_claim_hid_surface(session, &result);
        if (surfaceStatus != 0) {
            result_append(&result, "MK2 HID surface claim unavailable status=%d (%s); ",
                          surfaceStatus,
                          surfaceStatus < 0 ? libusb_error_name(surfaceStatus) : "OK");
        }
    }
    int midiStatus = libusb_claim_midi_streaming(session, &result);
    if (midiStatus != 0 && midiStatus != LIBUSB_ERROR_NOT_FOUND) {
        result_append(&result, "USB-MIDI claim unavailable status=%d (%s); ",
                      midiStatus,
                      midiStatus < 0 ? libusb_error_name(midiStatus) : "OK");
    }
    result.endpointAddress = session->outputEndpoint != 0 ? session->outputEndpoint : session->displayOutputEndpoint;
    *sessionOut = session;
    result.status = 0;
    return result;
}

KontrolUSBResult KontrolUSBLibUSBSessionOpen(KontrolUSBLibUSBSessionRef *sessionOut) {
    return KontrolUSBLibUSBSessionOpenForProduct(0, sessionOut);
}

uint8_t KontrolUSBLibUSBSessionGeneration(KontrolUSBLibUSBSessionRef sessionRef) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->device == NULL) {
        return 0;
    }
    return (uint8_t)session->device->generation;
}

uint16_t KontrolUSBLibUSBSessionProductID(KontrolUSBLibUSBSessionRef sessionRef) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->device == NULL) {
        return 0;
    }
    return session->device->productID;
}

uint8_t KontrolUSBLibUSBSessionKeyCount(KontrolUSBLibUSBSessionRef sessionRef) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->device == NULL) {
        return 0;
    }
    return session->device->keyCount;
}

KontrolUSBResult KontrolUSBLibUSBSessionStatus(KontrolUSBLibUSBSessionRef sessionRef) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = LIBUSB_ERROR_INVALID_PARAM;
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->handle == NULL) {
        return result;
    }
    result.status = 0;
    result.opened = 1;
    result.pipeRef = 1;
    result.endpointAddress = session->outputEndpoint != 0 ? session->outputEndpoint : session->displayOutputEndpoint;
    result_append(&result, "session device=%s pid=0x%04x generation=mk%d claimedInterface=%u surfaceInterface=%u surfaceClaimed=%u auxSurfaceInterface=%u auxSurfaceClaimed=%u endpoints in=0x%02x auxIn=0x%02x out=0x%02x displayInterface=%u displayOut=0x%02x midiInterface=%u midiIn=0x%02x midiClaimed=%u; ",
                  session->device != NULL ? session->device->name : "unknown",
                  session->device != NULL ? session->device->productID : 0,
                  session->device != NULL ? session->device->generation : 0,
                  session->claimedInterface,
                  session->surfaceInterface,
                  session->surfaceClaimed,
                  session->auxSurfaceInterface,
                  session->auxSurfaceClaimed,
                  session->inputEndpoint,
                  session->auxInputEndpoint,
                  session->outputEndpoint,
                  session->displayInterface,
                  session->displayOutputEndpoint,
                  session->midiInterface,
                  session->midiInputEndpoint,
                  session->midiClaimed);
    return result;
}

KontrolUSBResult KontrolUSBLibUSBSessionHealth(KontrolUSBLibUSBSessionRef sessionRef) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = LIBUSB_ERROR_INVALID_PARAM;
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->handle == NULL) {
        result_append(&result, "session unavailable; ");
        return result;
    }

    result.opened = 1;
    result.pipeRef = 1;
    result.endpointAddress = session->outputEndpoint != 0 ? session->outputEndpoint : session->displayOutputEndpoint;

    int inputError = libusb_async_status_to_error(session->inputTransferStatus);
    if (inputError != 0) {
        result.status = inputError;
        result_append(&result, "async input transfer status=%d; ", session->inputTransferStatus);
        return result;
    }

    int auxInputError = libusb_async_status_to_error(session->auxInputTransferStatus);
    if (auxInputError != 0) {
        result.status = auxInputError;
        result_append(&result, "async aux input transfer status=%d; ", session->auxInputTransferStatus);
        return result;
    }

    int midiError = libusb_async_status_to_error(session->midiTransferStatus);
    if (midiError != 0) {
        result.status = midiError;
        result_append(&result, "async midi transfer status=%d; ", session->midiTransferStatus);
        return result;
    }

    int configuration = 0;
    int status = libusb_get_configuration(session->handle, &configuration);
    libusb_append(&result, "get_configuration", status);
    if (status != 0) {
        result.status = status;
        return result;
    }

    status = libusb_kernel_driver_active(session->handle, session->claimedInterface);
    result_append(&result, "kernel_driver_active interface%u health -> %d (%s); ",
                  session->claimedInterface, status, status < 0 ? libusb_error_name(status) : "OK");
    if (status < 0 && status != LIBUSB_ERROR_NOT_SUPPORTED) {
        result.status = status;
        return result;
    }
    if (status == 1) {
        result.status = LIBUSB_ERROR_BUSY;
        result_append(&result, "kernel driver owns interface%u; ", session->claimedInterface);
        return result;
    }

    result.status = 0;
    result_append(&result, "configuration=%d; ", configuration);
    return result;
}

KontrolUSBResult KontrolUSBLibUSBSessionWrite(KontrolUSBLibUSBSessionRef sessionRef, uint8_t reportID, const uint8_t *payload, uint32_t payloadLen) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = LIBUSB_ERROR_INVALID_PARAM;
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->handle == NULL) {
        return result;
    }
    result.opened = 1;
    result.pipeRef = 1;
    result.endpointAddress = session->outputEndpoint != 0 ? session->outputEndpoint : KONTROL_EP_OUT;
    int status = 0;
    if (session->outputEndpoint != 0) {
        status = libusb_write_report(session->handle, session->outputEndpoint, reportID, payload, payloadLen, &result);
    } else if (session->device != NULL && session->device->generation == KONTROL_DEVICE_MK2 && session->surfaceClaimed && session->surfaceInterface != 0xff) {
        result.endpointAddress = 0;
        status = libusb_write_hid_report_control(session->handle, session->surfaceInterface, reportID, payload, payloadLen, &result);
    } else {
        result_append(&result, "no interrupt-OUT endpoint or HID control surface discovered; ");
        status = LIBUSB_ERROR_NOT_FOUND;
    }
    result.status = status;
    return result;
}

static void put_be16(uint8_t *buffer, size_t *offset, uint16_t value) {
    buffer[*offset] = (uint8_t)((value >> 8) & 0xff);
    buffer[*offset + 1] = (uint8_t)(value & 0xff);
    *offset += 2;
}

KontrolUSBResult KontrolUSBLibUSBSessionWriteMK2Display(KontrolUSBLibUSBSessionRef sessionRef,
                                                        uint8_t screen,
                                                        uint16_t x,
                                                        uint16_t y,
                                                        uint16_t width,
                                                        uint16_t height,
                                                        const uint16_t *pixelsRGB565,
                                                        uint32_t pixelCount,
                                                        uint32_t timeoutMs) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = LIBUSB_ERROR_INVALID_PARAM;
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->handle == NULL || pixelsRGB565 == NULL) {
        return result;
    }
    result.opened = 1;
    result.pipeRef = 1;
    result.endpointAddress = session->displayOutputEndpoint;

    if (session->device == NULL || session->device->generation != KONTROL_DEVICE_MK2) {
        result_append(&result, "session is not an MK2 display device; ");
        result.status = LIBUSB_ERROR_NOT_SUPPORTED;
        return result;
    }
    if (session->displayOutputEndpoint == 0) {
        result_append(&result, "no MK2 bulk display endpoint discovered; ");
        result.status = LIBUSB_ERROR_NOT_FOUND;
        return result;
    }
    if (screen > 1 || width == 0 || height == 0 || x > 479 || y > 271 || (uint32_t)x + (uint32_t)width > 480 || (uint32_t)y + (uint32_t)height > 272) {
        result_append(&result, "invalid display rect screen=%u x=%u y=%u w=%u h=%u; ", screen, x, y, width, height);
        result.status = LIBUSB_ERROR_INVALID_PARAM;
        return result;
    }
    uint32_t expectedPixels = (uint32_t)width * (uint32_t)height;
    if (expectedPixels != pixelCount) {
        result_append(&result, "pixel count mismatch expected=%u actual=%u; ", expectedPixels, pixelCount);
        result.status = LIBUSB_ERROR_INVALID_PARAM;
        return result;
    }
    if ((pixelCount % 2) != 0) {
        result_append(&result, "MK2 display protocol requires an even pixel count pixels=%u; ", pixelCount);
        result.status = LIBUSB_ERROR_INVALID_PARAM;
        return result;
    }
    if ((pixelCount / 2) > 0xffff) {
        result_append(&result, "rect too large for MK2 count field pixels=%u; ", pixelCount);
        result.status = LIBUSB_ERROR_OVERFLOW;
        return result;
    }

    const size_t headerLen = 24;
    const size_t trailerLen = 12;
    size_t totalLen = headerLen + ((size_t)pixelCount * 2) + trailerLen;
    uint8_t *buffer = malloc(totalLen);
    if (buffer == NULL) {
        result.status = LIBUSB_ERROR_NO_MEM;
        return result;
    }

    size_t offset = 0;
    buffer[offset++] = 0x84;
    buffer[offset++] = 0x00;
    buffer[offset++] = screen;
    buffer[offset++] = 0x60;
    buffer[offset++] = 0x00;
    buffer[offset++] = 0x00;
    buffer[offset++] = 0x00;
    buffer[offset++] = 0x00;
    put_be16(buffer, &offset, x);
    put_be16(buffer, &offset, y);
    put_be16(buffer, &offset, width);
    put_be16(buffer, &offset, height);
    buffer[offset++] = 0x02;
    buffer[offset++] = 0x00;
    buffer[offset++] = 0x00;
    buffer[offset++] = 0x00;
    buffer[offset++] = 0x00;
    buffer[offset++] = 0x00;
    put_be16(buffer, &offset, (uint16_t)(pixelCount / 2));

    for (uint32_t i = 0; i < pixelCount; i++) {
        put_be16(buffer, &offset, pixelsRGB565[i]);
    }

    const uint8_t trailer[] = {0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00};
    memcpy(buffer + offset, trailer, sizeof(trailer));
    offset += sizeof(trailer);

    int transferred = 0;
    uint32_t timeout = timeoutMs == 0 ? 1000 : timeoutMs;
    int status = libusb_bulk_transfer(session->handle, session->displayOutputEndpoint, buffer, (int)offset, &transferred, timeout);
    result_append(&result, "mk2 bulk_transfer ep0x%02x screen=%u rect=%u,%u %ux%u bytes=%zu -> %d (%s) transferred=%d; ",
                  session->displayOutputEndpoint,
                  screen,
                  x,
                  y,
                  width,
                  height,
                  offset,
                  status,
                  status < 0 ? libusb_error_name(status) : "OK",
                  transferred);
    result.status = status;
    free(buffer);
    return result;
}

KontrolUSBResult KontrolUSBLibUSBSessionFillMK2Display(KontrolUSBLibUSBSessionRef sessionRef,
                                                       uint8_t screen,
                                                       uint16_t x,
                                                       uint16_t y,
                                                       uint16_t width,
                                                       uint16_t height,
                                                       uint16_t rgb565,
                                                       uint32_t timeoutMs) {
    uint32_t pixelCount = (uint32_t)width * (uint32_t)height;
    uint16_t *pixels = malloc((size_t)pixelCount * sizeof(uint16_t));
    if (pixels == NULL) {
        KontrolUSBResult result;
        memset(&result, 0, sizeof(result));
        result.status = LIBUSB_ERROR_NO_MEM;
        return result;
    }
    for (uint32_t i = 0; i < pixelCount; i++) {
        pixels[i] = rgb565;
    }
    KontrolUSBResult result = KontrolUSBLibUSBSessionWriteMK2Display(sessionRef, screen, x, y, width, height, pixels, pixelCount, timeoutMs);
    free(pixels);
    return result;
}

KontrolUSBResult KontrolUSBLibUSBSessionRead(KontrolUSBLibUSBSessionRef sessionRef, uint8_t *buffer, uint32_t bufferLen, uint32_t *transferredOut, uint32_t timeoutMs) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = LIBUSB_ERROR_INVALID_PARAM;
    if (transferredOut != NULL) {
        *transferredOut = 0;
    }
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->handle == NULL || buffer == NULL || bufferLen == 0) {
        return result;
    }
    result.opened = 1;
    result.pipeRef = 1;
    uint8_t endpoint = session->inputEndpoint;
    result.endpointAddress = endpoint;
    if (endpoint == 0) {
        result_append(&result, "no interrupt-IN endpoint discovered; ");
        result.status = LIBUSB_ERROR_NOT_FOUND;
        return result;
    }

    int transferred = 0;
    int status = libusb_interrupt_transfer(session->handle, endpoint, buffer, (int)bufferLen, &transferred, timeoutMs);
    result_append(&result, "interrupt_transfer ep0x%02x len%u -> %d (%s) transferred=%d; ",
                  endpoint, bufferLen, status, status < 0 ? libusb_error_name(status) : "OK", transferred);
    if (transferredOut != NULL) {
        *transferredOut = transferred > 0 ? (uint32_t)transferred : 0;
    }
    result.status = status;
    return result;
}

KontrolUSBResult KontrolUSBLibUSBSessionReadMIDI(KontrolUSBLibUSBSessionRef sessionRef, uint8_t *buffer, uint32_t bufferLen, uint32_t *transferredOut, uint32_t timeoutMs) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = LIBUSB_ERROR_INVALID_PARAM;
    if (transferredOut != NULL) {
        *transferredOut = 0;
    }
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->handle == NULL || buffer == NULL || bufferLen == 0) {
        return result;
    }
    result.opened = 1;
    result.pipeRef = 1;
    result.endpointAddress = session->midiInputEndpoint;
    if (!session->midiClaimed || session->midiInputEndpoint == 0) {
        result_append(&result, "no claimed USB-MIDI IN endpoint; ");
        result.status = LIBUSB_ERROR_NOT_FOUND;
        return result;
    }

    int transferred = 0;
    int status = libusb_bulk_transfer(session->handle, session->midiInputEndpoint, buffer, (int)bufferLen, &transferred, timeoutMs);
    result_append(&result, "midi bulk_transfer ep0x%02x len%u -> %d (%s) transferred=%d; ",
                  session->midiInputEndpoint, bufferLen, status, status < 0 ? libusb_error_name(status) : "OK", transferred);
    if (transferredOut != NULL) {
        *transferredOut = transferred > 0 ? (uint32_t)transferred : 0;
    }
    result.status = status;
    return result;
}

void KontrolUSBLibUSBSessionClose(KontrolUSBLibUSBSessionRef sessionRef) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL) {
        return;
    }
    KontrolUSBLibUSBSessionStopAsync(sessionRef);
    if (session->inputTransfer != NULL) {
        libusb_free_transfer(session->inputTransfer);
        session->inputTransfer = NULL;
    }
    if (session->auxInputTransfer != NULL) {
        libusb_free_transfer(session->auxInputTransfer);
        session->auxInputTransfer = NULL;
    }
    if (session->midiTransfer != NULL) {
        libusb_free_transfer(session->midiTransfer);
        session->midiTransfer = NULL;
    }
    if (session->handle != NULL && session->midiClaimed) {
        libusb_release_interface(session->handle, session->midiInterface);
        libusb_attach_kernel_driver(session->handle, session->midiInterface);
        session->midiClaimed = 0;
    }
    if (session->handle != NULL && session->surfaceClaimed && session->surfaceInterface != session->claimedInterface) {
        libusb_release_interface(session->handle, session->surfaceInterface);
        libusb_attach_kernel_driver(session->handle, session->surfaceInterface);
        session->surfaceClaimed = 0;
    }
    if (session->handle != NULL
        && session->auxSurfaceClaimed
        && session->auxSurfaceInterface != session->claimedInterface
        && session->auxSurfaceInterface != session->surfaceInterface) {
        libusb_release_interface(session->handle, session->auxSurfaceInterface);
        libusb_attach_kernel_driver(session->handle, session->auxSurfaceInterface);
        session->auxSurfaceClaimed = 0;
    }
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.pipeRef = session->handle != NULL ? 1 : 0;
    libusb_close_claim_interface(session->ctx, session->handle, session->claimedInterface, &result);
    free(session);
}

KontrolUSBResult KontrolUSBLibUSBRunDemo(void) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = LIBUSB_ERROR_OTHER;

    libusb_context *ctx = NULL;
    libusb_device_handle *handle = NULL;
    int status = libusb_open_claim(&ctx, &handle, &result);
    if (status != 0) {
        libusb_close_claim(ctx, handle, &result);
        return result;
    }

    const uint8_t init[] = {0x00, 0x00};
    status = libusb_write_report(handle, KONTROL_EP_OUT, 0xa0, init, sizeof(init), &result);
    usleep(60000);

    uint8_t keys[75] = {0};
    for (int i = 0; i < 25; i++) {
        int lane = i % 6;
        keys[i * 3 + 0] = (uint8_t)((lane == 0 || lane == 1) ? 0x7f : 0x00);
        keys[i * 3 + 1] = (uint8_t)((lane == 2 || lane == 3) ? 0x7f : 0x00);
        keys[i * 3 + 2] = (uint8_t)((lane == 4 || lane == 5) ? 0x7f : 0x00);
    }
    int latest = libusb_write_report(handle, KONTROL_EP_OUT, 0x82, keys, sizeof(keys), &result);
    if (latest != 0) {
        status = latest;
    }

    uint8_t buttons[25];
    memset(buttons, 0x7f, sizeof(buttons));
    latest = libusb_write_report(handle, KONTROL_EP_OUT, 0x80, buttons, sizeof(buttons), &result);
    if (latest != 0) {
        status = latest;
    }

    result.status = status;
    libusb_close_claim(ctx, handle, &result);
    return result;
}

KontrolUSBResult KontrolUSBLibUSBRunHoldDemo(uint32_t steps, uint32_t intervalUsec) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = LIBUSB_ERROR_OTHER;

    libusb_context *ctx = NULL;
    libusb_device_handle *handle = NULL;
    int status = libusb_open_claim(&ctx, &handle, &result);
    if (status != 0) {
        libusb_close_claim(ctx, handle, &result);
        return result;
    }

    const uint8_t init[] = {0x00, 0x00};
    status = libusb_write_report(handle, KONTROL_EP_OUT, 0xa0, init, sizeof(init), &result);

    uint8_t buttons[25];
    memset(buttons, 0x7f, sizeof(buttons));
    int latest = libusb_write_report(handle, KONTROL_EP_OUT, 0x80, buttons, sizeof(buttons), &result);
    if (latest != 0) {
        status = latest;
    }

    uint8_t keys[75] = {0};
    uint32_t count = steps == 0 ? 8 : steps;
    uint32_t delay = intervalUsec == 0 ? 250000 : intervalUsec;
    for (uint32_t phase = 0; phase < count; phase++) {
        memset(keys, 0, sizeof(keys));
        for (int i = 0; i < 25; i++) {
            int lane = (i + (int)phase) % 6;
            keys[i * 3 + 0] = (uint8_t)((lane == 0 || lane == 1) ? 0x7f : 0x00);
            keys[i * 3 + 1] = (uint8_t)((lane == 2 || lane == 3) ? 0x7f : 0x00);
            keys[i * 3 + 2] = (uint8_t)((lane == 4 || lane == 5) ? 0x7f : 0x00);
        }
        latest = libusb_write_report(handle, KONTROL_EP_OUT, 0x82, keys, sizeof(keys), &result);
        if (latest != 0) {
            status = latest;
        }
        usleep(delay);
    }

    memset(keys, 0, sizeof(keys));
    latest = libusb_write_report(handle, KONTROL_EP_OUT, 0x82, keys, sizeof(keys), &result);
    if (latest != 0) {
        status = latest;
    }
    memset(buttons, 0, sizeof(buttons));
    latest = libusb_write_report(handle, KONTROL_EP_OUT, 0x80, buttons, sizeof(buttons), &result);
    if (latest != 0) {
        status = latest;
    }

    result.status = status;
    libusb_close_claim(ctx, handle, &result);
    return result;
}

/* ---- Async API implementation ---- */

static void input_transfer_callback(struct libusb_transfer *transfer) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)transfer->user_data;
    if (session == NULL) return;
    int isAux = session->auxInputTransfer == transfer;
    if (isAux) {
        session->auxInputTransferStatus = transfer->status;
    } else {
        session->inputTransferStatus = transfer->status;
    }

#ifdef KK_DEBUG
    char head[96];
    kk_usb_debug_head(head, sizeof(head), transfer->buffer, transfer->actual_length);
    kk_usb_debug_log("usb-surface",
                     transfer->status == LIBUSB_TRANSFER_COMPLETED ? "INFO" : "ERROR",
                     "callback status=%d actual=%d endpoint=0x%02x head=%s",
                     transfer->status,
                     transfer->actual_length,
                     transfer->endpoint,
                     head);
#endif

    if (transfer->status == LIBUSB_TRANSFER_COMPLETED) {
        if (session->inputCallback) {
            session->inputCallback(transfer->buffer, transfer->actual_length, session->inputUserData);
        }
    }

    if (transfer->status == LIBUSB_TRANSFER_COMPLETED
        && (session->inputTransfer == transfer || session->auxInputTransfer == transfer)
        && !session->closing) {
        int submitStatus = libusb_submit_transfer(transfer);
        if (isAux) {
            session->auxInputTransferStatus = submitStatus == 0 ? LIBUSB_TRANSFER_COMPLETED : submitStatus;
            session->auxInputTransferPending = submitStatus == 0;
        } else {
            session->inputTransferStatus = submitStatus == 0 ? LIBUSB_TRANSFER_COMPLETED : submitStatus;
            session->inputTransferPending = submitStatus == 0;
        }
        kk_usb_debug_log("usb-surface",
                         submitStatus == 0 ? "TRACE" : "ERROR",
                         "resubmit endpoint=0x%02x status=%d",
                         transfer->endpoint,
                         submitStatus);
    } else if (session->inputTransfer == transfer) {
        session->inputTransferPending = 0;
    } else if (session->auxInputTransfer == transfer) {
        session->auxInputTransferPending = 0;
    }
}

static void midi_transfer_callback(struct libusb_transfer *transfer) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)transfer->user_data;
    if (session == NULL) return;
    session->midiTransferStatus = transfer->status;

#ifdef KK_DEBUG
    char head[96];
    kk_usb_debug_head(head, sizeof(head), transfer->buffer, transfer->actual_length);
    kk_usb_debug_log("usb-midi",
                     transfer->status == LIBUSB_TRANSFER_COMPLETED ? "INFO" : "ERROR",
                     "callback status=%d actual=%d endpoint=0x%02x head=%s",
                     transfer->status,
                     transfer->actual_length,
                     transfer->endpoint,
                     head);
#endif

    if (transfer->status == LIBUSB_TRANSFER_COMPLETED) {
        if (session->midiCallback) {
            session->midiCallback(transfer->buffer, transfer->actual_length, session->midiUserData);
        }
    }

    if (transfer->status == LIBUSB_TRANSFER_COMPLETED && session->midiTransfer == transfer && !session->closing) {
        int submitStatus = libusb_submit_transfer(transfer);
        session->midiTransferStatus = submitStatus == 0 ? LIBUSB_TRANSFER_COMPLETED : submitStatus;
        session->midiTransferPending = submitStatus == 0;
        kk_usb_debug_log("usb-midi",
                         submitStatus == 0 ? "TRACE" : "ERROR",
                         "resubmit status=%d",
                         submitStatus);
    } else if (session->midiTransfer == transfer) {
        session->midiTransferPending = 0;
    }
}

int KontrolUSBLibUSBSessionGetPollFds(KontrolUSBLibUSBSessionRef sessionRef,
                                       KontrolUSBPollFd *outFds, int maxFds) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->ctx == NULL || outFds == NULL || maxFds <= 0) {
        return -1;
    }

    const struct libusb_pollfd **pollfds = libusb_get_pollfds(session->ctx);
    if (pollfds == NULL) {
        return -1;
    }

    int count = 0;
    for (int i = 0; pollfds[i] != NULL && i < maxFds; i++) {
        outFds[i].fd = pollfds[i]->fd;
        outFds[i].events = pollfds[i]->events;
        kk_usb_debug_log("usb", "TRACE", "pollfd fd=%d events=0x%04x", outFds[i].fd, outFds[i].events);
        count++;
    }

    libusb_free_pollfds(pollfds);
    kk_usb_debug_log("usb", "TRACE", "pollfds count=%d", count);
    return count;
}

void KontrolUSBLibUSBHandleEventsTimeout(KontrolUSBLibUSBSessionRef sessionRef,
                                          int timeoutMs) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->ctx == NULL) return;

    struct timeval tv;
    tv.tv_sec = timeoutMs / 1000;
    tv.tv_usec = (timeoutMs % 1000) * 1000;
    int status = libusb_handle_events_timeout(session->ctx, &tv);
    kk_usb_debug_log("usb",
                     status == 0 ? "TRACE" : "ERROR",
                     "handle_events timeout_ms=%d status=%d",
                     timeoutMs,
                     status);
}

int KontrolUSBLibUSBSessionStartAsyncInput(KontrolUSBLibUSBSessionRef sessionRef,
                                            KontrolUSBInputCallback callback,
                                            void *userData) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->handle == NULL || session->inputEndpoint == 0) {
        kk_usb_debug_log("usb-surface", "ERROR", "start async input unavailable endpoint=0x%02x", session != NULL ? session->inputEndpoint : 0);
        return -1;
    }

    session->inputCallback = callback;
    session->inputUserData = userData;
    session->closing = 0;

    if (session->inputTransfer == NULL) {
        session->inputTransfer = libusb_alloc_transfer(0);
        if (session->inputTransfer == NULL) {
            kk_usb_debug_log("usb-surface", "ERROR", "alloc transfer failed");
            return -1;
        }
        libusb_fill_interrupt_transfer(session->inputTransfer,
                                       session->handle,
                                       session->inputEndpoint,
                                       session->inputBuffer,
                                       sizeof(session->inputBuffer),
                                       input_transfer_callback,
                                       session,
                                       0);
    }

    int status = libusb_submit_transfer(session->inputTransfer);
    session->inputTransferStatus = status == 0 ? LIBUSB_TRANSFER_COMPLETED : status;
    session->inputTransferPending = status == 0;
    kk_usb_debug_log("usb-surface",
                     status == 0 ? "INFO" : "ERROR",
                     "start async input endpoint=0x%02x buffer=%zu status=%d",
                     session->inputEndpoint,
                     sizeof(session->inputBuffer),
                     status);

    int auxStatus = 0;
    if (session->auxInputEndpoint != 0) {
        if (session->auxInputTransfer == NULL) {
            session->auxInputTransfer = libusb_alloc_transfer(0);
            if (session->auxInputTransfer == NULL) {
                kk_usb_debug_log("usb-surface", "ERROR", "alloc aux transfer failed");
                session->auxInputEndpoint = 0;
                return status == 0 ? 0 : status;
            }
            libusb_fill_interrupt_transfer(session->auxInputTransfer,
                                           session->handle,
                                           session->auxInputEndpoint,
                                           session->auxInputBuffer,
                                           sizeof(session->auxInputBuffer),
                                           input_transfer_callback,
                                           session,
                                           0);
        }
        auxStatus = libusb_submit_transfer(session->auxInputTransfer);
        session->auxInputTransferStatus = auxStatus == 0 ? LIBUSB_TRANSFER_COMPLETED : auxStatus;
        session->auxInputTransferPending = auxStatus == 0;
        kk_usb_debug_log("usb-surface",
                         auxStatus == 0 ? "INFO" : "ERROR",
                         "start async aux input endpoint=0x%02x buffer=%zu status=%d",
                         session->auxInputEndpoint,
                         sizeof(session->auxInputBuffer),
                         auxStatus);
        if (auxStatus != 0) {
            session->auxInputEndpoint = 0;
            session->auxInputTransferStatus = LIBUSB_TRANSFER_COMPLETED;
            session->auxInputTransferPending = 0;
        }
    }
    return status == 0 ? 0 : status;
}

int KontrolUSBLibUSBSessionStartAsyncMIDI(KontrolUSBLibUSBSessionRef sessionRef,
                                           KontrolUSBInputCallback callback,
                                           void *userData) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->handle == NULL || !session->midiClaimed || session->midiInputEndpoint == 0) {
        kk_usb_debug_log("usb-midi",
                         "ERROR",
                         "start async midi unavailable claimed=%d endpoint=0x%02x",
                         session != NULL ? session->midiClaimed : 0,
                         session != NULL ? session->midiInputEndpoint : 0);
        return -1;
    }

    session->midiCallback = callback;
    session->midiUserData = userData;
    session->closing = 0;

    if (session->midiTransfer == NULL) {
        session->midiTransfer = libusb_alloc_transfer(0);
        if (session->midiTransfer == NULL) {
            kk_usb_debug_log("usb-midi", "ERROR", "alloc transfer failed");
            return -1;
        }
        libusb_fill_bulk_transfer(session->midiTransfer,
                                  session->handle,
                                  session->midiInputEndpoint,
                                  session->midiBuffer,
                                  sizeof(session->midiBuffer),
                                  midi_transfer_callback,
                                  session,
                                  0);
    }

    int status = libusb_submit_transfer(session->midiTransfer);
    session->midiTransferStatus = status == 0 ? LIBUSB_TRANSFER_COMPLETED : status;
    session->midiTransferPending = status == 0;
    kk_usb_debug_log("usb-midi",
                     status == 0 ? "INFO" : "ERROR",
                     "start async midi endpoint=0x%02x buffer=%zu status=%d",
                     session->midiInputEndpoint,
                     sizeof(session->midiBuffer),
                     status);
    return status;
}

void KontrolUSBLibUSBSessionStopAsync(KontrolUSBLibUSBSessionRef sessionRef) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL) return;

    session->closing = 1;

    if (session->inputTransfer != NULL && session->inputTransferPending) {
        libusb_cancel_transfer(session->inputTransfer);
    }
    if (session->auxInputTransfer != NULL && session->auxInputTransferPending) {
        libusb_cancel_transfer(session->auxInputTransfer);
    }
    if (session->midiTransfer != NULL && session->midiTransferPending) {
        libusb_cancel_transfer(session->midiTransfer);
    }

    if (session->ctx != NULL) {
        for (int i = 0; i < 100 && (session->inputTransferPending || session->auxInputTransferPending || session->midiTransferPending); i++) {
            struct timeval tv = {0, 10000};
            libusb_handle_events_timeout(session->ctx, &tv);
        }
    }
}
