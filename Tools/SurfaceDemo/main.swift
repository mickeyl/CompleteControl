import Foundation
import KompleteKontrol
import KontrolSurfaceKit

// A declarative screen: long labels scroll automatically; display 0 carries the
// global status and page indicator.
struct ParameterScreen: Screen {
    func render(on surface: isolated Surface) {
        surface.setStatus("KONTROL SURFACE KIT DEMO")
        surface.setPage(1, of: 4)

        surface.setText(1, 1, "CUTOFF")
        surface.setBar(0.42, lcd: 1)

        surface.setText(2, 1, "RESONANCE BANDPASS 24DB", overflow: .marquee(speed: 5))
        surface.setBar(0.66, lcd: 2)

        surface.setText(3, 1, "REVERB", overflow: .clip)
        surface.setText(3, 2, "LARGE HALL DECAY", overflow: .marquee(style: .pingPong))
    }
}

let device = KompleteKontrolS25MK1()
let surface = Surface(device: device)

print("KontrolSurfaceKit demo — long labels scroll as marquees. Ctrl-C to quit.")

// Clean shutdown: blank the displays before exiting.
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    Task {
        await surface.stop()
        exit(0)
    }
}
interrupt.resume()
signal(SIGINT, SIG_IGN)

Task {
    await surface.start()
    await surface.present(ParameterScreen())

    // Imperative path: a live value reconciled every tick on display 4.
    var value = 0.0
    while true {
        try? await Task.sleep(for: .milliseconds(40))
        value += 0.01
        if value > 1 { value = 0 }
        await surface.setBar(value, lcd: 4)
        await surface.setText(4, 1, "LEVEL")
        await surface.setText(4, 2, String(format: "%3d%%", Int(value * 100)), overflow: .clip)
    }
}

dispatchMain()
