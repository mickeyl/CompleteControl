#include <errno.h>
#include <getopt.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include <libusb.h>

#include "MK2DisplayCommandREPL.h"

static const uint16_t kVendorNativeInstruments = 0x17cc;
static const uint16_t kSupportedPIDs[] = {0x1610, 0x1620, 0x1630, 0x1600};
static const uint16_t kMaschineMK3PID = 0x1600;

static volatile sig_atomic_t g_shouldStop = 0;

typedef struct {
    struct libusb_transfer *transfer;
    uint8_t *buffer;
    uint8_t endpoint;
    uint8_t interfaceNumber;
    uint8_t transferType;
    int packetSize;
    uint64_t sequence;
} EndpointWatch;

typedef struct {
    bool requested[256];
    int count;
} InterfaceSelection;

static bool parse_u16(const char *text, uint16_t *valueOut);

static void handle_signal(int signalNumber) {
    (void)signalNumber;
    g_shouldStop = 1;
}

static uint64_t now_micros(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
}

static const char *class_name(uint8_t value) {
    switch (value) {
        case LIBUSB_CLASS_PER_INTERFACE: return "per-interface";
        case LIBUSB_CLASS_AUDIO: return "audio";
        case LIBUSB_CLASS_COMM: return "comm";
        case LIBUSB_CLASS_HID: return "hid";
        case LIBUSB_CLASS_PHYSICAL: return "physical";
        case LIBUSB_CLASS_IMAGE: return "image";
        case LIBUSB_CLASS_PRINTER: return "printer";
        case LIBUSB_CLASS_MASS_STORAGE: return "mass-storage";
        case LIBUSB_CLASS_HUB: return "hub";
        case LIBUSB_CLASS_DATA: return "data";
        case LIBUSB_CLASS_VENDOR_SPEC: return "vendor";
        default: return "unknown";
    }
}

static const char *transfer_type_name(uint8_t bmAttributes) {
    switch (bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) {
        case LIBUSB_TRANSFER_TYPE_CONTROL: return "control";
        case LIBUSB_TRANSFER_TYPE_ISOCHRONOUS: return "iso";
        case LIBUSB_TRANSFER_TYPE_BULK: return "bulk";
        case LIBUSB_TRANSFER_TYPE_INTERRUPT: return "interrupt";
        default: return "unknown";
    }
}

static const char *transfer_status_name(enum libusb_transfer_status status) {
    switch (status) {
        case LIBUSB_TRANSFER_COMPLETED: return "completed";
        case LIBUSB_TRANSFER_ERROR: return "error";
        case LIBUSB_TRANSFER_TIMED_OUT: return "timed-out";
        case LIBUSB_TRANSFER_CANCELLED: return "cancelled";
        case LIBUSB_TRANSFER_STALL: return "stall";
        case LIBUSB_TRANSFER_NO_DEVICE: return "no-device";
        case LIBUSB_TRANSFER_OVERFLOW: return "overflow";
        default: return "unknown";
    }
}

static bool is_supported_pid(uint16_t productID) {
    for (size_t index = 0; index < sizeof(kSupportedPIDs) / sizeof(kSupportedPIDs[0]); index++) {
        if (kSupportedPIDs[index] == productID) {
            return true;
        }
    }
    return false;
}

static bool parse_interface_list(const char *text, InterfaceSelection *selection) {
    if (text == NULL || text[0] == '\0' || text[0] == ',' || text[strlen(text) - 1] == ',' || strstr(text, ",,") != NULL) {
        return false;
    }
    char *copy = strdup(text);
    if (copy == NULL) {
        return false;
    }
    char *save = NULL;
    for (char *token = strtok_r(copy, ",", &save); token != NULL; token = strtok_r(NULL, ",", &save)) {
        uint16_t value = 0;
        if (!parse_u16(token, &value) || value > UINT8_MAX || selection->requested[value]) {
            free(copy);
            return false;
        }
        selection->requested[value] = true;
        selection->count++;
    }
    free(copy);
    return selection->count > 0;
}

static bool parse_u16(const char *text, uint16_t *valueOut) {
    char *end = NULL;
    errno = 0;
    unsigned long value = strtoul(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0' || value > 0xffffUL) {
        return false;
    }
    *valueOut = (uint16_t)value;
    return true;
}

