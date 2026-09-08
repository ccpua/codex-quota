import Foundation

var usesEnglish: Bool { UserDefaults.standard.string(forKey: "displayLanguage") == "en" }
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
