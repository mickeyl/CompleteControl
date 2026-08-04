import Testing
@testable import KompleteKontrol

@Suite("Daemon invocation parsing")
struct DaemonInvocationTests {
    typealias Invocation = KompleteKontrolLibUSBServer.DaemonInvocation

    @Test("bare invocation keeps the stock socket and no product binding")
    func bareInvocation() {
        let outcome = Invocation.parse(argumentsAfterFlag: [])
        #expect(outcome == .success(Invocation(
            socketPath: KompleteKontrolLibUSBServer.defaultDaemonSocketPath,
            product: nil
        )))
    }

    @Test("positional socket path is honored")
    func positionalSocket() {
        let outcome = Invocation.parse(argumentsAfterFlag: ["/tmp/test.sock"])
        #expect(outcome == .success(Invocation(socketPath: "/tmp/test.sock", product: nil)))
    }

    @Test("socket plus product binds the daemon to one family")
    func socketAndProduct() {
        let outcome = Invocation.parse(argumentsAfterFlag: ["/var/run/kompletekontrol-maschine.sock", "--product", "maschine-mk3"])
        #expect(outcome == .success(Invocation(
            socketPath: "/var/run/kompletekontrol-maschine.sock",
            product: .maschineMK3
        )))
    }

    @Test("product before the socket parses identically")
    func productBeforeSocket() {
        let outcome = Invocation.parse(argumentsAfterFlag: ["--product", "kontrol-mk2", "/tmp/kk.sock"])
        #expect(outcome == .success(Invocation(socketPath: "/tmp/kk.sock", product: .kompleteKontrolMK2)))
    }

    @Test("unknown product is a hard error, never a silent any-device open")
    func unknownProductFails() {
        let outcome = Invocation.parse(argumentsAfterFlag: ["--product", "maschine-studio"])
        guard case .failure = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
    }

    @Test("missing product value is a hard error")
    func missingProductValueFails() {
        let outcome = Invocation.parse(argumentsAfterFlag: ["/tmp/test.sock", "--product"])
        guard case .failure = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
    }

    @Test("unknown options are rejected instead of being read as socket paths")
    func unknownOptionFails() {
        let outcome = Invocation.parse(argumentsAfterFlag: ["--frobnicate"])
        guard case .failure = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
    }

    @Test("family CLI aliases resolve to their family")
    func familyAliases() {
        #expect(KontrolDeviceFamily(cliToken: "kontrol-mk2") == .kompleteKontrolMK2)
        #expect(KontrolDeviceFamily(cliToken: "komplete-kontrol-mk2") == .kompleteKontrolMK2)
        #expect(KontrolDeviceFamily(cliToken: "MK2") == .kompleteKontrolMK2)
        #expect(KontrolDeviceFamily(cliToken: "kontrol") == .kompleteKontrolMK2)
        #expect(KontrolDeviceFamily(cliToken: "maschine-mk3") == .maschineMK3)
        #expect(KontrolDeviceFamily(cliToken: "maschine") == .maschineMK3)
        #expect(KontrolDeviceFamily(cliToken: "mk3") == .maschineMK3)
        #expect(KontrolDeviceFamily(cliToken: "maschine-studio") == nil)
    }

    @Test("family product IDs match the KontrolUSB device table")
    func familyProductIDs() {
        #expect(KontrolDeviceFamily.kompleteKontrolMK2.productIDs == [0x1610, 0x1620, 0x1630])
        #expect(KontrolDeviceFamily.maschineMK3.productIDs == [0x1600])
        for family in KontrolDeviceFamily.allCases {
            for productID in family.productIDs {
                #expect(KontrolDeviceProfile.productID(productID)?.family == family)
            }
        }
    }
}