static void print_hex(const uint8_t *bytes, int length) {
    for (int index = 0; index < length; index++) {
        printf("%s%02x", index == 0 ? "" : " ", bytes[index]);
    }
}

static void print_hex_lines(const uint8_t *bytes, int length, const char *indent) {
    for (int index = 0; index < length; index += 16) {
        int lineLength = length - index < 16 ? length - index : 16;
        printf("%s%04x: ", indent, index);
        print_hex(bytes + index, lineLength);
        printf("\n");
    }
}

static void print_string_descriptor(libusb_device_handle *handle, const char *label, uint8_t index) {
    if (index == 0) {
        return;
    }
    unsigned char buffer[256];
    int status = libusb_get_string_descriptor_ascii(handle, index, buffer, sizeof(buffer));
    if (status >= 0) {
        printf("  %s[%u] = %s\n", label, index, buffer);
    } else {
        printf("  %s[%u] -> %s\n", label, index, libusb_error_name(status));
    }
}

static void dump_hid_report_descriptor(libusb_device_handle *handle, uint8_t interfaceNumber, const unsigned char *extra, int extraLength) {
    for (int offset = 0; offset + 6 < extraLength;) {
        uint8_t descriptorLength = extra[offset];
        if (descriptorLength == 0 || offset + descriptorLength > extraLength) {
            break;
        }
        uint8_t descriptorType = extra[offset + 1];
        if (descriptorType == 0x21 && descriptorLength >= 6) {
            uint8_t descriptorCount = extra[offset + 5];
            for (uint8_t index = 0; index < descriptorCount; index++) {
                int descriptorOffset = offset + 6 + index * 3;
                if (descriptorOffset + 2 >= offset + descriptorLength) {
                    break;
                }
                uint8_t hidDescriptorType = extra[descriptorOffset];
                uint16_t hidDescriptorLength = (uint16_t)extra[descriptorOffset + 1] | ((uint16_t)extra[descriptorOffset + 2] << 8);
                if (hidDescriptorType != 0x22 || hidDescriptorLength == 0) {
                    continue;
                }

                uint8_t *buffer = calloc(hidDescriptorLength, 1);
                if (buffer == NULL) {
                    printf("      HID report descriptor allocation failed length=%u\n", hidDescriptorLength);
                    continue;
                }
                int status = libusb_control_transfer(
                    handle,
                    LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_STANDARD | LIBUSB_RECIPIENT_INTERFACE,
                    LIBUSB_REQUEST_GET_DESCRIPTOR,
                    (uint16_t)(hidDescriptorType << 8),
                    interfaceNumber,
                    buffer,
                    hidDescriptorLength,
                    1000
                );
                if (status < 0) {
                    printf("      HID report descriptor if=%u type=0x%02x len=%u -> %s\n",
                           interfaceNumber,
                           hidDescriptorType,
                           hidDescriptorLength,
                           libusb_error_name(status));
                } else {
                    printf("      HID report descriptor if=%u len=%d\n", interfaceNumber, status);
                    print_hex_lines(buffer, status, "        ");
                }
                free(buffer);
            }
        }
        offset += descriptorLength;
    }
}

