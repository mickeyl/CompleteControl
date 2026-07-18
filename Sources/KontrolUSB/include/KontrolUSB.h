#ifndef KONTROL_USB_H
#define KONTROL_USB_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int32_t status;
    uint8_t opened;
    uint8_t pipeRef;
    uint8_t endpointAddress;
    uint8_t numEndpoints;
    uint32_t transferredBytes;
    char message[2048];
} KontrolUSBResult;

typedef void *KontrolUSBLibUSBSessionRef;

/* Persistent MK2 session API. */
KontrolUSBResult KontrolUSBLibUSBSessionOpen(KontrolUSBLibUSBSessionRef *sessionOut);
KontrolUSBResult KontrolUSBLibUSBSessionOpenForProduct(uint16_t productID, KontrolUSBLibUSBSessionRef *sessionOut);
uint16_t KontrolUSBLibUSBSessionProductID(KontrolUSBLibUSBSessionRef session);
uint8_t KontrolUSBLibUSBSessionKeyCount(KontrolUSBLibUSBSessionRef session);
/* Raw bcdDevice from the USB device descriptor. This is the same field Native
 * Instruments' own firmware updater reads (via IOUSBDeviceInterface's
 * GetDeviceReleaseNumber) to show a "major.minor.patch" version string, so no
 * vendor-specific query is needed to reproduce it. */
uint16_t KontrolUSBLibUSBSessionFirmwareVersion(KontrolUSBLibUSBSessionRef session);
KontrolUSBResult KontrolUSBLibUSBSessionStatus(KontrolUSBLibUSBSessionRef session);
KontrolUSBResult KontrolUSBLibUSBSessionHealth(KontrolUSBLibUSBSessionRef session);
int KontrolUSBLibUSBSessionDeviceLost(KontrolUSBLibUSBSessionRef session);
KontrolUSBResult KontrolUSBLibUSBSessionWrite(KontrolUSBLibUSBSessionRef session, uint8_t reportID, const uint8_t *payload, uint32_t payloadLen);
KontrolUSBResult KontrolUSBLibUSBSessionWriteMK2Display(KontrolUSBLibUSBSessionRef session, uint8_t screen, uint16_t x, uint16_t y, uint16_t width, uint16_t height, const uint16_t *pixelsRGB565, uint32_t pixelCount, uint32_t timeoutMs);
KontrolUSBResult KontrolUSBLibUSBSessionWriteMK2DisplayBytes(KontrolUSBLibUSBSessionRef session, uint8_t screen, uint16_t x, uint16_t y, uint16_t width, uint16_t height, const uint8_t *pixelsRGB565BE, uint32_t byteCount, uint32_t timeoutMs);
KontrolUSBResult KontrolUSBLibUSBSessionWriteMK2DisplayPacket(KontrolUSBLibUSBSessionRef session, const uint8_t *packet, uint32_t byteCount, uint32_t timeoutMs);
KontrolUSBResult KontrolUSBLibUSBSessionFillMK2Display(KontrolUSBLibUSBSessionRef session, uint8_t screen, uint16_t x, uint16_t y, uint16_t width, uint16_t height, uint16_t rgb565, uint32_t timeoutMs);
KontrolUSBResult KontrolUSBLibUSBSessionRead(KontrolUSBLibUSBSessionRef session, uint8_t *buffer, uint32_t bufferLen, uint32_t *transferredOut, uint32_t timeoutMs);
KontrolUSBResult KontrolUSBLibUSBSessionReadMIDI(KontrolUSBLibUSBSessionRef session, uint8_t *buffer, uint32_t bufferLen, uint32_t *transferredOut, uint32_t timeoutMs);
void KontrolUSBLibUSBSessionClose(KontrolUSBLibUSBSessionRef session);
/* Async API — enables kqueue/select integration. */

/* Get pollable file descriptors for libusb event handling.
 * Returns up to maxFds pollfd structs. Caller uses these with kqueue/select.
 * Returns the number of fds filled, or -1 on error. */
typedef struct {
    int fd;
    uint16_t events;  /* POLLIN / POLLOUT bits */
} KontrolUSBPollFd;

int KontrolUSBLibUSBSessionGetPollFds(KontrolUSBLibUSBSessionRef session,
                                       KontrolUSBPollFd *outFds, int maxFds);

/* Process pending libusb events (call after kqueue/select reports activity
 * on one of the poll fds). timeoutMs=0 means non-blocking. */
void KontrolUSBLibUSBHandleEventsTimeout(KontrolUSBLibUSBSessionRef session,
                                          int timeoutMs);

/* Start async interrupt-IN transfer. Data will arrive via the callback
 * registered with KontrolUSBLibUSBSessionSetInputCallback.
 * Returns 0 on success. */
typedef void (*KontrolUSBInputCallback)(const uint8_t *data, uint32_t length, void *userData);

int KontrolUSBLibUSBSessionStartAsyncInput(KontrolUSBLibUSBSessionRef session,
                                            KontrolUSBInputCallback callback,
                                            void *userData);

/* Start async MIDI-IN transfer. */
int KontrolUSBLibUSBSessionStartAsyncMIDI(KontrolUSBLibUSBSessionRef session,
                                           KontrolUSBInputCallback callback,
                                           void *userData);

/* Cancel synchronous output transfers currently waiting for completion. Returns the
 * number of cancellation requests accepted by libusb. Used before session teardown so
 * a vanished device cannot leave close/reconnect waiting behind a blocked writer. */
int KontrolUSBLibUSBSessionCancelPendingOutput(KontrolUSBLibUSBSessionRef session);

/* Cancel async transfers (e.g. before close). */
void KontrolUSBLibUSBSessionStopAsync(KontrolUSBLibUSBSessionRef session);

#ifdef __cplusplus
}
#endif

#endif
