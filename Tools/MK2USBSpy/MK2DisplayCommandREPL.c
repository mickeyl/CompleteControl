#include "MK2DisplayCommandREPL.h"

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

enum {
    kDisplayInterface = 3,
    kDisplayWidth = 480,
    kDisplayHeight = 272,
    kDisplayTimeoutMs = 1000,
    kMaximumTokens = 8,
};

typedef enum {
    DisplayCommandLiteral,
    DisplayCommandRepeatPair,
    DisplayCommandSkipLiteral,
    DisplayCommandSkipRepeatPair,
} DisplayCommandKind;

typedef struct {
    uint8_t *bytes;
    size_t length;
    size_t capacity;
} DisplayPacket;

typedef struct {
    uint8_t screen;
    uint16_t x;
    uint16_t y;
    uint16_t width;
    uint16_t height;
} DisplayRect;

typedef struct {
    libusb_device_handle *handle;
    uint8_t endpoint;
    uint8_t interfaceNumber;
    bool claimed;
    bool detachedKernelDriver;
} DisplayConnection;

static uint64_t now_micros(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (uint64_t)tv.tv_sec * 1000000ULL + (uint64_t)tv.tv_usec;
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

static bool parse_u32(const char *text, uint32_t *valueOut) {
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 0);
    if (errno != 0 || end == text || *end != '\0' || value > UINT32_MAX) {
        return false;
    }
    *valueOut = (uint32_t)value;
    return true;
}

static bool parse_screen(const char *text, uint8_t *screenOut) {
    if (strcmp(text, "left") == 0 || strcmp(text, "0") == 0) {
        *screenOut = 0;
        return true;
    }
    if (strcmp(text, "right") == 0 || strcmp(text, "1") == 0) {
        *screenOut = 1;
        return true;
    }
    return false;
}

static bool parse_color(const char *text, uint16_t *colorOut) {
    static const struct {
        const char *name;
        uint16_t value;
    } colors[] = {
        {"black", 0x0000},
        {"white", 0xffff},
        {"red", 0xf800},
        {"green", 0x07e0},
        {"blue", 0x001f},
        {"yellow", 0xffe0},
        {"cyan", 0x07ff},
        {"magenta", 0xf81f},
        {"orange", 0xfd20},
        {"gray", 0x8410},
        {"dimgray", 0x4208},
    };

    for (size_t index = 0; index < sizeof(colors) / sizeof(colors[0]); index++) {
        if (strcmp(text, colors[index].name) == 0) {
            *colorOut = colors[index].value;
            return true;
        }
    }
    return parse_u16(text, colorOut);
}

static bool packet_append_u8(DisplayPacket *packet, uint8_t value) {
    if (packet->length >= packet->capacity) {
        return false;
    }
    packet->bytes[packet->length++] = value;
    return true;
}

static bool packet_append_be16(DisplayPacket *packet, uint16_t value) {
    return packet_append_u8(packet, (uint8_t)(value >> 8))
        && packet_append_u8(packet, (uint8_t)(value & 0xff));
}

static bool packet_append_token(DisplayPacket *packet, uint8_t opcode, uint32_t pairCount) {
    if (pairCount > 0xffffff) {
        return false;
    }
    return packet_append_u8(packet, opcode)
        && packet_append_u8(packet, (uint8_t)(pairCount >> 16))
        && packet_append_u8(packet, (uint8_t)(pairCount >> 8))
        && packet_append_u8(packet, (uint8_t)pairCount);
}

static bool packet_append_header(DisplayPacket *packet, DisplayRect rect) {
    return packet_append_u8(packet, 0x84)
        && packet_append_u8(packet, 0x00)
        && packet_append_u8(packet, rect.screen)
        && packet_append_u8(packet, 0x60)
        && packet_append_u8(packet, 0x00)
        && packet_append_u8(packet, 0x00)
        && packet_append_u8(packet, 0x00)
        && packet_append_u8(packet, 0x00)
        && packet_append_be16(packet, rect.x)
        && packet_append_be16(packet, rect.y)
        && packet_append_be16(packet, rect.width)
        && packet_append_be16(packet, rect.height);
}

static bool packet_append_footer(DisplayPacket *packet) {
    return packet_append_token(packet, 0x02, 0)
        && packet_append_token(packet, 0x03, 0)
        && packet_append_token(packet, 0x40, 0);
}