static void dump_descriptors(libusb_device *device, libusb_device_handle *handle) {
    struct libusb_device_descriptor descriptor;
    int status = libusb_get_device_descriptor(device, &descriptor);
    if (status != 0) {
        printf("libusb_get_device_descriptor -> %s\n", libusb_error_name(status));
        return;
    }

    printf("device bus=%u address=%u vid=0x%04x pid=0x%04x usb=%x.%02x bcdDevice=0x%04x class=0x%02x/%s configs=%u\n",
           libusb_get_bus_number(device),
           libusb_get_device_address(device),
           descriptor.idVendor,
           descriptor.idProduct,
           descriptor.bcdUSB >> 8,
           descriptor.bcdUSB & 0xff,
           descriptor.bcdDevice,
           descriptor.bDeviceClass,
           class_name(descriptor.bDeviceClass),
           descriptor.bNumConfigurations);
    print_string_descriptor(handle, "manufacturer", descriptor.iManufacturer);
    print_string_descriptor(handle, "product", descriptor.iProduct);
    print_string_descriptor(handle, "serial", descriptor.iSerialNumber);

    for (uint8_t configIndex = 0; configIndex < descriptor.bNumConfigurations; configIndex++) {
        struct libusb_config_descriptor *config = NULL;
        status = libusb_get_config_descriptor(device, configIndex, &config);
        if (status != 0) {
            printf("config[%u] -> %s\n", configIndex, libusb_error_name(status));
            continue;
        }

        printf("config[%u] value=%u interfaces=%u attributes=0x%02x maxPower=%umA extra=%d\n",
               configIndex,
               config->bConfigurationValue,
               config->bNumInterfaces,
               config->bmAttributes,
               config->MaxPower * 2,
               config->extra_length);
        if (config->extra_length > 0) {
            printf("  config extra: ");
            print_hex(config->extra, config->extra_length);
            printf("\n");
        }

        for (uint8_t interfaceIndex = 0; interfaceIndex < config->bNumInterfaces; interfaceIndex++) {
            const struct libusb_interface *interface = &config->interface[interfaceIndex];
            printf("  interface[%u] altSettings=%d\n", interfaceIndex, interface->num_altsetting);
            for (int altIndex = 0; altIndex < interface->num_altsetting; altIndex++) {
                const struct libusb_interface_descriptor *alt = &interface->altsetting[altIndex];
                printf("    alt[%d] if=%u alt=%u class=0x%02x/%s subclass=0x%02x protocol=0x%02x endpoints=%u extra=%d\n",
                       altIndex,
                       alt->bInterfaceNumber,
                       alt->bAlternateSetting,
                       alt->bInterfaceClass,
                       class_name(alt->bInterfaceClass),
                       alt->bInterfaceSubClass,
                       alt->bInterfaceProtocol,
                       alt->bNumEndpoints,
                       alt->extra_length);
                if (alt->extra_length > 0) {
                    printf("      interface extra: ");
                    print_hex(alt->extra, alt->extra_length);
                    printf("\n");
                    if (alt->bInterfaceClass == LIBUSB_CLASS_HID) {
                        dump_hid_report_descriptor(handle, alt->bInterfaceNumber, alt->extra, alt->extra_length);
                    }
                }
                for (uint8_t endpointIndex = 0; endpointIndex < alt->bNumEndpoints; endpointIndex++) {
                    const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[endpointIndex];
                    printf("      ep[%u] addr=0x%02x dir=%s type=%s attr=0x%02x maxPacket=%u interval=%u refresh=%u synch=%u extra=%d\n",
                           endpointIndex,
                           endpoint->bEndpointAddress,
                           (endpoint->bEndpointAddress & LIBUSB_ENDPOINT_IN) ? "in" : "out",
                           transfer_type_name(endpoint->bmAttributes),
                           endpoint->bmAttributes,
                           endpoint->wMaxPacketSize,
                           endpoint->bInterval,
                           endpoint->bRefresh,
                           endpoint->bSynchAddress,
                           endpoint->extra_length);
                    if (endpoint->extra_length > 0) {
                        printf("        endpoint extra: ");
                        print_hex(endpoint->extra, endpoint->extra_length);
                        printf("\n");
                    }
                }
            }
        }
        libusb_free_config_descriptor(config);
    }
}

