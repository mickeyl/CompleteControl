import Foundation
import KompleteKontrol

if KompleteKontrolLibUSBServer.runIfRequested() {
    exit(0)
}

fputs("usage: ccd --kk-libusb-daemon [socket-path] | --revision\n", stderr)
exit(2)
