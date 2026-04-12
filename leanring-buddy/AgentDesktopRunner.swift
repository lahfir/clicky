//
//  AgentDesktopRunner.swift
//  leanring-buddy
//
//  Wraps subprocess invocation of the external `agent-desktop` CLI for Clicky's
//  Interactive Mode. All arguments are passed through `Process.arguments` as a
//  `[String]` array — never via shell interpolation — so arbitrary user/model
//  text (e.g. the `type` command's payload) is treated as a literal argv entry
//  and cannot inject shell metacharacters. Every invocation has a per-call
//  timeout that terminates the process on deadline, and all raw stdout/stderr
//  strings pass through `sanitizeForLogging` before being printed or wrapped
//  into thrown errors so API keys and private keys never leak into logs.
//

import CoreGraphics
import Foundation
import os

// MARK: - Error code mapping for the CLI's own machine-readable error codes.

/// Error codes documented by the `agent-desktop` CLI. These come from the
/// `error.code` field of a failing JSON response (`ok: false`).
enum AgentDesktopErrorCode: Equatable {
    case staleRef
    case elementNotFound
    case appNotFound
    case permissionDenied
    case actionFailed
    case timeout
    case invalidArgs
    case unknown(String)

    /// Build a strongly-typed error code from the raw `code` string returned
    /// by the CLI. Unknown strings are preserved verbatim inside `.unknown`
    /// so the calling layer can still surface them to Claude as context.
    init?(rawCodeString: String) {
        switch rawCodeString {
        case "STALE_REF":
            self = .staleRef
        case "ELEMENT_NOT_FOUND":
            self = .elementNotFound
        case "APP_NOT_FOUND":
            self = .appNotFound
        case "PERM_DENIED":
            self = .permissionDenied
        case "ACTION_FAILED":
            self = .actionFailed
        case "TIMEOUT":
            self = .timeout
        case "INVALID_ARGS":
            self = .invalidArgs
        default:
            if rawCodeString.isEmpty {
                return nil
            }
            self = .unknown(rawCodeString)
        }
    }
}

// MARK: - Error surfaced when the CLI itself returned `ok: false`.

/// Error produced when the CLI ran successfully but reported a domain failure
/// (for example a stale element reference or an app that was not running).
/// Distinct from `AgentDesktopRunnerError`, which covers runner/process
/// plumbing problems.
struct AgentDesktopError: Error, CustomStringConvertible {
    let code: AgentDesktopErrorCode
    let message: String
    let suggestion: String?

    var description: String {
        var pieces: [String] = []
        pieces.append("AgentDesktopError(code=\(code), message=\(message)")
        if let suggestion = suggestion, !suggestion.isEmpty {
            pieces.append(", suggestion=\(suggestion)")
        }
        pieces.append(")")
        return pieces.joined()
    }
}

// MARK: - Runner-level errors (binary discovery, subprocess plumbing, JSON shape).

/// Errors raised by the runner itself, distinct from the CLI's own reported
/// errors. These cover binary discovery failures, subprocess launch issues,
/// timeouts, and malformed output.
enum AgentDesktopRunnerError: Error, CustomStringConvertible {
    case cliBinaryNotFound
    case cliVersionTooOld(installedVersion: String, requiredMinimum: String)
    case accessibilityPermissionDenied
    case subprocessLaunchFailed(underlying: Error)
    case subprocessTimedOut(command: String)
    case nonJSONOutput(sanitizedRaw: String)
    case unexpectedResponseShape(sanitizedRaw: String)

    var description: String {
        switch self {
        case .cliBinaryNotFound:
            return "agent-desktop CLI binary was not found on PATH or in known locations."
        case .cliVersionTooOld(let installedVersion, let requiredMinimum):
            return "agent-desktop CLI version \(installedVersion) is older than required minimum \(requiredMinimum)."
        case .accessibilityPermissionDenied:
            return "agent-desktop reports that Accessibility permission has not been granted to the host app."
        case .subprocessLaunchFailed(let underlying):
            return "Failed to launch agent-desktop subprocess: \(underlying)"
        case .subprocessTimedOut(let command):
            return "agent-desktop subprocess exceeded its per-invocation timeout while running '\(command)'."
        case .nonJSONOutput(let sanitizedRaw):
            return "agent-desktop subprocess produced non-JSON output: \(sanitizedRaw)"
        case .unexpectedResponseShape(let sanitizedRaw):
            return "agent-desktop subprocess returned unexpected JSON shape: \(sanitizedRaw)"
        }
    }
}

// MARK: - Success result shapes.

/// Generic success result of a `runCommand` invocation. Callers that need a
/// domain-specific shape decode `dataJSON` themselves.
struct AgentDesktopRunnerResult {
    /// The `command` field echoed back by the CLI (e.g. "snapshot", "click").
    let commandName: String

