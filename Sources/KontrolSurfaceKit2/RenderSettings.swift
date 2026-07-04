import Foundation

public enum MK2RenderSettings {
    public static let antialiasingEnabledDefaultsKey = "KontrolSurfaceKit2AntialiasingEnabled"
    public static let antialiasingEnvironmentKey = "KONTROL_SURFACE_KIT2_ANTIALIASING"

    /// Global middleware master switch for expensive edge smoothing.
    ///
    /// Defaults to enabled. Disable per process with
    /// `KONTROL_SURFACE_KIT2_ANTIALIASING=0`, or globally for the host app's defaults
    /// domain by setting `KontrolSurfaceKit2AntialiasingEnabled` to `false`.
    public static var antialiasingEnabled: Bool {
        if let defaultValue = UserDefaults.standard.object(forKey: antialiasingEnabledDefaultsKey) as? Bool {
            return defaultValue
        }
        if let environmentValue = ProcessInfo.processInfo.environment[antialiasingEnvironmentKey],
           let parsed = parseBoolean(environmentValue) {
            return parsed
        }
        return true
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on", "enabled":
                true
            case "0", "false", "no", "off", "disabled":
                false
            default:
                nil
        }
    }
}
