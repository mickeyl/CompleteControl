import Foundation

/// Stable exit-code contract for automation scripts (documented in
/// Docs/automation-testing.md). Values never change meaning between releases.
enum HostExitCode: Int32 {
    case ok = 0
    case usage = 64
    case instanceBusy = 69
    case deviceSocketBindFailure = 71
    case daemonStartFailure = 72
    case daemonExitedUnexpectedly = 73
}

func exitHost(_ code: HostExitCode) -> Never {
    exit(code.rawValue)
}
