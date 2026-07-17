#include "KontrolUSB.h"

#include <libusb.h>
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
#define KONTROL_NO_INTERFACE 0xff
#define KONTROL_NO_ENDPOINT 0x00

typedef struct {
    uint16_t productID;
    const char *name;
    uint8_t keyCount;
    uint8_t claimInterface;
    uint8_t displayInterface;
    uint8_t displayOutputEndpointFallback;
    uint8_t surfaceInterface;
    uint8_t claimsMIDI;
    uint16_t surfaceInputTransferSize;
} KontrolDeviceDescriptor;

static const KontrolDeviceDescriptor kKontrolDevices[] = {
    {0x1610, "Komplete Kontrol S49 MK2", 49, 3, 3, 0x03, KONTROL_NO_INTERFACE, 1, 256},
    {0x1620, "Komplete Kontrol S61 MK2", 61, 3, 3, 0x03, KONTROL_NO_INTERFACE, 1, 256},
    {0x1630, "Komplete Kontrol S88 MK2", 88, 3, 3, 0x03, KONTROL_NO_INTERFACE, 1, 256},
    {0x1600, "Maschine MK3", 0, 5, 5, 0x04, 4, 0, 64},
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
    uint8_t midiBuffer[512];
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
    result->endpointAddress = device != NULL ? device->displayOutputEndpointFallback : KONTROL_NO_ENDPOINT;
    result_append(result, "device=%s pid=0x%04x claimInterface=%u; ",
                  device != NULL ? device->name : "unknown",
                  device != NULL ? device->productID : productID,
                  device != NULL ? device->claimInterface : KONTROL_NO_INTERFACE);

    uint8_t claimInterface = device != NULL ? device->claimInterface : KONTROL_NO_INTERFACE;
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
                                              const KontrolDeviceDescriptor *deviceProfile,
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
            if (deviceProfile != NULL
                && deviceProfile->surfaceInterface != KONTROL_NO_INTERFACE
                && alt->bInterfaceNumber != deviceProfile->surfaceInterface) {
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
        session->device,
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
                result_append(result, "aux HID claim unavailable status=%d (%s); ",
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
            uint8_t claimedInterface = device != NULL ? device->claimInterface : KONTROL_NO_INTERFACE;
            libusb_close_claim_interface(session->ctx, session->handle, claimedInterface, &result);
        }
        free(session);
        result.status = status;
        return result;
    }

    session->device = device;
    session->claimedInterface = device != NULL ? device->claimInterface : KONTROL_NO_INTERFACE;
    session->surfaceInterface = 0xff;
    session->surfaceClaimed = 0;
    session->auxSurfaceInterface = 0xff;
    session->auxSurfaceClaimed = 0;
    session->auxInputEndpoint = 0;
    session->displayInterface = device != NULL ? device->displayInterface : KONTROL_NO_INTERFACE;
    session->displayOutputEndpoint = 0;

    libusb_find_bulk_display_endpoint(session->handle, device, &session->displayOutputEndpoint, &result);
    int surfaceStatus = libusb_claim_hid_surface(session, &result);
    if (surfaceStatus != 0) {
        result_append(&result, "HID surface claim unavailable status=%d (%s); ",
                      surfaceStatus,
                      surfaceStatus < 0 ? libusb_error_name(surfaceStatus) : "OK");
    }
    session->midiInterface = KONTROL_NO_INTERFACE;
    session->midiInputEndpoint = KONTROL_NO_ENDPOINT;
    session->midiClaimed = 0;
    if (device != NULL && device->claimsMIDI) {
        int midiStatus = libusb_claim_midi_streaming(session, &result);
        if (midiStatus != 0 && midiStatus != LIBUSB_ERROR_NOT_FOUND) {
            result_append(&result, "USB-MIDI claim unavailable status=%d (%s); ",
                          midiStatus,
                          midiStatus < 0 ? libusb_error_name(midiStatus) : "OK");
        }
    } else {
        result_append(&result, "USB-MIDI claim disabled by device profile; ");
    }
    result.endpointAddress = session->outputEndpoint != 0 ? session->outputEndpoint : session->displayOutputEndpoint;
    *sessionOut = session;
    result.status = 0;
    return result;
}

KontrolUSBResult KontrolUSBLibUSBSessionOpen(KontrolUSBLibUSBSessionRef *sessionOut) {
    return KontrolUSBLibUSBSessionOpenForProduct(0, sessionOut);
}

