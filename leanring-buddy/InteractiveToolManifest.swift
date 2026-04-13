//
//  InteractiveToolManifest.swift
//  leanring-buddy
//
//  Single source of truth for the Interactive Mode tool set that Claude can
//  call via Anthropic's native `tool_use` API. Instead of defining one tool
//  per agent-desktop command, we expose ONE generic tool that can execute
//  any agent-desktop CLI command. Claude reads the tool description (which
//  lists every available command) and constructs the right invocation.
//
//  The allow-list of what Claude CAN'T do is controlled by what commands
//  are listed in the tool description — if a command isn't mentioned,
//  Claude won't try it. If Claude somehow does try an unlisted command,
//  agent-desktop itself will reject it or it'll be a no-op.
//

import Foundation

// MARK: - Tool definition types (Anthropic wire format)

/// A single tool declaration as Anthropic's `tool_use` API expects it.
struct InteractiveTool: Encodable {
    let name: String
    let description: String
    let input_schema: InteractiveToolInputSchema
}

/// JSON Schema `input_schema` wrapper. Always `type: "object"`.
struct InteractiveToolInputSchema: Encodable {
    let type: String = "object"
    let properties: [String: InteractiveToolProperty]
    let required: [String]
}

/// A single property inside a tool's `input_schema`.
struct InteractiveToolProperty: Encodable {
    let type: String
    let description: String
}

// MARK: - Tool call / result types (parsed from Claude's response)

/// Represents the different JSON value types Claude can send as tool arguments.
enum InteractiveToolCallArgument {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case arrayOfStrings([String])

    var stringValue: String? {
        if case .string(let stringValue) = self { return stringValue }
        return nil
    }

    var integerValue: Int? {
        if case .integer(let integerValue) = self { return integerValue }
        if case .double(let doubleValue) = self { return Int(doubleValue) }
        return nil
    }

    var booleanValue: Bool? {
        if case .boolean(let booleanValue) = self { return booleanValue }
        return nil
    }

    var stringArrayValue: [String]? {
        if case .arrayOfStrings(let arrayValue) = self { return arrayValue }
        return nil
    }
}

/// A parsed `tool_use` block from Claude's streamed response.
struct InteractiveToolCall {
    let toolUseID: String
    let toolName: String
    let input: [String: InteractiveToolCallArgument]
}

/// The response Clicky sends back to Claude as a `tool_result` content block.
struct InteractiveToolResult: Encodable {
    let toolUseID: String
    let content: String
    let isError: Bool

    private enum CodingKeys: String, CodingKey {
        case toolUseID = "tool_use_id"
        case content
        case isError = "is_error"
    }
}

// MARK: - Tool manifest

enum InteractiveToolManifest {