static bool valid_rect(DisplayRect rect, uint32_t *pixelCountOut) {
    if (rect.screen > 1 || rect.width == 0 || rect.height == 0
        || rect.x >= kDisplayWidth || rect.y >= kDisplayHeight
        || (uint32_t)rect.x + rect.width > kDisplayWidth
        || (uint32_t)rect.y + rect.height > kDisplayHeight) {
        return false;
    }
    uint32_t pixelCount = (uint32_t)rect.width * rect.height;
    if ((pixelCount % 2) != 0 || pixelCount / 2 > 0xffff) {
        return false;
    }
    *pixelCountOut = pixelCount;
    return true;
}

static DisplayPacket build_packet(DisplayCommandKind kind,
                                  DisplayRect rect,
                                  uint16_t firstColor,
                                  uint16_t secondColor,
                                  uint32_t skipPixels) {
    DisplayPacket packet = {0};
    uint32_t pixelCount = 0;
    bool usesSkip = kind == DisplayCommandSkipLiteral || kind == DisplayCommandSkipRepeatPair;
    bool usesLiteral = kind == DisplayCommandLiteral || kind == DisplayCommandSkipLiteral;
    if (!valid_rect(rect, &pixelCount)
        || (skipPixels % 2) != 0
        || skipPixels >= pixelCount
        || (usesSkip && skipPixels == 0)
        || (!usesSkip && skipPixels != 0)) {
        return packet;
    }

    uint32_t commandPixels = pixelCount - skipPixels;
    size_t commandPayloadBytes = usesLiteral ? (size_t)commandPixels * 2 : 4;
    packet.capacity = 16 + 4 + (usesSkip ? 4 : 0) + 4 + commandPayloadBytes + 12;
    packet.bytes = calloc(packet.capacity, 1);
    if (packet.bytes == NULL) {
        packet.capacity = 0;
        return packet;
    }

    bool success = packet_append_header(&packet, rect)
        && packet_append_token(&packet, 0x02, 0);

    if (success && usesSkip) {
        success = packet_append_token(&packet, 0x02, skipPixels / 2);
    }

    if (success && usesLiteral) {
        success = packet_append_token(&packet, 0x00, commandPixels / 2);
        for (uint32_t index = 0; success && index < commandPixels / 2; index++) {
            success = packet_append_be16(&packet, firstColor)
                && packet_append_be16(&packet, secondColor);
        }
    } else if (success) {
        success = packet_append_token(&packet, 0x01, commandPixels / 2)
            && packet_append_be16(&packet, firstColor)
            && packet_append_be16(&packet, secondColor);
    }

    success = success && packet_append_footer(&packet);
    if (!success) {
        free(packet.bytes);
        memset(&packet, 0, sizeof(packet));
    }
    return packet;
}

static void free_packet(DisplayPacket *packet) {
    free(packet->bytes);
    memset(packet, 0, sizeof(*packet));
}

static const char *command_name(DisplayCommandKind kind) {
    switch (kind) {
        case DisplayCommandLiteral: return "literal (verified baseline)";
        case DisplayCommandRepeatPair: return "repeat-pair 0x01 (experimental)";
        case DisplayCommandSkipLiteral: return "skip 0x02 + literal 0x00 (experimental)";
        case DisplayCommandSkipRepeatPair: return "skip 0x02 + repeat-pair 0x01 (experimental)";
    }
    return "unknown";
}

static int send_command(DisplayConnection *connection,
                        DisplayCommandKind kind,
                        DisplayRect rect,
                        uint16_t firstColor,
                        uint16_t secondColor,
                        uint32_t skipPixels) {
    DisplayPacket packet = build_packet(kind, rect, firstColor, secondColor, skipPixels);
    if (packet.bytes == NULL) {
        fprintf(stderr, "Couldn't construct the display packet. Check the rectangle and even-pixel constraints.\n");
        return LIBUSB_ERROR_INVALID_PARAM;
    }

    int transferred = 0;
    uint64_t start = now_micros();
    int status = libusb_bulk_transfer(connection->handle,
                                      connection->endpoint,
                                      packet.bytes,
                                      (int)packet.length,
                                      &transferred,
                                      kDisplayTimeoutMs);
    double elapsedMs = (double)(now_micros() - start) / 1000.0;

    printf("display-write screen=%s rect=%u,%u %ux%u command=%s skip=%u packet=%zu transferred=%d elapsed=%.3fms status=%s\n",
           rect.screen == 0 ? "left" : "right",
           rect.x,
           rect.y,
           rect.width,
           rect.height,
           command_name(kind),
           skipPixels,
           packet.length,
           transferred,
           elapsedMs,
           libusb_error_name(status));
    fflush(stdout);

    if (status == 0 && transferred != (int)packet.length) {
        fprintf(stderr, "Short display write: expected %zu bytes but transferred %d. Stop testing and reconnect the device.\n",
                packet.length,
                transferred);
        status = LIBUSB_ERROR_IO;
    }
    free_packet(&packet);
    return status;
}

