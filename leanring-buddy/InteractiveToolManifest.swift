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
            Execute an agent-desktop CLI command to drive macOS apps via the accessibility tree.

            AVAILABLE COMMANDS:
            - snapshot --app "App Name" -i --compact — capture the accessibility tree. ALWAYS call this first. Returns element refs like @e7 that you use in every other command.
            - click @eN — click an element by ref.
            - type @eN "text to type" — focus an element and type text. NEVER type passwords, API keys, or secrets.
            - press KEY — keyboard combo ("tab", "escape", "return", "cmd+a", ...).
            - focus @eN — set keyboard focus on an element.
            - scroll @eN --direction up|down|left|right --amount N — scroll an element.
            - scroll-to @eN — scroll an element into view.
            - hover @eN — move cursor over an element.
            - expand @eN / collapse @eN — disclosure triangle.
            - toggle @eN / check @eN / uncheck @eN — checkbox or switch.
            - select @eN --option "Option Name" — dropdown option.
            - screenshot --app "App Name" — PNG screenshot of a window.
            - launch "App Name" — launch an application.
            - list-apps — list running GUI applications.
            - list-windows --app "App Name" — list visible windows.
            - focus-window --app "App Name" — bring an app's window to front.
            - find --app "App Name" --text "search query" — search for elements by text.

            RULES:
            - Emit NO text between tool calls. Clicky's cursor visually flies to every element you touch, so the user already sees what you're doing.
            - Re-snapshot after any action that mutates the UI (opening menus, switching tabs, expanding rows).
            - After the LAST action, emit ONE short sentence (≤8 words) about what you accomplished — e.g. "opened build settings".
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

        do {
            let commandResult = try await runner.runCommand(
                arguments: fullCLIArguments,
                timeoutSeconds: commandName == "snapshot" ? 5.0 : 10.0
            )
            return InteractiveToolResult(
                toolUseID: toolUseID,
                content: commandResult.dataJSON,
                isError: false
            )
        } catch {
            return InteractiveToolResult(
                toolUseID: toolUseID,
                content: "\(commandName) failed: \(error.localizedDescription)",
                isError: true
            )
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
