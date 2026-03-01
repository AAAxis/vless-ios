import Foundation

/// Shared config store for main app and packet tunnel (same pattern as dopplerswift).
/// Uses App Group so the tunnel extension can read xray JSON when needed.
enum ConfigStore {

    private static let appGroupID = "group.com.theholylabs.foxywall"

    private enum Key {
        static let xrayConfigJSON = "xray_config_json"
    }

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func saveXrayConfig(_ json: String) {
        sharedDefaults?.set(json, forKey: Key.xrayConfigJSON)
    }

    static func loadXrayConfig() -> String? {
        sharedDefaults?.string(forKey: Key.xrayConfigJSON)
    }
}
