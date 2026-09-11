import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case french = "fr"

    var id: String { rawValue }

    var flag: String {
        switch self {
        case .english: "🇬🇧"
        case .french: "🇫🇷"
        }
    }

    var accessibilityName: String {
        switch self {
        case .english: "English"
        case .french: "Français"
        }
    }
}

enum LocalizationManager {
    static let storageKey = "AppSelectedLanguage"

    static var language: AppLanguage {
        get {
            AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .english
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    let language = LocalizationManager.language
    guard let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
          let bundle = Bundle(path: path) else {
        return key
    }

    let format = bundle.localizedString(forKey: key, value: key, table: nil)
    guard !arguments.isEmpty else { return format }
    return String(
        format: format,
        locale: Locale(identifier: language.rawValue),
        arguments: arguments
    )
}