static int find_display_endpoint(libusb_device *device, uint8_t *endpointOut) {
    struct libusb_config_descriptor *config = NULL;
    int status = libusb_get_active_config_descriptor(device, &config);
    if (status != 0) {
        return status;
    }

    status = LIBUSB_ERROR_NOT_FOUND;
    for (uint8_t interfaceIndex = 0; interfaceIndex < config->bNumInterfaces; interfaceIndex++) {
        const struct libusb_interface *interface = &config->interface[interfaceIndex];
        for (int altIndex = 0; altIndex < interface->num_altsetting; altIndex++) {
            const struct libusb_interface_descriptor *alt = &interface->altsetting[altIndex];
            if (alt->bInterfaceNumber != kDisplayInterface || alt->bAlternateSetting != 0) {
                continue;
            }
            for (uint8_t endpointIndex = 0; endpointIndex < alt->bNumEndpoints; endpointIndex++) {
                const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[endpointIndex];
                bool isBulk = (endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) == LIBUSB_TRANSFER_TYPE_BULK;
                bool isOutput = (endpoint->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK) == LIBUSB_ENDPOINT_OUT;
                if (isBulk && isOutput) {
                    *endpointOut = endpoint->bEndpointAddress;
                    status = 0;
                    goto done;
                }
            }
        }
    }

done:
    libusb_free_config_descriptor(config);
    return status;
}

static int open_display_connection(DisplayConnection *connection,
                                   libusb_device_handle *handle,
                                   libusb_device *device,
                                   bool detachKernelDriver) {
    memset(connection, 0, sizeof(*connection));
    connection->handle = handle;
    connection->interfaceNumber = kDisplayInterface;

    int status = find_display_endpoint(device, &connection->endpoint);
    if (status != 0) {
        fprintf(stderr, "No bulk OUT endpoint found on MK2 display interface %u.\n", kDisplayInterface);
        return status;
    }

    if (detachKernelDriver) {
        int active = libusb_kernel_driver_active(handle, connection->interfaceNumber);
        if (active == 1) {
            status = libusb_detach_kernel_driver(handle, connection->interfaceNumber);
            if (status != 0) {
                fprintf(stderr, "Can't detach the kernel driver from display interface %u: %s\n",
                        connection->interfaceNumber,
                        libusb_error_name(status));
                return status;
            }
            connection->detachedKernelDriver = true;
        }
    }

    status = libusb_claim_interface(handle, connection->interfaceNumber);
    if (status != 0) {
        fprintf(stderr,
                "Can't claim MK2 display interface %u: %s\n"
                "The CompleteControl daemon or another NI process may own it. Run `make mk2-usb-spy-display-repl`.\n",
                connection->interfaceNumber,
                libusb_error_name(status));
        if (connection->detachedKernelDriver) {
            int attachStatus = libusb_attach_kernel_driver(handle, connection->interfaceNumber);
            if (attachStatus != 0 && attachStatus != LIBUSB_ERROR_NOT_SUPPORTED) {
                fprintf(stderr, "Couldn't restore the kernel driver after the failed claim: %s\n",
                        libusb_error_name(attachStatus));
            }
            connection->detachedKernelDriver = false;
        }
        return status;
    }
    connection->claimed = true;
    return 0;
}

static void close_display_connection(DisplayConnection *connection) {
    if (connection->claimed) {
        int status = libusb_release_interface(connection->handle, connection->interfaceNumber);
        if (status != 0) {
            fprintf(stderr, "Couldn't release display interface %u: %s\n",
                    connection->interfaceNumber,
                    libusb_error_name(status));
        }
    }
    if (connection->detachedKernelDriver) {
        int status = libusb_attach_kernel_driver(connection->handle, connection->interfaceNumber);
        if (status != 0 && status != LIBUSB_ERROR_NOT_SUPPORTED) {
            fprintf(stderr, "Couldn't reattach the kernel driver to display interface %u: %s\n",
                    connection->interfaceNumber,
                    libusb_error_name(status));
        }
    }
    memset(connection, 0, sizeof(*connection));
}

