import AppKit

enum DisplayTheme: String {
    case system, light, dark
}

var displayTheme: DisplayTheme {
    DisplayTheme(rawValue: UserDefaults.standard.string(forKey: "displayTheme") ?? "system") ?? .system
}
var configuredAppearance: NSAppearance? {
    switch displayTheme {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
}

// A missing preference is a first launch, which defaults to English.
var usesEnglish: Bool { UserDefaults.standard.string(forKey: "displayLanguage") ?? "en" == "en" }
func tr(_ chinese: String, _ english: String) -> String { usesEnglish ? english : chinese }
var displayTimeZone: TimeZone {
    UserDefaults.standard.string(forKey: "displayTimeZone").flatMap(TimeZone.init(identifier:)) ?? .current
}
func displayFormatter(_ pattern: String, zone: TimeZone = displayTimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: usesEnglish ? "en_US_POSIX" : "zh_CN")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = zone
    formatter.dateFormat = pattern
    return formatter
}