    /// The raw JSON encoding of the top-level `data` field. Kept as a string
    /// so caller code can decode it into whatever Codable shape it prefers,
    /// or forward it verbatim to Claude as tool-result context.
    let dataJSON: String

    /// The full sanitized JSON response, retained for debug logging only.
    /// Already passed through `sanitizeForLogging`, so it is safe to print.
    let rawFullResponse: String
}

/// Specific result shape for `snapshot`, which is the hot path for Interactive
/// Mode since every tool call cycle starts with a fresh snapshot.
struct AgentDesktopSnapshotResult {
    /// The application name the snapshot was taken against, as reported by
    /// the CLI's `data.app` field.
    let appName: String

    /// The `data.ref_count` value — total number of interactive elements
    /// the CLI tracked across all open snapshots.
    let refCount: Int

    /// The raw JSON string for `data.tree`. Passed verbatim to Claude so the
    /// model sees the full accessibility tree with `@ref` IDs and does not
    /// need a second Swift-side decode layer.
    let fullTreeJSON: String

    /// Lookup table mapping `@eN` ref IDs to their screen bounds (in
    /// macOS screen coordinates). Populated from `--include-bounds` on
    /// the snapshot command. Used by the orchestrator to fly the overlay
    /// cursor to the element Claude is interacting with.
    let elementBoundsByRefID: [String: CGRect]