static void print_repl_help(void) {
    fprintf(stderr,
            "Commands:\n"
            "  status                              Show the selected screen and rectangle.\n"
            "  screen <left|right|0|1>             Select a display.\n"
            "  rect <x> <y> <width> <height>       Select a safe test rectangle.\n"
            "  literal <color-a> [color-b]         Send verified 0x00 literal pixels.\n"
            "  repeat <color-a> [color-b]          Test experimental 0x01 pair repeat.\n"
            "  skip-literal <pixels> <a> [b]       Test 0x02 skip, then verified literal pixels.\n"
            "  skip-repeat <pixels> <a> [b]        Preserve an even prefix, repeat over the rest.\n"
            "  clear-rect [color]                  Clear the selected rectangle via literal pixels.\n"
            "  clear-screen [color]                Clear the selected screen via literal pixels.\n"
            "  colors                              List named RGB565 colors.\n"
            "  help                                Show this command list.\n"
            "  quit                                Release USB and exit.\n"
            "\n"
            "Colors may be names or 16-bit values such as 0xf800. The rectangle must\n"
            "contain an even number of pixels. `repeat`, `skip-literal`, and\n"
            "`skip-repeat` are unverified protocol experiments; use a small rectangle first.\n"
            "\n"
            "Recommended hardware test (default 64x32 rectangle):\n"
            "  literal blue                    Baseline: the complete rectangle becomes blue.\n"
            "  repeat red                      0x01: the complete rectangle should become red.\n"
            "  literal blue                    Restore the blue baseline.\n"
            "  skip-literal 1024 yellow        0x02: top 16 rows stay blue, bottom 16 turn yellow.\n"
            "  skip-repeat 1024 green          Combined: top half stays unchanged, bottom turns green.\n"
            "  clear-rect black                Restore the test area.\n"
            "  quit                            Release USB and exit.\n"
            "\n"
            "A successful USB status is not visual proof; record what the display actually shows.\n");
}

static void print_status(DisplayConnection *connection, DisplayRect rect) {
    fprintf(stderr,
            "USB interface=%u endpoint=0x%02x screen=%s rect=%u,%u %ux%u pixels=%u\n",
            connection->interfaceNumber,
            connection->endpoint,
            rect.screen == 0 ? "left" : "right",
            rect.x,
            rect.y,
            rect.width,
            rect.height,
            (unsigned int)rect.width * rect.height);
}

static int tokenize(char *line, char **tokens, int capacity) {
    int count = 0;
    char *save = NULL;
    for (char *token = strtok_r(line, " \t\r\n", &save);
         token != NULL && count < capacity;
         token = strtok_r(NULL, " \t\r\n", &save)) {
        tokens[count++] = token;
    }
    return count;
}

static bool parse_command_colors(char **tokens,
                                 int tokenCount,
                                 int firstIndex,
                                 uint16_t *firstColorOut,
                                 uint16_t *secondColorOut) {
    if (tokenCount <= firstIndex || tokenCount > firstIndex + 2
        || !parse_color(tokens[firstIndex], firstColorOut)) {
        return false;
    }
    *secondColorOut = *firstColorOut;
    if (tokenCount == firstIndex + 2 && !parse_color(tokens[firstIndex + 1], secondColorOut)) {
        return false;
    }
    return true;
}