static void transfer_callback(struct libusb_transfer *transfer) {
    EndpointWatch *watch = (EndpointWatch *)transfer->user_data;
    watch->sequence++;
    if (transfer->status == LIBUSB_TRANSFER_COMPLETED && transfer->actual_length > 0) {
        printf("timestamp=%llu endpoint=0x%02x interface=%u type=%s seq=%llu len=%d data=",
               (unsigned long long)now_micros(),
               watch->endpoint,
               watch->interfaceNumber,
               transfer_type_name(watch->transferType),
               (unsigned long long)watch->sequence,
               transfer->actual_length);
        print_hex(watch->buffer, transfer->actual_length);
        printf("\n");
        fflush(stdout);
    } else if (transfer->status != LIBUSB_TRANSFER_COMPLETED) {
        printf("timestamp=%llu endpoint=0x%02x interface=%u type=%s seq=%llu status=%s actual=%d\n",
               (unsigned long long)now_micros(),
               watch->endpoint,
               watch->interfaceNumber,
               transfer_type_name(watch->transferType),
               (unsigned long long)watch->sequence,
               transfer_status_name(transfer->status),
               transfer->actual_length);
        fflush(stdout);
    }

    if (!g_shouldStop && transfer->status != LIBUSB_TRANSFER_CANCELLED && transfer->status != LIBUSB_TRANSFER_NO_DEVICE) {
        int status = libusb_submit_transfer(transfer);
        if (status != 0) {
            printf("endpoint=0x%02x resubmit -> %s\n", watch->endpoint, libusb_error_name(status));
            fflush(stdout);
        }
    }
}

static int claim_interfaces(libusb_device_handle *handle,
                            libusb_device *device,
                            bool detachKernelDrivers,
                            const InterfaceSelection *selection,
                            bool claimedInterfaces[256],
                            bool detachedInterfaces[256]) {
    struct libusb_config_descriptor *config = NULL;
    int status = libusb_get_active_config_descriptor(device, &config);
    if (status != 0) {
        printf("libusb_get_active_config_descriptor -> %s\n", libusb_error_name(status));
        return status;
    }

    bool foundInterfaces[256] = {false};
    for (uint8_t index = 0; index < config->bNumInterfaces; index++) {
        const struct libusb_interface *interface = &config->interface[index];
        if (interface->num_altsetting > 0) {
            foundInterfaces[interface->altsetting[0].bInterfaceNumber] = true;
        }
    }
    if (selection->count > 0) {
        for (int interfaceNumber = 0; interfaceNumber <= UINT8_MAX; interfaceNumber++) {
            if (selection->requested[interfaceNumber] && !foundInterfaces[interfaceNumber]) {
                fprintf(stderr, "Interface %d is not present on the selected device. Run with --describe to inspect it.\n", interfaceNumber);
                libusb_free_config_descriptor(config);
                return LIBUSB_ERROR_NOT_FOUND;
            }
        }
    }

    int claimed = 0;
    for (uint8_t index = 0; index < config->bNumInterfaces; index++) {
        const struct libusb_interface *interface = &config->interface[index];
        if (interface->num_altsetting <= 0) {
            continue;
        }
        uint8_t interfaceNumber = interface->altsetting[0].bInterfaceNumber;
        if (selection->count > 0 && !selection->requested[interfaceNumber]) {
            continue;
        }
        bool detached = false;
        if (detachKernelDrivers) {
            int active = libusb_kernel_driver_active(handle, interfaceNumber);
            printf("claim if=%u kernel_driver_active -> %s\n",
                   interfaceNumber,
                   active >= 0 ? (active ? "yes" : "no") : libusb_error_name(active));
            if (active == 1) {
                int detachStatus = libusb_detach_kernel_driver(handle, interfaceNumber);
                printf("claim if=%u detach_kernel_driver -> %s\n", interfaceNumber, libusb_error_name(detachStatus));
                detached = detachStatus == 0;
            }
        }
        status = libusb_claim_interface(handle, interfaceNumber);
        printf("claim if=%u -> %s\n", interfaceNumber, libusb_error_name(status));
        if (status == 0) {
            claimedInterfaces[interfaceNumber] = true;
            detachedInterfaces[interfaceNumber] = detached;
            claimed++;
        } else if (detached) {
            int attachStatus = libusb_attach_kernel_driver(handle, interfaceNumber);
            printf("claim if=%u reattach_after_failure -> %s\n", interfaceNumber, libusb_error_name(attachStatus));
        }
    }
    libusb_free_config_descriptor(config);
    if (selection->count > 0 && claimed != selection->count) {
        return LIBUSB_ERROR_BUSY;
    }
    return claimed > 0 ? 0 : LIBUSB_ERROR_BUSY;
}

