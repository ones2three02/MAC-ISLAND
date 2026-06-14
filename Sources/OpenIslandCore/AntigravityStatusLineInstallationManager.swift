import Foundation

public struct AntigravityStatusLineInstallationStatus: Equatable, Sendable {
    public var antigravityDirectory: URL
    public var settingsURL: URL
    public var scriptDirectoryURL: URL
    public var scriptURL: URL
    public var cacheURL: URL
    public var statusLineCommand: String?
    public var hasStatusLine: Bool
    public var managedStatusLineConfigured: Bool
    public var managedStatusLineInstalled: Bool
    public var managedStatusLineNeedsRepair: Bool
    public var hasConflictingStatusLine: Bool
    /// `true` when the managed script is installed in wrapper mode, preserving
    /// the user's existing `statusLine.command` under `_openIslandOriginalStatusLine`.
    public var managedStatusLineIsWrapper: Bool

    public init(
        antigravityDirectory: URL,
        settingsURL: URL,
        scriptDirectoryURL: URL,
        scriptURL: URL,
        cacheURL: URL,
        statusLineCommand: String?,
        hasStatusLine: Bool,
        managedStatusLineConfigured: Bool,
        managedStatusLineInstalled: Bool,
        managedStatusLineNeedsRepair: Bool,
        hasConflictingStatusLine: Bool,
        managedStatusLineIsWrapper: Bool = false
    ) {
        self.antigravityDirectory = antigravityDirectory
        self.settingsURL = settingsURL
        self.scriptDirectoryURL = scriptDirectoryURL
        self.scriptURL = scriptURL
        self.cacheURL = cacheURL
        self.statusLineCommand = statusLineCommand
        self.hasStatusLine = hasStatusLine
        self.managedStatusLineConfigured = managedStatusLineConfigured
        self.managedStatusLineInstalled = managedStatusLineInstalled
        self.managedStatusLineNeedsRepair = managedStatusLineNeedsRepair
        self.hasConflictingStatusLine = hasConflictingStatusLine
        self.managedStatusLineIsWrapper = managedStatusLineIsWrapper
    }
}

public final class AntigravityStatusLineInstallationManager: @unchecked Sendable {
    public static let managedScriptName = "open-island-antigravity-statusline"
    public static let wrappedDelegateScriptName = "open-island-antigravity-statusline-delegate"
    public static let legacyManagedScriptName = "vibe-island-antigravity-statusline"
    public static let managedCacheURL = AntigravityUsageLoader.defaultCacheURL
    public static let quotaHelperScriptName = "open-island-antigravity-quota-helper.py"

    public static let quotaHelperScript = #"""
        #!/usr/bin/env python3
        # Antigravity Quota Helper
        # Auto-configured by Mac Island
        import subprocess
        import re
        import urllib.request
        import json
        import time
        import sys

        def get_ports():
            try:
                res = subprocess.check_output("lsof -i -P -n | grep -E 'agy|language_server' | grep -i listen", shell=True)
                lines = res.decode('utf-8', errors='ignore').split('\n')
                ports = []
                for line in lines:
                    m = re.search(r'TCP 127\.0\.0\.1:(\d+)', line)
                    if m:
                        ports.append(int(m.group(1)))
                return list(set(ports))
            except Exception:
                return []

        def main():
            cache_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/open-island-antigravity-rl.json"
            ports = get_ports()
            for p in ports:
                url = f"http://127.0.0.1:{p}/exa.language_server_pb.LanguageServerService/GetUserStatus"
                try:
                    req = urllib.request.Request(url, data=b'{}', method='POST')
                    req.add_header('Content-Type', 'application/json')
                    with urllib.request.urlopen(req, timeout=1.5) as resp:
                        data = json.loads(resp.read().decode('utf-8'))
                        user_status = data.get('userStatus', {})
                        plan_status = user_status.get('planStatus', {})
                        avail_prompt = plan_status.get('availablePromptCredits')
                        avail_flow = plan_status.get('availableFlowCredits')
                        if avail_prompt is not None and avail_flow is not None:
                            five_hour_used = max(0, min(100, int(round(100 - (avail_prompt / 500.0 * 100)))))
                            seven_day_used = max(0, min(100, int(round(100 - (avail_flow / 100.0 * 100)))))
                            