static int run_repl(DisplayConnection *connection, volatile sig_atomic_t *shouldStop) {
    DisplayRect rect = {.screen = 0, .x = 16, .y = 16, .width = 64, .height = 32};
    char *line = NULL;
    size_t lineCapacity = 0;
    int exitStatus = 0;

    fprintf(stderr,
            "MK2 display-command verification REPL\n"
            "No display data has been sent. The default test area is a 64x32 rectangle.\n"
            "Type `help` for commands and start with `literal dimgray`.\n");
    print_status(connection, rect);

    while (!*shouldStop) {
        fprintf(stderr, "mk2-display> ");
        fflush(stderr);
        errno = 0;
        ssize_t length = getline(&line, &lineCapacity, stdin);
        if (length < 0) {
            if (*shouldStop || errno == EINTR) {
                fprintf(stderr, "Stopping and releasing the display interface.\n");
            } else if (!feof(stdin)) {
                fprintf(stderr, "Couldn't read the next command: %s\n", strerror(errno));
                exitStatus = 1;
            }
            break;
        }

        char *tokens[kMaximumTokens] = {0};
        int tokenCount = tokenize(line, tokens, kMaximumTokens);
        if (tokenCount == 0) {
            continue;
        }

        const char *command = tokens[0];
        if (strcmp(command, "quit") == 0 || strcmp(command, "exit") == 0) {
            break;
        }
        if (strcmp(command, "help") == 0) {
            print_repl_help();
            continue;
        }
        if (strcmp(command, "status") == 0) {
            print_status(connection, rect);
            continue;
        }
        if (strcmp(command, "colors") == 0) {
            fprintf(stderr, "black white red green blue yellow cyan magenta orange gray dimgray\n");
            continue;
        }
        if (strcmp(command, "screen") == 0) {
            uint8_t screen = 0;
            if (tokenCount != 2 || !parse_screen(tokens[1], &screen)) {
                fprintf(stderr, "Usage: screen <left|right|0|1>\n");
                continue;
            }
            rect.screen = screen;
            print_status(connection, rect);
            continue;
        }
        if (strcmp(command, "rect") == 0) {
            DisplayRect candidate = rect;
            uint32_t pixelCount = 0;
            if (tokenCount != 5
                || !parse_u16(tokens[1], &candidate.x)
                || !parse_u16(tokens[2], &candidate.y)
                || !parse_u16(tokens[3], &candidate.width)
                || !parse_u16(tokens[4], &candidate.height)
                || !valid_rect(candidate, &pixelCount)) {
                fprintf(stderr,
                        "Usage: rect <x> <y> <width> <height> — bounds are 480x272 and pixel count must be even.\n");
                continue;
            }
            rect = candidate;
            print_status(connection, rect);
            continue;
        }

        if (strcmp(command, "clear-rect") == 0 || strcmp(command, "clear-screen") == 0) {
            uint16_t color = 0;
            if (tokenCount > 2 || (tokenCount == 2 && !parse_color(tokens[1], &color))) {
                fprintf(stderr, "Usage: %s [color]\n", command);
                continue;
            }
            DisplayRect target = rect;
            if (strcmp(command, "clear-screen") == 0) {
                target.x = 0;
                target.y = 0;
                target.width = kDisplayWidth;
                target.height = kDisplayHeight;
            }
            int status = send_command(connection, DisplayCommandLiteral, target, color, color, 0);
            if (status != 0) {
                fprintf(stderr, "Display write failed. Stop if the next literal baseline also fails.\n");
            }
            continue;
        }

        if (strcmp(command, "literal") == 0 || strcmp(command, "repeat") == 0) {
            uint16_t firstColor = 0;
            uint16_t secondColor = 0;
            if (!parse_command_colors(tokens, tokenCount, 1, &firstColor, &secondColor)) {
                fprintf(stderr, "Usage: %s <color-a> [color-b]\n", command);
                continue;
            }
            DisplayCommandKind kind = strcmp(command, "literal") == 0
                ? DisplayCommandLiteral
                : DisplayCommandRepeatPair;
            int status = send_command(connection, kind, rect, firstColor, secondColor, 0);
            if (status != 0) {
                fprintf(stderr, "Display write failed. Return to `literal dimgray` or quit before further experiments.\n");
            }
            continue;
        }

        if (strcmp(command, "skip-literal") == 0 || strcmp(command, "skip-repeat") == 0) {
            uint32_t skipPixels = 0;
            uint16_t firstColor = 0;
            uint16_t secondColor = 0;
            uint32_t pixelCount = (uint32_t)rect.width * rect.height;
            if (tokenCount < 3 || tokenCount > 4
                || !parse_u32(tokens[1], &skipPixels)
                || (skipPixels % 2) != 0
                || skipPixels == 0
                || skipPixels >= pixelCount
                || !parse_command_colors(tokens, tokenCount, 2, &firstColor, &secondColor)) {
                fprintf(stderr,
                        "Usage: %s <nonzero-even-pixels-less-than-%u> <color-a> [color-b]\n",
                        command,
                        pixelCount);
                continue;
            }
            DisplayCommandKind kind = strcmp(command, "skip-literal") == 0
                ? DisplayCommandSkipLiteral
                : DisplayCommandSkipRepeatPair;
            int status = send_command(connection,
                                      kind,
                                      rect,
                                      firstColor,
                                      secondColor,
                                      skipPixels);
            if (status != 0) {
                fprintf(stderr, "Display write failed. Return to `literal dimgray` or quit before further experiments.\n");
            }
            continue;
        }

        fprintf(stderr, "Unknown command `%s`. Type `help` for the available commands.\n", command);
    }

    free(line);
    return exitStatus;
}