static EndpointWatch *start_endpoint_watches(libusb_device_handle *handle,
                                             libusb_device *device,
                                             const bool claimedInterfaces[256],
                                             int *countOut) {
    *countOut = 0;
    struct libusb_config_descriptor *config = NULL;
    int status = libusb_get_active_config_descriptor(device, &config);
    if (status != 0) {
        printf("libusb_get_active_config_descriptor -> %s\n", libusb_error_name(status));
        return NULL;
    }

    int endpointCount = 0;
    for (uint8_t interfaceIndex = 0; interfaceIndex < config->bNumInterfaces; interfaceIndex++) {
        const struct libusb_interface *interface = &config->interface[interfaceIndex];
        for (int altIndex = 0; altIndex < interface->num_altsetting; altIndex++) {
            const struct libusb_interface_descriptor *alt = &interface->altsetting[altIndex];
            if (!claimedInterfaces[alt->bInterfaceNumber]) {
                continue;
            }
            for (uint8_t endpointIndex = 0; endpointIndex < alt->bNumEndpoints; endpointIndex++) {
                const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[endpointIndex];
                uint8_t type = endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;
                if ((endpoint->bEndpointAddress & LIBUSB_ENDPOINT_IN) != 0 &&
                    (type == LIBUSB_TRANSFER_TYPE_INTERRUPT || type == LIBUSB_TRANSFER_TYPE_BULK)) {
                    endpointCount++;
                }
            }
        }
    }

    EndpointWatch *watches = calloc((size_t)endpointCount, sizeof(EndpointWatch));
    if (watches == NULL) {
        libusb_free_config_descriptor(config);
        return NULL;
    }

    int watchIndex = 0;
    for (uint8_t interfaceIndex = 0; interfaceIndex < config->bNumInterfaces; interfaceIndex++) {
        const struct libusb_interface *interface = &config->interface[interfaceIndex];
        for (int altIndex = 0; altIndex < interface->num_altsetting; altIndex++) {
            const struct libusb_interface_descriptor *alt = &interface->altsetting[altIndex];
            if (!claimedInterfaces[alt->bInterfaceNumber]) {
                continue;
            }
            if (alt->bAlternateSetting != 0) {
                int altStatus = libusb_set_interface_alt_setting(handle, alt->bInterfaceNumber, alt->bAlternateSetting);
                printf("set alt if=%u alt=%u -> %s\n", alt->bInterfaceNumber, alt->bAlternateSetting, libusb_error_name(altStatus));
                if (altStatus != 0) {
                    continue;
                }
            }
            for (uint8_t endpointIndex = 0; endpointIndex < alt->bNumEndpoints; endpointIndex++) {
                const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[endpointIndex];
                uint8_t type = endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;
                if ((endpoint->bEndpointAddress & LIBUSB_ENDPOINT_IN) == 0 ||
                    (type != LIBUSB_TRANSFER_TYPE_INTERRUPT && type != LIBUSB_TRANSFER_TYPE_BULK)) {
                    continue;
                }

                EndpointWatch *watch = &watches[watchIndex++];
                watch->endpoint = endpoint->bEndpointAddress;
                watch->interfaceNumber = alt->bInterfaceNumber;
                watch->transferType = type;
                watch->packetSize = endpoint->wMaxPacketSize > 0 ? endpoint->wMaxPacketSize : 512;
                watch->buffer = calloc((size_t)watch->packetSize, 1);
                watch->transfer = libusb_alloc_transfer(0);
                if (watch->buffer == NULL || watch->transfer == NULL) {
                    printf("watch ep=0x%02x allocation failed\n", watch->endpoint);
                    continue;
                }

                if (type == LIBUSB_TRANSFER_TYPE_INTERRUPT) {
                    libusb_fill_interrupt_transfer(watch->transfer, handle, watch->endpoint, watch->buffer, watch->packetSize, transfer_callback, watch, 0);
                } else {
                    libusb_fill_bulk_transfer(watch->transfer, handle, watch->endpoint, watch->buffer, watch->packetSize, transfer_callback, watch, 0);
                }
                status = libusb_submit_transfer(watch->transfer);
                printf("watch ep=0x%02x if=%u type=%s maxPacket=%d submit -> %s\n",
                       watch->endpoint,
                       watch->interfaceNumber,
                       transfer_type_name(type),
                       watch->packetSize,
                       libusb_error_name(status));
            }
        }
    }

    libusb_free_config_descriptor(config);
    *countOut = endpointCount;
    return watches;
}

