import Foundation

/// Resolves the Antigravity CLI configuration directory.
///
/// Priority: user setting (UserDefaults) > `ANTIGRAVITY_CONFIG_DIR` env var > `~/.gemini/antigravity-cli`.
public enum AntigravityConfigDirectory {
    public static let defaultsKey = "antigravity.configDirectory"

    /// The user-configured custom directory, or `nil` if not set.
    public static var customDirectory: URL? {
        get {
            guard let path = UserDefaults.standard.string(forKey: defaultsKey), !path.isEmpty else {
                return nil
            }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        set {
            if let path = newValue?.path {
                UserDefaults.standard.set(path, forKey: defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            }
        }
    }

    /// Resolves the effective Antigravity config directory.
    public static func resolved(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = customDirectory {
            return custom
        }
        if let envPath = environment["ANTIGRAVITY_CONFIG_DIR"], !envPath.isEmpty {
            return URL(fileURLWithPath: (envPath as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
            .appendingPathComponent("antigravity", isDirectory: true)
    }
}
