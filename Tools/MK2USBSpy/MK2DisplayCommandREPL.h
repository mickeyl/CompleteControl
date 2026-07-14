#ifndef MK2_DISPLAY_COMMAND_REPL_H
#define MK2_DISPLAY_COMMAND_REPL_H

#include <signal.h>
#include <stdbool.h>

#include <libusb.h>

int mk2_display_command_repl(libusb_device_handle *handle,
                             libusb_device *device,
                             bool detachKernelDriver,
                             volatile sig_atomic_t *shouldStop);

int mk2_display_command_self_test(void);

#endif