int mk2_display_command_repl(libusb_device_handle *handle,
                             libusb_device *device,
                             bool detachKernelDriver,
                             volatile sig_atomic_t *shouldStop) {
    if (!isatty(STDIN_FILENO)) {
        fprintf(stderr, "The display REPL requires an interactive terminal on stdin.\n");
        return 2;
    }

    DisplayConnection connection;
    int status = open_display_connection(&connection, handle, device, detachKernelDriver);
    if (status != 0) {
        return 1;
    }
    int replStatus = run_repl(&connection, shouldStop);
    close_display_connection(&connection);
    return replStatus;
}

static bool bytes_equal(const uint8_t *actual, const uint8_t *expected, size_t length) {
    return memcmp(actual, expected, length) == 0;
}

int mk2_display_command_self_test(void) {
    DisplayRect rect = {.screen = 1, .x = 2, .y = 3, .width = 2, .height = 1};
    DisplayPacket literal = build_packet(DisplayCommandLiteral, rect, 0xf800, 0x001f, 0);
    const uint8_t expectedLiteral[] = {
        0x84, 0x00, 0x01, 0x60, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x02, 0x00, 0x03, 0x00, 0x02, 0x00, 0x01,
        0x02, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x01, 0xf8, 0x00, 0x00, 0x1f,
        0x02, 0x00, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x00,
    };
    bool literalOK = literal.bytes != NULL
        && literal.length == sizeof(expectedLiteral)
        && bytes_equal(literal.bytes, expectedLiteral, sizeof(expectedLiteral));
    free_packet(&literal);

    DisplayPacket repeat = build_packet(DisplayCommandRepeatPair, rect, 0xf800, 0x001f, 0);
    const uint8_t expectedRepeatToken[] = {0x01, 0x00, 0x00, 0x01, 0xf8, 0x00, 0x00, 0x1f};
    bool repeatOK = repeat.bytes != NULL
        && repeat.length == 40
        && bytes_equal(repeat.bytes + 20, expectedRepeatToken, sizeof(expectedRepeatToken));
    free_packet(&repeat);

    DisplayRect skipRect = {.screen = 0, .x = 0, .y = 0, .width = 4, .height = 1};
    DisplayPacket skip = build_packet(DisplayCommandSkipLiteral, skipRect, 0x07e0, 0x001f, 2);
    const uint8_t expectedSkipToken[] = {0x02, 0x00, 0x00, 0x01};
    const uint8_t expectedSkipLiteral[] = {
        0x00, 0x00, 0x00, 0x01, 0x07, 0xe0, 0x00, 0x1f,
    };
    bool skipOK = skip.bytes != NULL
        && skip.length == 44
        && bytes_equal(skip.bytes + 20, expectedSkipToken, sizeof(expectedSkipToken))
        && bytes_equal(skip.bytes + 24, expectedSkipLiteral, sizeof(expectedSkipLiteral));
    free_packet(&skip);

    DisplayPacket combined = build_packet(DisplayCommandSkipRepeatPair, skipRect, 0x07e0, 0x001f, 2);
    const uint8_t expectedRepeatAfterSkip[] = {
        0x01, 0x00, 0x00, 0x01, 0x07, 0xe0, 0x00, 0x1f,
    };
    bool combinedOK = combined.bytes != NULL
        && combined.length == 44
        && bytes_equal(combined.bytes + 20, expectedSkipToken, sizeof(expectedSkipToken))
        && bytes_equal(combined.bytes + 24, expectedRepeatAfterSkip, sizeof(expectedRepeatAfterSkip));
    free_packet(&combined);

    DisplayRect full = {.screen = 0, .x = 0, .y = 0, .width = 480, .height = 272};
    DisplayPacket fullRepeat = build_packet(DisplayCommandRepeatPair, full, 0, 0, 0);
    bool fullOK = fullRepeat.bytes != NULL
        && fullRepeat.length == 40
        && fullRepeat.bytes[22] == 0xff
        && fullRepeat.bytes[23] == 0x00;
    free_packet(&fullRepeat);

    if (!literalOK || !repeatOK || !skipOK || !combinedOK || !fullOK) {
        fprintf(stderr,
                "Display command self-test failed: literal=%s repeat=%s skip=%s combined=%s full=%s\n",
                literalOK ? "ok" : "failed",
                repeatOK ? "ok" : "failed",
                skipOK ? "ok" : "failed",
                combinedOK ? "ok" : "failed",
                fullOK ? "ok" : "failed");
        return 1;
    }

    printf("MK2 display command packet self-test passed.\n");
    return 0;
}