uint16_t KontrolUSBLibUSBSessionProductID(KontrolUSBLibUSBSessionRef sessionRef) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->device == NULL) {
        return 0;
    }
    return session->device->productID;
}

uint16_t KontrolUSBLibUSBSessionFirmwareVersion(KontrolUSBLibUSBSessionRef sessionRef) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->handle == NULL) {
        return 0;
    }
    libusb_device *device = libusb_get_device(session->handle);
    if (device == NULL) {
        return 0;
    }
    struct libusb_device_descriptor descriptor;
    if (libusb_get_device_descriptor(device, &descriptor) != 0) {
        return 0;
    }
    return descriptor.bcdDevice;
}

/* Async transfers are only resubmitted on LIBUSB_TRANSFER_COMPLETED, so any other final
 * status means the input/MIDI stream is dead and the session must be reopened. CANCELLED
 * and TIMED_OUT are excluded: they occur during orderly close, not device loss. */
static int transfer_status_is_fatal(int status) {
    if (status < 0) {
        return status != LIBUSB_ERROR_TIMEOUT;
    }
    switch (status) {
        case LIBUSB_TRANSFER_COMPLETED:
        case LIBUSB_TRANSFER_CANCELLED:
        case LIBUSB_TRANSFER_TIMED_OUT:
            return 0;
        default:
            return 1;
    }
}

