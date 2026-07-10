import Foundation
import KompleteKontrol

let usage = "usage: ccd --kk-libusb-daemon [socket-path] | --revision | --version"
if let argument = CommandLine.arguments.dropFirst().first {
    if argument == "-h" || argument == "--help" || argument == "help" {
        print(usage)
        exit(0)
    }
    if argument == "--version" {
        print(KompleteKontrolLibUSBServer.daemonVersion)
        exit(0)
    }
}

if KompleteKontrolLibUSBServer.runIfRequested() {
    exit(0)
}

fputs(usage + "\n", stderr)
exit(2)