    /// ONE tool — a generic agent-desktop CLI executor. Claude reads the
    /// description to know what commands are available and how to call them.
    static let v1Tools: [InteractiveTool] = [
        InteractiveTool(
            name: "agent_desktop",
            description: """
            Execute an agent-desktop CLI command to drive macOS apps via the native accessibility tree.

            OBSERVATION:
            - snapshot --skeleton --app "App" -i --compact — PREFERRED for dense apps (Slack, VS Code, Mail, Numbers, Xcode). Returns a shallow overview with children_count per region and refs on named containers at the truncation boundary. Use this to locate the region containing your target, then drill.
            - snapshot --root @eN -i --compact — drill into a region identified from the skeleton. Scoped invalidation: only @eN's subtree refs change; other refs stay valid.
            - snapshot --app "App" -i --compact — full tree. Only for simple apps with few elements (Finder, Calculator, TextEdit).
            - snapshot --app "App" --surface menu -i — snapshot of a menu / sheet / alert overlay. Never combine --surface with --skeleton.
            - find --app "App" --role button --name "Save" — targeted search by role/name/text/value. Faster than snapshot when you know what you're looking for. Supports --first, --last, --nth N.
            - get @eN --property text|value|title|bounds|role|states — read a specific element property.
            - is @eN --property visible|enabled|checked|focused|expanded — check element state.
            - screenshot --app "App" — PNG of a window.
            - list-surfaces --app "App" — list available surfaces (window, menu, sheet, ...).

            INTERACTION:
            - click @eN / double-click @eN / triple-click @eN / right-click @eN
            - type @eN "text to type" — focus and type. NEVER type passwords, API keys, or secrets.
            - focus @eN — set keyboard focus.
            - select @eN --option "Option Name" — dropdown option.
            - toggle @eN / check @eN / uncheck @eN — checkbox or switch (check/uncheck are idempotent).
            - expand @eN / collapse @eN — disclosure triangle.
            - scroll @eN --direction up|down|left|right --amount N
            - scroll-to @eN — scroll element into view.
            - hover @eN — move cursor over element.

            KEYBOARD & SYSTEM:
            - press KEY — "tab", "escape", "return", "cmd+a", "shift+tab", "down", etc.
            - launch "App Name" — launch and wait for window.
            - list-apps — running GUI applications.
            - list-windows --app "App" — visible windows.
            - focus-window --app "App" — bring window to front.

            ASYNC UI:
            - wait MS — pause N milliseconds.
            - wait --element @eN --timeout 5000 — wait for element to appear.
            - wait --window "Title" --timeout 5000 — wait for a window.
            - wait --text "Done" --app "App" — wait for text to appear.
            - wait --menu --app "App" — wait for a context menu to open.
            - wait --menu-closed --app "App" — wait for a menu to dismiss.

            ERROR CODES (from error.code in the tool_result):
            - STALE_REF / ELEMENT_NOT_FOUND — the ref is from a stale snapshot. Re-snapshot (or re-drill with --root) and try again with the new ref.
            - PERM_DENIED — Clicky will auto-trigger the macOS permission dialog. Stop and wait for the user.
            - APP_NOT_FOUND — the app isn't running. Call `launch "App Name"` first.
            - ACTION_NOT_SUPPORTED — the element can't do that. Try a different command (e.g. set-value instead of type).
            - TIMEOUT — a wait condition didn't resolve. Widen the timeout or pick a different anchor.

            RULES:
            - Start dense apps with `snapshot --skeleton -i --compact`. Drill with `--root @eN`, don't re-snapshot the whole app.
            - Prefer `find` when you know the exact role + name.
            - After UI-mutating actions (click, type, expand), re-drill ONLY the affected region via `--root @eN`. Refs outside that region stay valid.
            - After launching an app or opening a dialog, use `wait` — don't assume the UI is ready.
            - Emit NO text between tool calls. Clicky's cursor visually flies to every element you touch.
            - After the LAST action, emit ONE short sentence (≤15 words) about what you accomplished.
            - Never type secrets, passwords, or API keys.
            """,
            input_schema: InteractiveToolInputSchema(
                properties: [
                    "command": InteractiveToolProperty(
                        type: "string",
                        description: "The agent-desktop subcommand to run (e.g. 'click', 'snapshot', 'type', 'launch')."
                    ),
                    "args": InteractiveToolProperty(
                        type: "string",
                        description: "All arguments as a single string, exactly as you'd type them after the command name on the CLI. Examples: '@e7' for click, '--app Finder -i --compact' for snapshot, '@e5 hello world' for type."
                    )
                ],
                required: ["command"]
            )
        )
    ]
}

// MARK: - Dispatcher

enum InteractiveToolDispatcher {