int KontrolUSBLibUSBSessionDeviceLost(KontrolUSBLibUSBSessionRef sessionRef) {
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->closing) {
        return 0;
    }
    if (transfer_status_is_fatal(session->inputTransferStatus)) {
        return 1;
    }
    if (session->auxInputTransfer != NULL && transfer_status_is_fatal(session->auxInputTransferStatus)) {
        return 1;
    }
    if (session->midiTransfer != NULL && transfer_status_is_fatal(session->midiTransferStatus)) {
        return 1;
    }
    return 0;
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
    result_append(&result, "session device=%s pid=0x%04x claimedInterface=%u surfaceInterface=%u surfaceClaimed=%u auxSurfaceInterface=%u auxSurfaceClaimed=%u endpoints in=0x%02x auxIn=0x%02x out=0x%02x displayInterface=%u displayOut=0x%02x midiInterface=%u midiIn=0x%02x midiClaimed=%u; ",
                  session->device != NULL ? session->device->name : "unknown",
                  session->device != NULL ? session->device->productID : 0,
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
    result.endpointAddress = session->outputEndpoint;
    if (session->device != NULL && session->device->productID == 0x1600) {
        uint32_t expectedPayloadLen = 0;
        if (reportID == 0x80) {
            expectedPayloadLen = 62;
        } else if (reportID == 0x81) {
            expectedPayloadLen = 41;
        } else {
            result_append(&result, "MASCHINE MK3 output report 0x%02x is not verified; ", reportID);
            return result;
        }
        if (payloadLen != expectedPayloadLen) {
            result_append(&result,
                          "MASCHINE MK3 output report 0x%02x payload len%u expected%u; ",
                          reportID,
                          payloadLen,
                          expectedPayloadLen);
            return result;
        }
    }
    int status = 0;
    if (session->outputEndpoint != 0) {
        status = libusb_write_report(session->handle, session->outputEndpoint, reportID, payload, payloadLen, &result);
    } else if (session->surfaceClaimed && session->surfaceInterface != 0xff) {
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

static uint16_t get_be16(const uint8_t *buffer, size_t offset) {
    return (uint16_t)(((uint16_t)buffer[offset] << 8) | buffer[offset + 1]);
}

KontrolUSBResult KontrolUSBLibUSBSessionWriteMK2DisplayPacket(KontrolUSBLibUSBSessionRef sessionRef,
                                                              const uint8_t *packet,
                                                              uint32_t byteCount,
                                                              uint32_t timeoutMs) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = LIBUSB_ERROR_INVALID_PARAM;
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->handle == NULL || packet == NULL || byteCount < 28 || byteCount > INT32_MAX) {
        return result;
    }
    result.opened = 1;
    result.pipeRef = 1;
    result.endpointAddress = session->displayOutputEndpoint;
    if (session->displayOutputEndpoint == 0) {
        result_append(&result, "no MK2 bulk display endpoint discovered; ");
        result.status = LIBUSB_ERROR_NOT_FOUND;
        return result;
    }

    int transferred = 0;
    uint32_t timeout = timeoutMs == 0 ? 1000 : timeoutMs;
    int status = libusb_bulk_transfer(session->handle,
                                      session->displayOutputEndpoint,
                                      (uint8_t *)packet,
                                      (int)byteCount,
                                      &transferred,
                                      timeout);
    if (status == 0 && transferred != (int)byteCount) {
        status = LIBUSB_ERROR_IO;
    }
    result.transferredBytes = transferred > 0 ? (uint32_t)transferred : 0;
    result_append(&result,
                  "mk2 bulk_transfer ep0x%02x screen=%u rect=%u,%u %ux%u packetBytes=%u -> %d (%s) transferred=%d; ",
                  session->displayOutputEndpoint,
                  byteCount > 2 ? packet[2] : 0xff,
                  get_be16(packet, 8),
                  get_be16(packet, 10),
                  get_be16(packet, 12),
                  get_be16(packet, 14),
                  byteCount,
                  status,
                  status < 0 ? libusb_error_name(status) : "OK",
                  transferred);
    result.status = status;
    return result;
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
    result.transferredBytes = transferred > 0 ? (uint32_t)transferred : 0;
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

KontrolUSBResult KontrolUSBLibUSBSessionWriteMK2DisplayBytes(KontrolUSBLibUSBSessionRef sessionRef,
                                                             uint8_t screen,
                                                             uint16_t x,
                                                             uint16_t y,
                                                             uint16_t width,
                                                             uint16_t height,
                                                             const uint8_t *pixelsRGB565BE,
                                                             uint32_t byteCount,
                                                             uint32_t timeoutMs) {
    KontrolUSBResult result;
    memset(&result, 0, sizeof(result));
    result.status = LIBUSB_ERROR_INVALID_PARAM;
    KontrolLibUSBSession *session = (KontrolLibUSBSession *)sessionRef;
    if (session == NULL || session->handle == NULL || pixelsRGB565BE == NULL) {
        return result;
    }
    result.opened = 1;
    result.pipeRef = 1;
    result.endpointAddress = session->displayOutputEndpoint;

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
    uint32_t expectedBytes = expectedPixels * 2;
    if (expectedBytes != byteCount) {
        result_append(&result, "byte count mismatch expected=%u actual=%u; ", expectedBytes, byteCount);
        result.status = LIBUSB_ERROR_INVALID_PARAM;
        return result;
    }
    if ((expectedPixels % 2) != 0) {
        result_append(&result, "MK2 display protocol requires an even pixel count pixels=%u; ", expectedPixels);
        result.status = LIBUSB_ERROR_INVALID_PARAM;
        return result;
    }
    if ((expectedPixels / 2) > 0xffff) {
        result_append(&result, "rect too large for MK2 count field pixels=%u; ", expectedPixels);
        result.status = LIBUSB_ERROR_OVERFLOW;
        return result;
    }

    const size_t headerLen = 24;
    const size_t trailerLen = 12;
    size_t totalLen = headerLen + (size_t)byteCount + trailerLen;
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
    put_be16(buffer, &offset, (uint16_t)(expectedPixels / 2));

    memcpy(buffer + offset, pixelsRGB565BE, byteCount);
    offset += byteCount;

    const uint8_t trailer[] = {0x02, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00};
    memcpy(buffer + offset, trailer, sizeof(trailer));
    offset += sizeof(trailer);

    int transferred = 0;
    uint32_t timeout = timeoutMs == 0 ? 1000 : timeoutMs;
    int status = libusb_bulk_transfer(session->handle, session->displayOutputEndpoint, buffer, (int)offset, &transferred, timeout);
    result.transferredBytes = transferred > 0 ? (uint32_t)transferred : 0;
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
        size_t transferSize = session->device != NULL
            ? session->device->surfaceInputTransferSize
            : sizeof(session->inputBuffer);
        if (transferSize == 0 || transferSize > sizeof(session->inputBuffer)) {
            transferSize = sizeof(session->inputBuffer);
        }
        libusb_fill_interrupt_transfer(session->inputTransfer,
                                       session->handle,
                                       session->inputEndpoint,
                                       session->inputBuffer,
                                       (int)transferSize,
                                       input_transfer_callback,
                                       session,
                                       0);
    }

    int status = libusb_submit_transfer(session->inputTransfer);
    session->inputTransferStatus = status == 0 ? LIBUSB_TRANSFER_COMPLETED : status;
    session->inputTransferPending = status == 0;
    kk_usb_debug_log("usb-surface",
                     status == 0 ? "INFO" : "ERROR",
                     "start async input endpoint=0x%02x buffer=%d status=%d",
                     session->inputEndpoint,
                     session->inputTransfer != NULL ? session->inputTransfer->length : 0,
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