    /// Returns the center point of an element's bounds in screen
    /// coordinates, or nil if the ref isn't in this snapshot.
    func screenCenterForElement(refID: String) -> CGPoint? {
        guard let bounds = elementBoundsByRefID[refID] else { return nil }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/// Walks an agent-desktop snapshot JSON tree and collects the
/// `{ x, y, width, height }` bounds for every node that has a
/// `ref_id` and a `bounds` dict. Returns a flat `[refID: CGRect]`.
func parseElementBoundsFromSnapshotTree(_ treeJSON: Any) -> [String: CGRect] {
    var boundsMap: [String: CGRect] = [:]

    func walkNode(_ node: Any) {
        guard let nodeDict = node as? [String: Any] else { return }

        if let refID = nodeDict["ref_id"] as? String,
           let boundsDict = nodeDict["bounds"] as? [String: Any],
           let boundsX = boundsDict["x"] as? Double,
           let boundsY = boundsDict["y"] as? Double,
           let boundsWidth = boundsDict["width"] as? Double,
           let boundsHeight = boundsDict["height"] as? Double {
            boundsMap[refID] = CGRect(
                x: boundsX, y: boundsY,
                width: boundsWidth, height: boundsHeight
            )
        }

        if let children = nodeDict["children"] as? [Any] {
            for child in children {
                walkNode(child)
            }
        }
    }

    walkNode(treeJSON)
    return boundsMap
}

// MARK: - Runner.
//
// Design choice: `actor`.
//
// The runner caches a discovered binary URL (`cachedAgentDesktopBinaryURL`)
// and a resolved CLI version string across calls. Interactive Mode will fan
// out multiple tool invocations from different Swift tasks (a Claude stream
// handler and possibly a UI-driven re-run), and actor isolation gives us
// free data-race safety for that cached state without littering the class
// with explicit locks. All blocking work happens inside `await` points, so
// the actor executor is never stuck on process I/O.

actor AgentDesktopRunner {
    /// Minimum CLI version the Swift side has been validated against. Passed
    /// in via initializer so tests (added later) can pin a different value.
    private let minimumPinnedVersion: String

    /// Cached absolute URL of the `agent-desktop` executable, populated on the
    /// first successful `discoverBinary()` call and reused for the rest of
    /// this runner instance's lifetime.
    private var cachedAgentDesktopBinaryURL: URL?

    /// Cached installed CLI version string, filled by `discoverBinary()`.
    /// Stored so consumers can surface it in diagnostics without re-shelling.
    private var cachedInstalledCLIVersion: String?

    init(minimumPinnedVersion: String = "0.1.11") {
        self.minimumPinnedVersion = minimumPinnedVersion
    }

    // MARK: - Binary discovery.

    /// Resolve the `agent-desktop` executable URL and validate its version +
    /// accessibility-permission state. Caches the result for the lifetime of
    /// this runner instance.
    func discoverBinary() async throws -> URL {
        if let cachedAgentDesktopBinaryURL = cachedAgentDesktopBinaryURL {
            return cachedAgentDesktopBinaryURL
        }

        // First, try asking the environment where `agent-desktop` lives by
        // invoking `/usr/bin/env agent-desktop status` with a tight 500ms
        // timeout. This is the cheapest discovery path — if the CLI is on
        // PATH in the user's login environment, it resolves immediately.
        let envResolvedBinaryURL: URL? = try? await resolveBinaryViaEnvStatusProbe()

        // Fallback: probe well-known install locations directly. Homebrew
        // ships to `/opt/homebrew/bin/agent-desktop` on Apple Silicon, and
        // Bun installs global binaries into `~/.bun/bin/agent-desktop`.
        let fallbackCandidateBinaryURLs: [URL] = buildFallbackCandidateBinaryURLs()

        let candidateBinaryURLsInPriorityOrder: [URL]
        if let envResolvedBinaryURL = envResolvedBinaryURL {
            candidateBinaryURLsInPriorityOrder = [envResolvedBinaryURL] + fallbackCandidateBinaryURLs
        } else {
            candidateBinaryURLsInPriorityOrder = fallbackCandidateBinaryURLs
        }

        for candidateBinaryURL in candidateBinaryURLsInPriorityOrder {
            guard FileManager.default.isExecutableFile(atPath: candidateBinaryURL.path) else {
                continue
            }

            // Run `status` against this candidate and validate version +
            // accessibility permission. If any check fails at validation
            // time we throw — we do not silently fall through, because a
            // working-but-too-old binary should surface as a clear error.
            let statusResult = try await runStatusForValidation(binaryURL: candidateBinaryURL)

            try validateInstalledCLIVersion(
                installedVersion: statusResult.installedVersion,
                requiredMinimum: minimumPinnedVersion
            )

            if statusResult.accessibilityPermissionGranted == false {
                throw AgentDesktopRunnerError.accessibilityPermissionDenied
            }

            cachedAgentDesktopBinaryURL = candidateBinaryURL
            cachedInstalledCLIVersion = statusResult.installedVersion
            return candidateBinaryURL
        }

        throw AgentDesktopRunnerError.cliBinaryNotFound
    }

    /// Probe for the binary by asking `/usr/bin/env` to resolve it on PATH.
    /// Uses a very short timeout because we just want a quick "does it run".
    private func resolveBinaryViaEnvStatusProbe() async throws -> URL {
        let envExecutableURL = URL(fileURLWithPath: "/usr/bin/env")
        let probeArguments: [String] = ["agent-desktop", "status"]

        let rawSubprocessOutput: SubprocessRawOutput = try await spawnAndCollect(
            executableURL: envExecutableURL,
            arguments: probeArguments,
            timeoutSeconds: 0.5,
            commandLabelForDebug: "env agent-desktop status"
        )

        // If `/usr/bin/env` found it, the process exited 0 and we consider
        // the current PATH-resolved binary usable. We re-point the cached URL
        // to a concrete file path below by asking `/usr/bin/env which`. This
        // keeps the cached URL absolute.
        if rawSubprocessOutput.exitCode != 0 {
            throw AgentDesktopRunnerError.cliBinaryNotFound
        }

        let envWhichOutput: SubprocessRawOutput = try await spawnAndCollect(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["which", "agent-desktop"],
            timeoutSeconds: 0.5,
            commandLabelForDebug: "env which agent-desktop"
        )

        let trimmedWhichPath = envWhichOutput.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedWhichPath.isEmpty {
            throw AgentDesktopRunnerError.cliBinaryNotFound
        }

        return URL(fileURLWithPath: trimmedWhichPath)
    }

    /// Build the list of fallback filesystem locations to probe when PATH
    /// lookup fails. Expands `~/.bun/bin/agent-desktop` against the current
    /// user's home directory.
    private func buildFallbackCandidateBinaryURLs() -> [URL] {
        var fallbackCandidateBinaryURLs: [URL] = []

        fallbackCandidateBinaryURLs.append(
            URL(fileURLWithPath: "/opt/homebrew/bin/agent-desktop")
        )

        let userHomeDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let bunGlobalBinaryURL = userHomeDirectoryURL
            .appendingPathComponent(".bun", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("agent-desktop", isDirectory: false)
        fallbackCandidateBinaryURLs.append(bunGlobalBinaryURL)

        fallbackCandidateBinaryURLs.append(
            URL(fileURLWithPath: "/usr/local/bin/agent-desktop")
        )

        return fallbackCandidateBinaryURLs
    }

    /// Intermediate type returned by the `status`-based validation probe.
    private struct StatusValidationResult {
        let installedVersion: String
        let accessibilityPermissionGranted: Bool
    }

    /// Run `<binary> status` and parse the installed version + permissions.
    /// Used by `discoverBinary()` during validation of each candidate URL.
    private func runStatusForValidation(binaryURL: URL) async throws -> StatusValidationResult {
        let rawSubprocessOutput: SubprocessRawOutput = try await spawnAndCollect(
            executableURL: binaryURL,
            arguments: ["status"],
            timeoutSeconds: 2.0,
            commandLabelForDebug: "\(binaryURL.lastPathComponent) status"
        )

        guard let rawStdoutData = rawSubprocessOutput.stdoutString.data(using: .utf8) else {
            throw AgentDesktopRunnerError.nonJSONOutput(
                sanitizedRaw: sanitizeForLogging(rawSubprocessOutput.stdoutString)
            )
        }

        let parsedTopLevelObject: Any
        do {
            parsedTopLevelObject = try JSONSerialization.jsonObject(with: rawStdoutData, options: [])
        } catch {
            throw AgentDesktopRunnerError.nonJSONOutput(
                sanitizedRaw: sanitizeForLogging(rawSubprocessOutput.stdoutString)
            )
        }

        guard
            let topLevelDictionary = parsedTopLevelObject as? [String: Any],
            let statusDataDictionary = topLevelDictionary["data"] as? [String: Any],
            let installedVersionString = statusDataDictionary["version"] as? String
        else {
            throw AgentDesktopRunnerError.unexpectedResponseShape(
                sanitizedRaw: sanitizeForLogging(rawSubprocessOutput.stdoutString)
            )
        }

        let permissionsDictionary = statusDataDictionary["permissions"] as? [String: Any] ?? [:]
        let accessibilityPermissionGranted = permissionsDictionary["granted"] as? Bool ?? false

        return StatusValidationResult(
            installedVersion: installedVersionString,
            accessibilityPermissionGranted: accessibilityPermissionGranted
        )
    }

    /// Compare the installed CLI version string against the minimum pinned
    /// version. Throws `.cliVersionTooOld` when the installed version is
    /// lower. Uses dotted numeric comparison so `0.1.11` beats `0.1.9`.
    private func validateInstalledCLIVersion(
        installedVersion: String,
        requiredMinimum: String
    ) throws {
        let installedVersionComponents: [Int] = installedVersion
            .split(separator: ".")
            .map { component in Int(component) ?? 0 }
        let requiredMinimumComponents: [Int] = requiredMinimum
            .split(separator: ".")
            .map { component in Int(component) ?? 0 }

        let comparisonLength = max(
            installedVersionComponents.count,
            requiredMinimumComponents.count
        )

        for componentIndex in 0..<comparisonLength {
            let installedComponentValue = componentIndex < installedVersionComponents.count
                ? installedVersionComponents[componentIndex]
                : 0
            let requiredComponentValue = componentIndex < requiredMinimumComponents.count
                ? requiredMinimumComponents[componentIndex]
                : 0

            if installedComponentValue > requiredComponentValue {
                return
            }
            if installedComponentValue < requiredComponentValue {
                throw AgentDesktopRunnerError.cliVersionTooOld(
                    installedVersion: installedVersion,
                    requiredMinimum: requiredMinimum
                )
            }
        }
        // Equal versions are acceptable.
    }

    // MARK: - Core runCommand entry point.

    /// Spawn `agent-desktop` with the provided argument array, enforcing a
    /// per-invocation timeout. Parses the top-level JSON envelope and either
    /// returns a success result or throws `AgentDesktopError` (for CLI
    /// failures with `ok: false`) / `AgentDesktopRunnerError` (for plumbing
    /// failures).
    func runCommand(
        arguments: [String],
        timeoutSeconds: Double
    ) async throws -> AgentDesktopRunnerResult {
        let resolvedAgentDesktopBinaryURL: URL = try await discoverBinary()

        let commandLabelForDebug: String = arguments.first ?? "agent-desktop"

        let rawSubprocessOutput: SubprocessRawOutput = try await spawnAndCollect(
            executableURL: resolvedAgentDesktopBinaryURL,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds,
            commandLabelForDebug: commandLabelForDebug
        )

        return try decodeCLIResponseEnvelope(
            rawStdoutString: rawSubprocessOutput.stdoutString
        )
    }

    /// Decode the CLI's standard JSON envelope (`{ok, command, data, error}`)
    /// into either an `AgentDesktopRunnerResult` or a thrown error. Extracted
    /// so the snapshot fast path and runCommand share identical parsing.
    private func decodeCLIResponseEnvelope(
        rawStdoutString: String
    ) throws -> AgentDesktopRunnerResult {
        guard let rawStdoutData = rawStdoutString.data(using: .utf8) else {
            throw AgentDesktopRunnerError.nonJSONOutput(
                sanitizedRaw: sanitizeForLogging(rawStdoutString)
            )
        }

        let parsedTopLevelObject: Any
        do {
            parsedTopLevelObject = try JSONSerialization.jsonObject(with: rawStdoutData, options: [])
        } catch {
            throw AgentDesktopRunnerError.nonJSONOutput(
                sanitizedRaw: sanitizeForLogging(rawStdoutString)
            )
        }

        guard let topLevelDictionary = parsedTopLevelObject as? [String: Any] else {
            throw AgentDesktopRunnerError.unexpectedResponseShape(
                sanitizedRaw: sanitizeForLogging(rawStdoutString)
            )
        }

        let commandName = topLevelDictionary["command"] as? String ?? "unknown"
        let okFlag = topLevelDictionary["ok"] as? Bool ?? false

        if okFlag == false {
            // Failure envelope — surface the CLI's machine-readable code.
            let errorDictionary = topLevelDictionary["error"] as? [String: Any] ?? [:]
            let rawErrorCodeString = errorDictionary["code"] as? String ?? ""
            let errorMessage = errorDictionary["message"] as? String ?? "agent-desktop reported an error"
            let errorSuggestion = errorDictionary["suggestion"] as? String

            let typedErrorCode = AgentDesktopErrorCode(rawCodeString: rawErrorCodeString)
                ?? .unknown(rawErrorCodeString)

            throw AgentDesktopError(
                code: typedErrorCode,
                message: errorMessage,
                suggestion: errorSuggestion
            )
        }

        // Success envelope — extract `data` and re-serialize just that
        // subtree into a JSON string the caller can forward verbatim.
        let dataSubtreeJSONString: String = reserializeJSONSubtree(
            topLevelDictionary: topLevelDictionary,
            key: "data"
        )

        let sanitizedFullResponse = sanitizeForLogging(rawStdoutString)

        return AgentDesktopRunnerResult(
            commandName: commandName,
            dataJSON: dataSubtreeJSONString,
            rawFullResponse: sanitizedFullResponse
        )
    }

    /// Re-serialize a specific top-level key from a parsed JSON dictionary
    /// back into a JSON string. Returns "null" if the key is missing.
    private func reserializeJSONSubtree(
        topLevelDictionary: [String: Any],
        key: String
    ) -> String {
        guard let subtreeValue = topLevelDictionary[key] else {
            return "null"
        }

        guard JSONSerialization.isValidJSONObject(subtreeValue)
            || subtreeValue is NSNull
            || subtreeValue is String
            || subtreeValue is NSNumber
        else {
            return "null"
        }

        // JSONSerialization requires the top-level to be an array or dict.
        // Wrap primitives in an array temporarily if needed.
        if let subtreeAsDictionary = subtreeValue as? [String: Any] {
            guard
                let subtreeAsData = try? JSONSerialization.data(
                    withJSONObject: subtreeAsDictionary,
                    options: []
                ),
                let subtreeAsString = String(data: subtreeAsData, encoding: .utf8)
            else {
                return "null"
            }
            return subtreeAsString
        }

        if let subtreeAsArray = subtreeValue as? [Any] {
            guard
                let subtreeAsData = try? JSONSerialization.data(
                    withJSONObject: subtreeAsArray,
                    options: []
                ),
                let subtreeAsString = String(data: subtreeAsData, encoding: .utf8)
            else {
                return "null"
            }
            return subtreeAsString
        }

        // For primitive leaves, round-trip through an array wrapper.
        guard
            let wrappedAsData = try? JSONSerialization.data(
                withJSONObject: [subtreeValue],
                options: []
            ),
            let wrappedAsString = String(data: wrappedAsData, encoding: .utf8),
            wrappedAsString.hasPrefix("["),
            wrappedAsString.hasSuffix("]")
        else {
            return "null"
        }
        let innerJSONString = String(wrappedAsString.dropFirst().dropLast())
        return innerJSONString
    }

    // MARK: - Convenience methods that build argument arrays.

    /// Snapshot a named application's accessibility tree. This is the hot
    /// path invoked at the start of every Interactive Mode tool cycle.
    func snapshot(
        app applicationName: String,
        timeoutSeconds: Double = 5.0
    ) async throws -> AgentDesktopSnapshotResult {
        let snapshotArguments: [String] = [
            "snapshot",
            "--app", applicationName,
            "--interactive-only",
            "--compact"
        ]

        let snapshotRunnerResult: AgentDesktopRunnerResult = try await runCommand(
            arguments: snapshotArguments,
            timeoutSeconds: timeoutSeconds
        )

        // Re-parse the data subtree to pull out `app`, `ref_count`, and the
        // full tree JSON. We keep tree JSON as a string to avoid a second
        // round-trip decode on the hot path.
        guard let dataJSONUTF8 = snapshotRunnerResult.dataJSON.data(using: .utf8) else {
            throw AgentDesktopRunnerError.unexpectedResponseShape(
                sanitizedRaw: sanitizeForLogging(snapshotRunnerResult.rawFullResponse)
            )
        }

        let parsedDataObject: Any
        do {
            parsedDataObject = try JSONSerialization.jsonObject(with: dataJSONUTF8, options: [])
        } catch {
            throw AgentDesktopRunnerError.unexpectedResponseShape(
                sanitizedRaw: sanitizeForLogging(snapshotRunnerResult.rawFullResponse)
            )
        }

        guard let dataDictionary = parsedDataObject as? [String: Any] else {
            throw AgentDesktopRunnerError.unexpectedResponseShape(
                sanitizedRaw: sanitizeForLogging(snapshotRunnerResult.rawFullResponse)
            )
        }

        let extractedAppName = dataDictionary["app"] as? String ?? applicationName
        let extractedRefCount = dataDictionary["ref_count"] as? Int ?? 0

        let fullTreeJSONString: String = reserializeJSONSubtree(
            topLevelDictionary: dataDictionary,
            key: "tree"
        )

        // Parse element bounds from the tree (populated by --include-bounds)
        let treeObject = dataDictionary["tree"] ?? [:]
        let parsedElementBounds = parseElementBoundsFromSnapshotTree(treeObject)

        return AgentDesktopSnapshotResult(
            appName: extractedAppName,
            refCount: extractedRefCount,
            fullTreeJSON: fullTreeJSONString,
            elementBoundsByRefID: parsedElementBounds
        )
    }

    /// Click an element by its snapshot-scoped ref (e.g. "@e5").
    func click(
        ref elementRefIdentifier: String,
        timeoutSeconds: Double = 10.0
    ) async throws {
        _ = try await runCommand(
            arguments: ["click", elementRefIdentifier],
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Type literal text into an element. IMPORTANT: `textToType` is passed
    /// as a single argv entry — it is NEVER shell-escaped or interpolated.
    /// `Process.arguments: [String]` guarantees argv[N] equals the literal
    /// string, so quotes, backticks, `$(...)`, and newlines are all safe.
    func type(
        ref elementRefIdentifier: String,
        text textToType: String,
        timeoutSeconds: Double = 10.0
    ) async throws {
        _ = try await runCommand(
            arguments: ["type", elementRefIdentifier, textToType],
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Send a key combo (e.g. "return", "cmd+c", "shift+tab"). The combo is
    /// a positional argument per `agent-desktop press --help`.
    func press(
        key keyComboString: String,
        timeoutSeconds: Double = 5.0
    ) async throws {
        _ = try await runCommand(
            arguments: ["press", keyComboString],
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Give keyboard focus to an element.
    func focus(ref elementRefIdentifier: String) async throws {
        _ = try await runCommand(
            arguments: ["focus", elementRefIdentifier],
            timeoutSeconds: 5.0
        )
    }

    /// Scroll an element in a direction by a unit amount.
    func scroll(
        ref elementRefIdentifier: String,
        direction scrollDirection: String,
        amount scrollAmount: Int
    ) async throws {
        _ = try await runCommand(
            arguments: [
                "scroll", elementRefIdentifier,
                "--direction", scrollDirection,
                "--amount", String(scrollAmount)
            ],
            timeoutSeconds: 5.0
        )
    }

    /// Scroll an element into the visible viewport.
    func scrollTo(ref elementRefIdentifier: String) async throws {
        _ = try await runCommand(
            arguments: ["scroll-to", elementRefIdentifier],
            timeoutSeconds: 5.0
        )
    }

    /// Hover the cursor over an element.
    func hover(ref elementRefIdentifier: String) async throws {
        _ = try await runCommand(
            arguments: ["hover", elementRefIdentifier],
            timeoutSeconds: 5.0
        )
    }

    /// Expand a disclosure element.
    func expand(ref elementRefIdentifier: String) async throws {
        _ = try await runCommand(
            arguments: ["expand", elementRefIdentifier],
            timeoutSeconds: 5.0
        )
    }

    /// Collapse a disclosure element.
    func collapse(ref elementRefIdentifier: String) async throws {
        _ = try await runCommand(
            arguments: ["collapse", elementRefIdentifier],
            timeoutSeconds: 5.0
        )
    }

    /// Toggle a checkbox or switch.
    func toggle(ref elementRefIdentifier: String) async throws {
        _ = try await runCommand(
            arguments: ["toggle", elementRefIdentifier],
            timeoutSeconds: 5.0
        )
    }

    /// Set a checkbox or switch to the checked state (idempotent).
    func check(ref elementRefIdentifier: String) async throws {
        _ = try await runCommand(
            arguments: ["check", elementRefIdentifier],
            timeoutSeconds: 5.0
        )
    }

    /// Set a checkbox or switch to the unchecked state (idempotent).
    func uncheck(ref elementRefIdentifier: String) async throws {
        _ = try await runCommand(
            arguments: ["uncheck", elementRefIdentifier],
            timeoutSeconds: 5.0
        )
    }

    /// Select an option in a list or dropdown. The option value is a literal
    /// argv entry, not shell-interpolated.
    func select(
        ref elementRefIdentifier: String,
        option optionValueToSelect: String
    ) async throws {
        _ = try await runCommand(
            arguments: ["select", elementRefIdentifier, optionValueToSelect],
            timeoutSeconds: 5.0
        )
    }

    /// Launch an application by name or bundle ID and wait for its window.
    func launchApp(name applicationNameOrBundleID: String) async throws {
        _ = try await runCommand(
            arguments: ["launch", applicationNameOrBundleID],
            timeoutSeconds: 30.0
        )
    }

    /// Return the raw `data` JSON string for `list-apps`. Returned as a
    /// string so callers can forward it directly to Claude as tool context.
    func listApps() async throws -> String {
        let listAppsRunnerResult = try await runCommand(
            arguments: ["list-apps"],
            timeoutSeconds: 5.0
        )
        return listAppsRunnerResult.dataJSON
    }

    /// Return the raw `data` JSON string for `list-windows`, optionally
    /// filtered by app name.
    func listWindows(app applicationNameFilter: String?) async throws -> String {
        var listWindowsArguments: [String] = ["list-windows"]
        if let applicationNameFilter = applicationNameFilter {
            listWindowsArguments.append("--app")
            listWindowsArguments.append(applicationNameFilter)
        }

        let listWindowsRunnerResult = try await runCommand(
            arguments: listWindowsArguments,
            timeoutSeconds: 5.0
        )
        return listWindowsRunnerResult.dataJSON
    }

    /// Bring a named application's window to the front.
    func focusWindow(app applicationNameToFocus: String) async throws {
        _ = try await runCommand(
            arguments: ["focus-window", "--app", applicationNameToFocus],
            timeoutSeconds: 5.0
        )
    }

    /// Search for elements in an app matching a free-text query. Returns the
    /// raw `data` JSON string for Claude to parse.
    func find(
        app applicationNameToSearch: String,
        query freeTextSearchQuery: String
    ) async throws -> String {
        let findArguments: [String] = [
            "find",
            "--app", applicationNameToSearch,
            "--text", freeTextSearchQuery
        ]
        let findRunnerResult = try await runCommand(
            arguments: findArguments,
            timeoutSeconds: 5.0
        )
        return findRunnerResult.dataJSON
    }
}

// MARK: - Subprocess plumbing.
//
// Timeout mechanism: a detached watchdog Task sleeps for `timeoutSeconds` and
// then calls `process.terminate()` on the live process. The main async path
// uses `withCheckedThrowingContinuation` to await `Process.terminationHandler`
// and resume once. A flag (`hasResumedContinuation`) guards the single-resume
// contract. Chose this over `DispatchSource.makeTimerSource` because it plays
// nicely with structured concurrency and cancellation on the calling task.

/// Raw output captured from a subprocess invocation. Internal to the runner.
private struct SubprocessRawOutput {
    let stdoutString: String
    let stderrString: String
    let exitCode: Int32
}

extension AgentDesktopRunner {

    /// Launch a child process, collect stdout and stderr fully, enforce a
    /// timeout, and return the raw captured strings + exit code. Never
    /// parses JSON — callers are responsible for that.
    fileprivate func spawnAndCollect(
        executableURL childProcessExecutableURL: URL,
        arguments childProcessArguments: [String],
        timeoutSeconds childProcessTimeoutSeconds: Double,
        commandLabelForDebug: String
    ) async throws -> SubprocessRawOutput {
        let childProcess = Process()
        childProcess.executableURL = childProcessExecutableURL
        childProcess.arguments = childProcessArguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        childProcess.standardOutput = stdoutPipe
        childProcess.standardError = stderrPipe
        childProcess.standardInput = FileHandle.nullDevice

        // Shared state guarding the one-shot continuation resume. We use
        // `OSAllocatedUnfairLock<Bool>` instead of `NSLock` because this
        // function is `async` and is called from inside both the
        // terminationHandler callback (which runs on a Foundation-owned
        // thread) and a `Task.detached` watchdog (which runs in an async
        // context). `NSLock.lock/unlock` is unavailable from async contexts
        // in Swift 6; `OSAllocatedUnfairLock` is async-safe and offers a
        // scoped `withLock` closure API that cannot leak a held lock.
        let alreadyResumedState = OSAllocatedUnfairLock<Bool>(initialState: false)

        // Helper: atomically mark the continuation as resumed. Returns
        // true if THIS call is the first one to claim the resume (and
        // the caller should proceed to actually resume the continuation),
        // or false if another caller already claimed it (and the caller
        // should return without resuming).
        @Sendable
        func claimOneShotResume() -> Bool {
            alreadyResumedState.withLock { hasAlreadyResumed in
                if hasAlreadyResumed { return false }
                hasAlreadyResumed = true
                return true
            }
        }

        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<SubprocessRawOutput, Error>) in

            childProcess.terminationHandler = { terminatedProcess in
                // Drain pipes. `readDataToEndOfFile` is safe here because
                // terminationHandler fires after the process exits.
                let capturedStdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let capturedStderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let capturedStdoutString = String(
                    data: capturedStdoutData,
                    encoding: .utf8
                ) ?? ""
                let capturedStderrString = String(
                    data: capturedStderrData,
                    encoding: .utf8
                ) ?? ""

                guard claimOneShotResume() else {
                    // Timeout already resumed the continuation with a
                    // failure. Don't double-resume.
                    return
                }

                // Print any stderr for debugging, sanitized.
                if capturedStderrString.isEmpty == false {
                    let sanitizedStderr = sanitizeForLogging(capturedStderrString)
                    print("[AgentDesktopRunner] stderr(\(commandLabelForDebug)): \(sanitizedStderr)")
                }

                let rawOutput = SubprocessRawOutput(
                    stdoutString: capturedStdoutString,
                    stderrString: capturedStderrString,
                    exitCode: terminatedProcess.terminationStatus
                )
                continuation.resume(returning: rawOutput)
            }

            do {
                try childProcess.run()
            } catch {
                if claimOneShotResume() {
                    continuation.resume(
                        throwing: AgentDesktopRunnerError.subprocessLaunchFailed(underlying: error)
                    )
                }
                return
            }

            // Detached watchdog Task that terminates the process if the
            // deadline passes. On timeout we resume the continuation
            // with `.subprocessTimedOut` immediately so the caller is
            // unblocked even if the child ignores SIGTERM briefly.
            Task.detached {
                let nanosecondsPerSecond: UInt64 = 1_000_000_000
                let sleepNanoseconds = UInt64(
                    childProcessTimeoutSeconds * Double(nanosecondsPerSecond)
                )
                try? await Task.sleep(nanoseconds: sleepNanoseconds)

                if childProcess.isRunning == false {
                    return
                }

                let thisCallClaimedResume = claimOneShotResume()

                // Terminate regardless so we don't leak a child process.
                childProcess.terminate()

                if thisCallClaimedResume {
                    continuation.resume(
                        throwing: AgentDesktopRunnerError.subprocessTimedOut(
                            command: commandLabelForDebug
                        )
                    )
                }
            }
        }
    }
}

// MARK: - Secret redaction for logging.
//
// TODO: Consolidate this with the richer redactor in
// `InteractiveOutboundSafety.swift` (being built by another agent) once that
// file lands. For now we inline a minimal set of patterns to avoid a build-
// time circular dependency between these two files.

/// Replace obviously secret-looking substrings with `<redacted>` before
/// printing subprocess output or embedding it in thrown errors. Handles the
/// most common API key prefixes plus PEM private key headers. Intentionally
/// conservative — prefers false positives (over-redaction) to leaking.
func sanitizeForLogging(_ rawStringToSanitize: String) -> String {
    let secretRegexPatternsToRedact: [String] = [
        #"sk-[A-Za-z0-9]{20,}"#,
        #"sk_[A-Za-z0-9]{20,}"#,
        #"ghp_[A-Za-z0-9]{20,}"#,
        #"gho_[A-Za-z0-9]{20,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"AIza[0-9A-Za-z_-]{35}"#,
        #"-----BEGIN [A-Z ]+ PRIVATE KEY-----"#
    ]

    var workingSanitizedString = rawStringToSanitize
    for secretRegexPattern in secretRegexPatternsToRedact {
        guard let compiledSecretRegex = try? NSRegularExpression(
            pattern: secretRegexPattern,
            options: []
        ) else {
            continue
        }

        let fullRangeOfWorkingString = NSRange(
            workingSanitizedString.startIndex...,
            in: workingSanitizedString
        )
        workingSanitizedString = compiledSecretRegex.stringByReplacingMatches(
            in: workingSanitizedString,
            options: [],
            range: fullRangeOfWorkingString,
            withTemplate: "<redacted>"
        )
    }

    return workingSanitizedString
}