    @MainActor
    static func dispatch(
        _ interactiveToolCall: InteractiveToolCall,
        targetApplicationName: String?,
        runner: AgentDesktopRunner
    ) async -> InteractiveToolResult {
        let toolUseID = interactiveToolCall.toolUseID
        let inputArguments = interactiveToolCall.input

        guard interactiveToolCall.toolName == "agent_desktop" else {
            return InteractiveToolResult(
                toolUseID: toolUseID,
                content: "Unknown tool: \(interactiveToolCall.toolName). Use 'agent_desktop' with a 'command' argument.",
                isError: true
            )
        }

        guard let commandName = inputArguments["command"]?.stringValue, !commandName.isEmpty else {
            return InteractiveToolResult(
                toolUseID: toolUseID,
                content: "Missing required argument: command",
                isError: true
            )
        }

        // Parse the args string into an argument array for Process.
        // We split on spaces but respect quoted strings so things like
        // type @e5 "hello world" work correctly.
        let rawArgsString = inputArguments["args"]?.stringValue ?? ""
        let parsedArguments = splitArgumentString(rawArgsString)

        // Build the full CLI argument list: [command, ...args]
        let fullCLIArguments = [commandName] + parsedArguments

        // Timeout tuned per-command family. Accessibility-tree snapshots on
        // heavy apps (Numbers, Xcode, Mail) can genuinely take 5–10 seconds,
        // so the old 5s cap was cutting them off. Screenshots scale with
        // window size. Interactive verbs (click, type, focus) are snappy.
        let perCommandTimeoutSeconds: Double
        switch commandName {
        case "snapshot":
            perCommandTimeoutSeconds = 20.0
        case "screenshot":
            perCommandTimeoutSeconds = 15.0
        case "find":
            perCommandTimeoutSeconds = 15.0
        default:
            perCommandTimeoutSeconds = 10.0
        }

        do {
            let commandResult = try await runner.runCommand(
                arguments: fullCLIArguments,
                timeoutSeconds: perCommandTimeoutSeconds
            )
            return InteractiveToolResult(
                toolUseID: toolUseID,
                content: commandResult.dataJSON,
                isError: false
            )
        } catch let runnerError as AgentDesktopRunnerError {
            // Auto-prompt for the macOS Accessibility dialog if the error
            // is actually a denied permission. Without this the user just
            // sees a silent failure — macOS will now surface the system
            // permission sheet on their next action.
            if case .accessibilityPermissionDenied = runnerError {
                await requestAgentDesktopAccessibilityPermission(runner: runner)
            }
            return InteractiveToolResult(
                toolUseID: toolUseID,
                content: "\(commandName) failed: \(runnerError.description)",
                isError: true
            )
        } catch {
            // String(describing:) invokes CustomStringConvertible on enums
            // that conform to it (AgentDesktopError), so Claude sees the
            // CLI's actual error reason instead of Swift's default
            // "The operation couldn't be completed. (X error N.)" noise.
            return InteractiveToolResult(
                toolUseID: toolUseID,
                content: "\(commandName) failed: \(String(describing: error))",
                isError: true
            )
        }
    }

    /// Runs `agent-desktop permissions --request` which triggers the macOS
    /// Accessibility permission sheet for the agent-desktop binary. Fire-and-
    /// forget — the dialog is modal to the user and we don't block on it.
    private static func requestAgentDesktopAccessibilityPermission(
        runner: AgentDesktopRunner
    ) async {
        do {
            _ = try await runner.runCommand(
                arguments: ["permissions", "--request"],
                timeoutSeconds: 3.0
            )
            print("🔑 [Interactive] triggered agent-desktop permission prompt")
        } catch {
            print("⚠️ [Interactive] failed to request permission: \(String(describing: error))")
        }
    }

    /// Splits a CLI argument string into individual arguments, respecting
    /// double-quoted strings. For example:
    ///   `@e5 "hello world" --flag` → `["@e5", "hello world", "--flag"]`
    private static func splitArgumentString(_ argumentString: String) -> [String] {
        var parsedArguments: [String] = []
        var currentArgument = ""
        var insideQuotes = false

        for character in argumentString {
            if character == "\"" {
                insideQuotes.toggle()
            } else if character == " " && !insideQuotes {
                if !currentArgument.isEmpty {
                    parsedArguments.append(currentArgument)
                    currentArgument = ""
                }
            } else {
                currentArgument.append(character)
            }
        }

        if !currentArgument.isEmpty {
            parsedArguments.append(currentArgument)
        }

        return parsedArguments
    }
}