static void stop_endpoint_watches(EndpointWatch *watches, int count, libusb_context *context) {
    for (int index = 0; index < count; index++) {
        if (watches[index].transfer != NULL) {
            libusb_cancel_transfer(watches[index].transfer);
        }
    }

    struct timeval timeout = {.tv_sec = 0, .tv_usec = 10000};
    for (int spin = 0; spin < 20; spin++) {
        libusb_handle_events_timeout_completed(context, &timeout, NULL);
    }

    for (int index = 0; index < count; index++) {
        if (watches[index].transfer != NULL) {
            libusb_free_transfer(watches[index].transfer);
        }
        free(watches[index].buffer);
    }
    free(watches);
}

static void release_claimed_interfaces(libusb_device_handle *handle,
                                       libusb_device *device,
                                       const bool claimedInterfaces[256],
                                       const bool detachedInterfaces[256]) {
    struct libusb_config_descriptor *config = NULL;
    int status = libusb_get_active_config_descriptor(device, &config);
    if (status != 0) {
        return;
    }
    for (uint8_t index = 0; index < config->bNumInterfaces; index++) {
        const struct libusb_interface *interface = &config->interface[index];
        if (interface->num_altsetting <= 0) {
            continue;
        }
        uint8_t interfaceNumber = interface->altsetting[0].bInterfaceNumber;
        if (!claimedInterfaces[interfaceNumber]) {
            continue;
        }
        status = libusb_release_interface(handle, interfaceNumber);
        printf("release if=%u -> %s\n", interfaceNumber, libusb_error_name(status));
        if (detachedInterfaces[interfaceNumber]) {
            status = libusb_attach_kernel_driver(handle, interfaceNumber);
            printf("reattach if=%u -> %s\n", interfaceNumber, libusb_error_name(status));
        }
    }
    libusb_free_config_descriptor(config);
}

static bool parse_nonnegative_int(const char *text, int *valueOut) {
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < 0 || value > INT32_MAX) {
        return false;
    }
    *valueOut = (int)value;
    return true;
}

static void usage(FILE *stream, const char *argv0) {
    fprintf(stream,
            "Examples:\n"
            "  %s --pid 0x1600 --describe\n"
            "  %s --pid 0x1600 --interfaces 4 --seconds 10\n"
            "  %s --seconds 10\n"
            "  %s --pid 0x1620 --display-repl\n"
            "  %s --display-command-self-test\n"
            "\n"
            "Usage: %s [options]\n"
            "\n"
            "Inspect supported Native Instruments USB devices or interactively verify\n"
            "the colour-display command stream. Descriptor mode never claims an\n"
            "interface. Capture mode must run with the daemon stopped and usually sudo.\n"
            "\n"
            "Options:\n"
            "  --describe                   Print descriptors without claiming interfaces.\n"
            "  --interfaces <list>          Claim only comma-separated interfaces, for example 4,5.\n"
            "  --display-repl               Claim only the display interface and open the REPL.\n"
            "  --display-command-self-test  Verify packet construction without USB hardware.\n"
            "  --pid <value>                Select a supported product ID, for example 0x1600.\n"
            "  --seconds <count>            Stop packet capture after this many seconds.\n"
            "  --no-detach                  Do not detach kernel drivers before claiming USB.\n"
            "  -h, --help                   Show this help.\n",
            argv0,
            argv0,
            argv0,
            argv0,
            argv0,
            argv0);
}

