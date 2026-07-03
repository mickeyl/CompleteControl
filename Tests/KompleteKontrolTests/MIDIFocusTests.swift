import Testing
import KompleteKontrol
@testable import KontrolSurfaceKit2

@Suite("MIDI focus")
struct MIDIFocusTests {
    @Test("MIDIFocus stores an id and receives MIDI events")
    func receivesEvents() {
        let box = MIDIEventBox()
        let focus = MIDIFocus("tracker.channel.3") { event in
            box.append(event)
        }
        let event = KKMIDIEvent(kind: .noteOn, channel: 0, note: 60, velocity: 100)

        focus.receive(event)

        #expect(focus.id == "tracker.channel.3")
        #expect(box.events == [event])
    }

    @Test("Input bindings can carry the active MIDI focus")
    func bindingStoresFocus() {
        var bindings = MK2InputBindings2()
        bindings.midiFocus = MIDIFocus("tracker.channel.1") { _ in }

        #expect(bindings.midiFocus?.id == "tracker.channel.1")
    }
}

private final class MIDIEventBox: @unchecked Sendable {
    private var storage: [KKMIDIEvent] = []

    var events: [KKMIDIEvent] {
        storage
    }

    func append(_ event: KKMIDIEvent) {
        storage.append(event)
    }
}
