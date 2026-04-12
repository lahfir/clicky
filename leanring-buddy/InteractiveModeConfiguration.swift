//
//  InteractiveModeConfiguration.swift
//  leanring-buddy
//
//  Reads the CLICKY_INTERACTIVE_MODE environment variable at app launch
//  to decide whether the push-to-talk chord (ctrl + option) dispatches to
//  Show mode (the default, unchanged) or to Interactive mode (the new
//  agent-desktop-driven pipeline).
//
//  There is only ONE push-to-talk chord in Clicky: ctrl + option. The
//  env var is the only thing that changes what happens when you release
//  that chord. No second hotkey, no UI toggle, no UserDefaults drift —
//  set it in your Xcode scheme and relaunch.
//
//  Set the env var via:
//    Xcode → Product → Scheme → Edit Scheme → Run → Arguments tab →
//    Environment Variables → add "CLICKY_INTERACTIVE_MODE" with value "1"
//
//  Or from a terminal launch:
//    CLICKY_INTERACTIVE_MODE=1 open path/to/leanring-buddy.app
//
//  Accepted enabled values (case-insensitive): "1", "true", "yes",
//  "enabled", "on". Anything else (including unset) means Interactive
//  mode is disabled and Clicky behaves exactly as it always has.
//

import Foundation

enum InteractiveModeConfiguration {
    /// The environment variable name the user sets to enable Interactive mode.
    static let environmentVariableName = "CLICKY_INTERACTIVE_MODE"

    /// Whether Interactive mode is enabled for this app launch. Computed
    /// once at first access by reading the environment variable.
    ///
    /// Evaluating this lazily instead of at every push-to-talk release
    /// avoids a per-press `ProcessInfo.environment` lookup. The env var
    /// cannot change during a single app launch — if you want to toggle,
    /// change the scheme and relaunch.
    static let isEnabled: Bool = {
        let rawValue = ProcessInfo.processInfo.environment[environmentVariableName]?
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let enabledRawValues: Set<String> = ["1", "true", "yes", "enabled", "on"]
        let resolvedEnabled = rawValue.map { enabledRawValues.contains($0) } ?? false

        if resolvedEnabled {
            print("🤖 InteractiveModeConfiguration: ENABLED (env: \(environmentVariableName)=\(rawValue ?? ""))")
        } else if let rawValue, rawValue.isEmpty == false {
            print("🤖 InteractiveModeConfiguration: DISABLED (env: \(environmentVariableName)=\(rawValue) is not a recognized enabled value)")
        } else {
            print("🤖 InteractiveModeConfiguration: DISABLED (env: \(environmentVariableName) is not set)")
        }

        return resolvedEnabled
    }()
}
