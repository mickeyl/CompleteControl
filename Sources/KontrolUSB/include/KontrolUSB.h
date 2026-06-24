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
    char message[512];
} KontrolUSBResult;

typedef void *KontrolUSBLibUSBSessionRef;

KontrolUSBResult KontrolUSBWriteReport(uint8_t reportID, const uint8_t *payload, uint32_t payloadLen);
KontrolUSBResult KontrolUSBRunDemo(void);
KontrolUSBResult KontrolUSBLibUSBWriteReport(uint8_t reportID, const uint8_t *payload, uint32_t payloadLen);
KontrolUSBResult KontrolUSBLibUSBSessionOpen(KontrolUSBLibUSBSessionRef *sessionOut);
KontrolUSBResult KontrolUSBLibUSBSessionStatus(KontrolUSBLibUSBSessionRef session);
KontrolUSBResult KontrolUSBLibUSBSessionWrite(KontrolUSBLibUSBSessionRef session, uint8_t reportID, const uint8_t *payload, uint32_t payloadLen);
KontrolUSBResult KontrolUSBLibUSBSessionRead(KontrolUSBLibUSBSessionRef session, uint8_t *buffer, uint32_t bufferLen, uint32_t *transferredOut, uint32_t timeoutMs);
KontrolUSBResult KontrolUSBLibUSBSessionReadMIDI(KontrolUSBLibUSBSessionRef session, uint8_t *buffer, uint32_t bufferLen, uint32_t *transferredOut, uint32_t timeoutMs);
void KontrolUSBLibUSBSessionClose(KontrolUSBLibUSBSessionRef session);
KontrolUSBResult KontrolUSBLibUSBRunDemo(void);
KontrolUSBResult KontrolUSBLibUSBRunHoldDemo(uint32_t steps, uint32_t intervalUsec);

#ifdef __cplusplus
}
#endif

#endif