                            quota_data = {
                                "five_hour": {
                                    "used_percentage": five_hour_used,
                                    "resets_at": int(time.time()) + 18000
                                },
                                "seven_day": {
                                    "used_percentage": seven_day_used,
                                    "resets_at": int(time.time()) + 604800
                                }
                            }
                            
                            with open(cache_path, "w") as f:
                                json.dump(quota_data, f, indent=2)
                            break
                except Exception:
                    pass

        if __name__ == '__main__':
            main()
        """#


    public let antigravityDirectory: URL
    public let scriptDirectoryURL: URL
    public let legacyScriptDirectoryURL: URL
    private let fileManager: FileManager

    public init(
        antigravityDirectory: URL = AntigravityConfigDirectory.resolved(),
        scriptDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".open-island", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true),
        legacyScriptDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe-island", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.antigravityDirectory = antigravityDirectory
        self.scriptDirectoryURL = scriptDirectoryURL
        self.legacyScriptDirectoryURL = legacyScriptDirectoryURL
        self.fileManager = fileManager
    }

    public func status() throws -> AntigravityStatusLineInstallationStatus {
        let settingsURL = antigravityDirectory.appendingPathComponent("settings.json")
        let scriptURL = scriptDirectoryURL.appendingPathComponent(Self.managedScriptName)
        let legacyScriptURL = legacyScriptDirectoryURL.appendingPathComponent(Self.legacyManagedScriptName)

        let settings = try loadSettings(at: settingsURL)
        let statusLine = settings["statusLine"] as? [String: Any]
        let command = statusLine?["command"] as? String
        let managedCommands = [scriptURL.path, legacyScriptURL.path]
        let managedStatusLineConfigured = managedCommands.contains(command ?? "")
        let managedStatusLineInstalled = managedStatusLineConfigured
            && (command.map { fileManager.fileExists(atPath: $0) } ?? false)
        let managedStatusLineNeedsRepair = managedStatusLineConfigured && !managedStatusLineInstalled
        let hasStatusLine = statusLine != nil
        let hasConflictingStatusLine = hasStatusLine && !managedStatusLineConfigured
        let managedStatusLineIsWrapper = managedStatusLineConfigured
            && settings[openIslandOriginalStatusLineKey] != nil

        return AntigravityStatusLineInstallationStatus(
            antigravityDirectory: antigravityDirectory,
            settingsURL: settingsURL,
            scriptDirectoryURL: scriptDirectoryURL,
            scriptURL: scriptURL,
            cacheURL: Self.managedCacheURL,
            statusLineCommand: command,
            hasStatusLine: hasStatusLine,
            managedStatusLineConfigured: managedStatusLineConfigured,
            managedStatusLineInstalled: managedStatusLineInstalled,
            managedStatusLineNeedsRepair: managedStatusLineNeedsRepair,
            hasConflictingStatusLine: hasConflictingStatusLine,
            managedStatusLineIsWrapper: managedStatusLineIsWrapper
        )
    }

    @discardableResult
    public func install() throws -> AntigravityStatusLineInstallationStatus {
        let currentStatus = try status()
        if currentStatus.hasConflictingStatusLine {
            throw ClaudeStatusLineInstallationError.existingStatusLineConflict(
                command: currentStatus.statusLineCommand
            )
        }

        try fileManager.createDirectory(at: antigravityDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scriptDirectoryURL, withIntermediateDirectories: true)

        let settingsURL = currentStatus.settingsURL
        let scriptURL = currentStatus.scriptURL
        let existingSettings = try loadSettings(at: settingsURL)
        var mutatedSettings = existingSettings
        mutatedSettings["statusLine"] = managedStatusLine(for: scriptURL)

        let settingsData = try serializeSettings(mutatedSettings)
        if fileManager.fileExists(atPath: settingsURL.path) {
            try backupFile(at: settingsURL)
        }

        let scriptContents = Self.managedScript(cacheURL: currentStatus.cacheURL, scriptDirectoryURL: scriptDirectoryURL)
        try settingsData.write(to: settingsURL, options: .atomic)
        try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let helperURL = scriptDirectoryURL.appendingPathComponent(Self.quotaHelperScriptName)
        try Self.quotaHelperScript.write(to: helperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
        let legacyScriptURL = legacyScriptDirectoryURL.appendingPathComponent(Self.legacyManagedScriptName)
        if fileManager.fileExists(atPath: legacyScriptURL.path) {
            try fileManager.removeItem(at: legacyScriptURL)
        }

        // Write statusLine config to ~/.gemini/antigravity-cli for CLI tool compatibility
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cliDir = home.appendingPathComponent(".gemini", isDirectory: true).appendingPathComponent("antigravity-cli", isDirectory: true)
        if cliDir.path != antigravityDirectory.path {
            try? fileManager.createDirectory(at: cliDir, withIntermediateDirectories: true)
            let cliSettingsURL = cliDir.appendingPathComponent("settings.json")
            let existingCliSettings = (try? loadSettings(at: cliSettingsURL)) ?? [:]
            var mutatedCliSettings = existingCliSettings
            mutatedCliSettings["statusLine"] = managedStatusLine(for: scriptURL)
            if let settingsData = try? serializeSettings(mutatedCliSettings) {
                try? settingsData.write(to: cliSettingsURL, options: .atomic)
            }
        }

        return try status()
    }

    @discardableResult
    public func installAsWrapper() throws -> AntigravityStatusLineInstallationStatus {
        let currentStatus = try status()
        guard currentStatus.hasConflictingStatusLine,
              let originalCommand = currentStatus.statusLineCommand,
              !originalCommand.isEmpty
        else {
            throw ClaudeStatusLineInstallationError.wrappableCommandMissing
        }

        try fileManager.createDirectory(at: antigravityDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scriptDirectoryURL, withIntermediateDirectories: true)

        let settingsURL = currentStatus.settingsURL
        let scriptURL = currentStatus.scriptURL
        let delegateScriptURL = scriptDirectoryURL.appendingPathComponent(Self.wrappedDelegateScriptName)
        var mutatedSettings = try loadSettings(at: settingsURL)

        if let originalStatusLine = mutatedSettings["statusLine"] {
            mutatedSettings[openIslandOriginalStatusLineKey] = originalStatusLine
        }
        mutatedSettings["statusLine"] = managedStatusLine(for: scriptURL)

        let settingsData = try serializeSettings(mutatedSettings)
        if fileManager.fileExists(atPath: settingsURL.path) {
            try backupFile(at: settingsURL)
        }

        let wrapperContents = Self.wrappedScript(
            cacheURL: currentStatus.cacheURL,
            delegateScriptURL: delegateScriptURL,
            scriptDirectoryURL: scriptDirectoryURL
        )
        let delegateContents = Self.wrappedDelegateScript(originalCommand: originalCommand)
 
        try settingsData.write(to: settingsURL, options: .atomic)
        try wrapperContents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try delegateContents.write(to: delegateScriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: delegateScriptURL.path)

        let helperURL = scriptDirectoryURL.appendingPathComponent(Self.quotaHelperScriptName)
        try Self.quotaHelperScript.write(to: helperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)

        // Write statusLine config to ~/.gemini/antigravity-cli in wrapper mode
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cliDir = home.appendingPathComponent(".gemini", isDirectory: true).appendingPathComponent("antigravity-cli", isDirectory: true)
        if cliDir.path != antigravityDirectory.path {
            try? fileManager.createDirectory(at: cliDir, withIntermediateDirectories: true)
            let cliSettingsURL = cliDir.appendingPathComponent("settings.json")
            var mutatedCliSettings = (try? loadSettings(at: cliSettingsURL)) ?? [:]
            if let originalStatusLine = mutatedCliSettings["statusLine"] {
                mutatedCliSettings[openIslandOriginalStatusLineKey] = originalStatusLine
            }
            mutatedCliSettings["statusLine"] = managedStatusLine(for: scriptURL)
            if let settingsData = try? serializeSettings(mutatedCliSettings) {
                try? settingsData.write(to: cliSettingsURL, options: .atomic)
            }
        }

        return try status()
    }

    @discardableResult
    public func uninstall() throws -> AntigravityStatusLineInstallationStatus {
        let currentStatus = try status()
        let settingsURL = currentStatus.settingsURL
        let scriptURL = currentStatus.scriptURL
        let delegateScriptURL = scriptDirectoryURL.appendingPathComponent(Self.wrappedDelegateScriptName)

        if currentStatus.managedStatusLineConfigured {
            var settings = try loadSettings(at: settingsURL)
            if let savedOriginal = settings[openIslandOriginalStatusLineKey] {
                settings["statusLine"] = savedOriginal
                settings.removeValue(forKey: openIslandOriginalStatusLineKey)
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            if fileManager.fileExists(atPath: settingsURL.path) {
                try backupFile(at: settingsURL)
            }
            let settingsData = try serializeSettings(settings)
            try settingsData.write(to: settingsURL, options: .atomic)
        }

        if fileManager.fileExists(atPath: scriptURL.path) {
            try fileManager.removeItem(at: scriptURL)
        }
        if fileManager.fileExists(atPath: delegateScriptURL.path) {
            try fileManager.removeItem(at: delegateScriptURL)
        }
        let helperURL = scriptDirectoryURL.appendingPathComponent(Self.quotaHelperScriptName)
        if fileManager.fileExists(atPath: helperURL.path) {
            try fileManager.removeItem(at: helperURL)
        }
        let legacyScriptURL = legacyScriptDirectoryURL.appendingPathComponent(Self.legacyManagedScriptName)
        if fileManager.fileExists(atPath: legacyScriptURL.path) {
            try fileManager.removeItem(at: legacyScriptURL)
        }

        // Clean up statusLine config in ~/.gemini/antigravity-cli
        let home = FileManager.default.homeDirectoryForCurrentUser
        let cliDir = home.appendingPathComponent(".gemini", isDirectory: true).appendingPathComponent("antigravity-cli", isDirectory: true)
        if cliDir.path != antigravityDirectory.path {
            let cliSettingsURL = cliDir.appendingPathComponent("settings.json")
            if var cliSettings = try? loadSettings(at: cliSettingsURL) {
                if cliSettings[openIslandOriginalStatusLineKey] != nil || cliSettings["statusLine"] != nil {
                    if let savedOriginal = cliSettings[openIslandOriginalStatusLineKey] {
                        cliSettings["statusLine"] = savedOriginal
                        cliSettings.removeValue(forKey: openIslandOriginalStatusLineKey)
                    } else {
                        cliSettings.removeValue(forKey: "statusLine")
                    }
                    if let settingsData = try? serializeSettings(cliSettings) {
                        try? settingsData.write(to: cliSettingsURL, options: .atomic)
                    }
                }
            }
        }

        return try status()
    }

    private func loadSettings(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }

        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let settings = object as? [String: Any] else {
            throw ClaudeStatusLineInstallationError.invalidSettingsRoot
        }
        return settings
    }

    private func serializeSettings(_ settings: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    private func managedStatusLine(for scriptURL: URL) -> [String: Any] {
        [
            "type": "command",
            "command": scriptURL.path,
            "padding": 2,
        ]
    }

    private func backupFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupURL = url.appendingPathExtension("backup.\(timestamp)")
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: url, to: backupURL)
    }

    public static func wrappedScript(
        cacheURL: URL,
        delegateScriptURL: URL,
        scriptDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".open-island", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    ) -> String {
        #"""
        #!/bin/bash
        # Antigravity StatusLine Script (wrapper mode)
        # Auto-configured by Mac Island.
        input=$(cat)
        python3 "\#(scriptDirectoryURL.path)/\#(quotaHelperScriptName)" "\#(cacheURL.path)" >/dev/null 2>&1 &
        printf '%s' "$input" | "\#(delegateScriptURL.path)"
        """#
    }

    public static func wrappedDelegateScript(originalCommand: String) -> String {
        "#!/bin/bash\n# Original Antigravity statusLine.command preserved by Mac Island.\n\(originalCommand)\n"
    }

    public static func managedScript(
        cacheURL: URL = managedCacheURL,
        scriptDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".open-island", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    ) -> String {
        #"""
        #!/bin/bash
        # Antigravity StatusLine Script
        # Auto-configured by Mac Island
        input=$(cat)
        python3 "\#(scriptDirectoryURL.path)/\#(quotaHelperScriptName)" "\#(cacheURL.path)" >/dev/null 2>&1 &
        echo "$input" | jq -r '"[\(.model.display_name // "Antigravity")] \(.context_window.used_percentage // 0)% context"' 2>/dev/null
        """#
    }
}