int main(int argc, char **argv) {
    uint16_t forcedPID = 0;
    int seconds = 0;
    bool detachKernelDrivers = true;
    bool displayREPL = false;
    bool displayCommandSelfTest = false;
    bool describeOnly = false;
    InterfaceSelection interfaceSelection = {0};

    if (argc == 2 && strcmp(argv[1], "help") == 0) {
        usage(stdout, argv[0]);
        return 0;
    }

    static const struct option longOptions[] = {
        {"help", no_argument, NULL, 'h'},
        {"pid", required_argument, NULL, 'p'},
        {"seconds", required_argument, NULL, 's'},
        {"no-detach", no_argument, NULL, 1000},
        {"display-repl", no_argument, NULL, 1001},
        {"display-command-self-test", no_argument, NULL, 1002},
        {"describe", no_argument, NULL, 1003},
        {"interfaces", required_argument, NULL, 1004},
        {NULL, 0, NULL, 0},
    };

    int option = 0;
    while ((option = getopt_long(argc, argv, "hp:s:", longOptions, NULL)) != -1) {
        switch (option) {
            case 'h':
                usage(stdout, argv[0]);
                return 0;
            case 'p':
                if (!parse_u16(optarg, &forcedPID)) {
                    fprintf(stderr, "Invalid --pid value `%s`; expected a 16-bit integer such as 0x1620.\n", optarg);
                    return 2;
                }
                break;
            case 's':
                if (!parse_nonnegative_int(optarg, &seconds)) {
                    fprintf(stderr, "Invalid --seconds value `%s`; expected a non-negative integer.\n", optarg);
                    return 2;
                }
                break;
            case 1000:
                detachKernelDrivers = false;
                break;
            case 1001:
                displayREPL = true;
                break;
            case 1002:
                displayCommandSelfTest = true;
                break;
            case 1003:
                describeOnly = true;
                break;
            case 1004:
                if (!parse_interface_list(optarg, &interfaceSelection)) {
                    fprintf(stderr, "Invalid --interfaces value `%s`; expected unique interface numbers such as 4 or 4,5.\n", optarg);
                    return 2;
                }
                break;
            default:
                fprintf(stderr, "Run `%s --help` for usage.\n", argv[0]);
                return 2;
        }
    }

    if (optind != argc) {
        fprintf(stderr, "Unexpected positional argument `%s`. Run `%s --help` for usage.\n", argv[optind], argv[0]);
        return 2;
    }
    if (forcedPID != 0 && !is_supported_pid(forcedPID)) {
        fprintf(stderr, "Unsupported --pid 0x%04x. Supported products are 0x1600, 0x1610, 0x1620, and 0x1630.\n", forcedPID);
        return 2;
    }
    if (displayREPL && seconds != 0) {
        fprintf(stderr, "--seconds cannot be combined with --display-repl; leave the REPL with `quit` or Ctrl-C.\n");
        return 2;
    }
    if (describeOnly && (displayREPL || seconds != 0 || interfaceSelection.count != 0)) {
        fprintf(stderr, "--describe cannot be combined with capture or display options. Use only --pid to select the device.\n");
        return 2;
    }
    if (displayREPL && interfaceSelection.count != 0) {
        fprintf(stderr, "--interfaces cannot be combined with --display-repl; the REPL selects its verified display interface.\n");
        return 2;
    }
    if (forcedPID == kMaschineMK3PID && !describeOnly && !displayREPL && interfaceSelection.count == 0) {
        fprintf(stderr, "Refusing to claim every MASCHINE MK3 interface. Pass --interfaces 4 for HID capture or use --describe.\n");
        return 2;
    }
    if (displayCommandSelfTest) {
        return mk2_display_command_self_test();
    }

    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    libusb_context *context = NULL;
    int status = libusb_init(&context);
    if (status != 0) {
        fprintf(stderr, "libusb_init -> %s\n", libusb_error_name(status));
        return 1;
    }
    libusb_set_option(context, LIBUSB_OPTION_LOG_LEVEL, LIBUSB_LOG_LEVEL_INFO);

    libusb_device **devices = NULL;
    ssize_t deviceCount = libusb_get_device_list(context, &devices);
    if (deviceCount < 0) {
        fprintf(stderr, "libusb_get_device_list -> %s\n", libusb_error_name((int)deviceCount));
        libusb_exit(context);
        return 1;
    }

    libusb_device *selected = NULL;
    struct libusb_device_descriptor selectedDescriptor;
    memset(&selectedDescriptor, 0, sizeof(selectedDescriptor));
    for (ssize_t index = 0; index < deviceCount; index++) {
        struct libusb_device_descriptor descriptor;
        status = libusb_get_device_descriptor(devices[index], &descriptor);
        if (status != 0) {
            continue;
        }
        bool pidMatches = forcedPID != 0 ? descriptor.idProduct == forcedPID : is_supported_pid(descriptor.idProduct);
        if (descriptor.idVendor == kVendorNativeInstruments && pidMatches) {
            selected = devices[index];
            selectedDescriptor = descriptor;
            libusb_ref_device(selected);
            break;
        }
    }
    libusb_free_device_list(devices, 1);

    if (selected == NULL) {
        fprintf(stderr, "no supported Native Instruments device found");
        if (forcedPID != 0) {
            fprintf(stderr, " for pid=0x%04x", forcedPID);
        }
        fprintf(stderr, "\n");
        libusb_exit(context);
        return 1;
    }

    libusb_device_handle *handle = NULL;
    status = libusb_open(selected, &handle);
    if (status != 0) {
        fprintf(stderr, "libusb_open vid=0x%04x pid=0x%04x -> %s\n",
                selectedDescriptor.idVendor,
                selectedDescriptor.idProduct,
                libusb_error_name(status));
        libusb_unref_device(selected);
        libusb_exit(context);
        return 1;
    }

    const char *mode = describeOnly ? "describe" : (displayREPL ? "display-repl" : "capture");
    printf("MK2USBSpy pid=0x%04x mode=%s seconds=%d detach=%s\n",
           selectedDescriptor.idProduct,
           mode,
           seconds,
           detachKernelDrivers ? "yes" : "no");

    if (displayREPL) {
        if (selectedDescriptor.idProduct == kMaschineMK3PID) {
            fprintf(stderr, "The display REPL only permits Komplete Kontrol S49/S61/S88 MK2 product IDs.\n");
            libusb_close(handle);
            libusb_unref_device(selected);
            libusb_exit(context);
            return 2;
        }
        int replStatus = mk2_display_command_repl(handle,
                                                  selected,
                                                  detachKernelDrivers,
                                                  &g_shouldStop);
        libusb_close(handle);
        libusb_unref_device(selected);
        libusb_exit(context);
        return replStatus;
    }

    dump_descriptors(selected, handle);
    if (describeOnly) {
        libusb_close(handle);
        libusb_unref_device(selected);
        libusb_exit(context);
        return 0;
    }
    bool claimedInterfaces[256] = {false};
    bool detachedInterfaces[256] = {false};
    status = claim_interfaces(
        handle,
        selected,
        detachKernelDrivers,
        &interfaceSelection,
        claimedInterfaces,
        detachedInterfaces
    );
    if (status != 0) {
        fprintf(stderr, "claim failed -> %s\n", libusb_error_name(status));
        release_claimed_interfaces(handle, selected, claimedInterfaces, detachedInterfaces);
        libusb_close(handle);
        libusb_unref_device(selected);
        libusb_exit(context);
        return 1;
    }

    int watchCount = 0;
    EndpointWatch *watches = start_endpoint_watches(handle, selected, claimedInterfaces, &watchCount);
    if (watches == NULL || watchCount == 0) {
        fprintf(stderr, "no readable IN endpoints found\n");
        free(watches);
        release_claimed_interfaces(handle, selected, claimedInterfaces, detachedInterfaces);
        libusb_close(handle);
        libusb_unref_device(selected);
        libusb_exit(context);
        return 1;
    }

    printf("listening on %d IN endpoints. Press Ctrl-C to stop.\n", watchCount);
    fflush(stdout);

    uint64_t start = now_micros();
    while (!g_shouldStop) {
        if (seconds > 0 && now_micros() - start >= (uint64_t)seconds * 1000000ULL) {
            break;
        }
        struct timeval timeout = {.tv_sec = 0, .tv_usec = 100000};
        status = libusb_handle_events_timeout_completed(context, &timeout, NULL);
        if (status != 0 && status != LIBUSB_ERROR_INTERRUPTED) {
            fprintf(stderr, "libusb_handle_events -> %s\n", libusb_error_name(status));
            break;
        }
    }

    g_shouldStop = 1;
    stop_endpoint_watches(watches, watchCount, context);
    release_claimed_interfaces(handle, selected, claimedInterfaces, detachedInterfaces);
    libusb_close(handle);
    libusb_unref_device(selected);
    libusb_exit(context);
    return 0;
}
