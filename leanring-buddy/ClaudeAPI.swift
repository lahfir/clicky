//
//  ClaudeAPI.swift
//  Claude API Implementation with streaming support
//

import Foundation

// MARK: - Interactive Mode supporting types

/// Aggregated result of a full Interactive mode multi-turn conversation with
/// Claude's tool_use API. Returned by `ClaudeAPI.analyzeInteractiveRequest`
/// once Claude emits `stop_reason: end_turn` (or an error aborts the loop).
struct InteractiveClaudeResult {
    /// All text content blocks Claude emitted across every turn of the loop,
    /// concatenated in emission order. This is the final user-facing narration.
    let fullConcatenatedText: String
    /// Every tool_use block Claude emitted across every turn, in emission order.
    /// Callers can use this for telemetry or replay.
    let toolCallsExecuted: [InteractiveToolCall]
    /// How many Claude API calls were made during this request. Always >= 1.
    /// Equals 1 for a pure-text response, and (1 + N) when Claude issued N
    /// tool_use turns before finally stopping with end_turn.
    let totalTurns: Int
    /// The final `stop_reason` from Claude's last message_delta event.
    /// Typically "end_turn" on success.
    let finalStopReason: String
}

/// Errors specific to the Interactive-mode multi-turn loop. The single-shot
/// `analyzeImageStreaming` path still throws the legacy `NSError(domain:"ClaudeAPI",…)`
/// values and is untouched.
enum ClaudeAPIError: Error {
    /// Claude's response was cut off at `max_tokens` before it could finish.
    case interactiveResponseTruncated
    /// The multi-turn loop exceeded its safety cap (20 iterations) — Claude
    /// may be stuck in a pathological tool_use loop.
    case interactiveLoopLimitExceeded
    /// The `onToolUseStart` callback threw while dispatching a tool. The
    /// current callback signature is non-throwing, but this case exists so
    /// a future throwing variant can propagate upstream without API churn.
    case toolDispatchFailed(underlying: Error)
    /// Claude's tool_use block had malformed accumulated JSON that could not
    /// be parsed into a `[String: Any]` input object.
    case malformedToolUseInputJSON(rawJSONString: String)
    /// An unexpected HTTP status or empty body was received from the proxy
    /// during an Interactive-mode turn.
    case interactiveHTTPError(statusCode: Int, responseBody: String)
}

/// Claude API helper with streaming for progressive text display.
class ClaudeAPI {
    private static let tlsWarmupLock = NSLock()
    private static var hasStartedTLSWarmup = false

    private let apiURL: URL
    var model: String
    private let session: URLSession

    init(proxyURL: String, model: String = "claude-sonnet-4-6") {
        self.apiURL = URL(string: proxyURL)!
        self.model = model

        // Use .default instead of .ephemeral so TLS session tickets are cached.
        // Ephemeral sessions do a full TLS handshake on every request, which causes
        // transient -1200 (errSSLPeerHandshakeFail) errors with large image payloads.
        // Disable URL/cookie caching to avoid storing responses or credentials on disk.
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)

        // Fire a lightweight HEAD request in the background to pre-establish the TLS
        // connection. This caches the TLS session ticket so the first real API call
        // (which carries a large image payload) doesn't need a cold TLS handshake.
        warmUpTLSConnectionIfNeeded()
    }

    private func makeAPIRequest() -> URLRequest {
        var request = URLRequest(url: apiURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Detects the MIME type of image data by inspecting the first bytes.
    /// Screen captures from ScreenCaptureKit are JPEG, but pasted images from the
    /// clipboard are PNG. The API rejects requests where the declared media_type
    /// doesn't match the actual image format.
    private func detectImageMediaType(for imageData: Data) -> String {
        // PNG files start with the 8-byte signature: 89 50 4E 47 0D 0A 1A 0A
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "image/png"
            }
        }
        // Default to JPEG — screen captures use JPEG compression
        return "image/jpeg"
    }

    /// Sends a no-op HEAD request to the API host to establish and cache a TLS session.
    /// Failures are silently ignored — this is purely an optimization.
    private func warmUpTLSConnectionIfNeeded() {
        Self.tlsWarmupLock.lock()
        let shouldStartTLSWarmup = !Self.hasStartedTLSWarmup
        if shouldStartTLSWarmup {
            Self.hasStartedTLSWarmup = true
        }
        Self.tlsWarmupLock.unlock()

        guard shouldStartTLSWarmup else { return }

        guard var warmupURLComponents = URLComponents(url: apiURL, resolvingAgainstBaseURL: false) else {
            return
        }

        // The TLS session ticket is host-scoped, so warming the root host is enough.
        // Hitting the host instead of `/v1/messages` avoids extra endpoint-specific noise.
        warmupURLComponents.path = "/"
        warmupURLComponents.query = nil
        warmupURLComponents.fragment = nil

        guard let warmupURL = warmupURLComponents.url else {
            return
        }

        var warmupRequest = URLRequest(url: warmupURL)
        warmupRequest.httpMethod = "HEAD"
        warmupRequest.timeoutInterval = 10
        session.dataTask(with: warmupRequest) { _, _, _ in
            // Response doesn't matter — the TLS handshake is the goal
        }.resume()
    }

    /// Send a vision request to Claude with streaming.
    /// Calls `onTextChunk` on the main actor each time new text arrives so the UI updates progressively.
    /// Returns the full accumulated text and total duration when the stream completes.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()

        // Build messages array
        var messages: [[String: Any]] = []

        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "stream": true,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude streaming request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        // Use bytes streaming for SSE (Server-Sent Events)
        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        // If non-2xx status, read the full body as error text
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "ClaudeAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "API Error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Parse SSE stream — each event is "data: {json}\n\n"
        var accumulatedResponseText = ""

        for try await line in byteStream.lines {
            // SSE lines look like: "data: {...}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonString = String(line.dropFirst(6)) // Drop "data: " prefix

            // End of stream marker
            guard jsonString != "[DONE]" else { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let eventPayload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let eventType = eventPayload["type"] as? String else {
                continue
            }

            // We care about content_block_delta events that contain text chunks
            if eventType == "content_block_delta",
               let delta = eventPayload["delta"] as? [String: Any],
               let deltaType = delta["type"] as? String,
               deltaType == "text_delta",
               let textChunk = delta["text"] as? String {
                accumulatedResponseText += textChunk
                // Send the accumulated text so far to the UI for progressive rendering
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Non-streaming fallback for validation requests where we don't need progressive display.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        var request = makeAPIRequest()

        var messages: [[String: Any]] = []
        for (userPlaceholder, assistantResponse) in conversationHistory {
            messages.append(["role": "user", "content": userPlaceholder])
            messages.append(["role": "assistant", "content": assistantResponse])
        }

        // Build current message with all labeled images + prompt
        var contentBlocks: [[String: Any]] = []
        for image in images {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": image.label
            ])
        }
        contentBlocks.append([
            "type": "text",
            "text": userPrompt
        ])
        messages.append(["role": "user", "content": contentBlocks])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "system": systemPrompt,
            "messages": messages
        ]

        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Claude request: \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "ClaudeAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "API Error: \(responseString)"]
            )
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let content = json?["content"] as? [[String: Any]],
              let textBlock = content.first(where: { ($0["type"] as? String) == "text" }),
              let text = textBlock["text"] as? String else {
            throw NSError(
                domain: "ClaudeAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }

    // MARK: - Interactive Mode (tool_use multi-turn loop)

    /// Send a vision + tool_use request to Claude and drive the multi-turn
    /// tool_use loop until Claude emits `stop_reason: end_turn` (or an error
    /// aborts the loop).
    ///
    /// This method is ADDITIVE — the one-shot `analyzeImageStreaming` path
    /// used by Show mode is untouched. Interactive mode uses this sibling
    /// method instead because it needs:
    ///   1. A `tools` array in the request body (tool manifest)
    ///   2. A loop that continues the conversation after each `tool_use`
    ///      stop_reason by sending back a `tool_result` user turn
    ///   3. Streaming of text chunks AND streaming of tool_use events to the
    ///      caller so the orchestrator can pipe narration to TTS and dispatch
    ///      tool calls to `AgentDesktopRunner`
    ///
    /// Multi-tool_use handling: Anthropic requires a `tool_result` for every
    /// `tool_use` block in the preceding assistant turn — you cannot send
    /// back a partial set. So if Claude emits N tool_use blocks in a single
    /// turn, we dispatch ALL N sequentially (via repeated `onToolUseStart`
    /// calls in emission order) and batch every returned tool_result into a
    /// single user message for the next turn. In practice Claude usually
    /// emits one tool per turn, but batching keeps us correct when it doesn't.
    func analyzeInteractiveRequest(
        frontmostWindowImage: Data,
        frontmostWindowImageMediaType: String,
        snapshotJSONString: String,
        userTranscript: String,
        interactiveSystemPrompt: String,
        tools: [InteractiveTool],
        conversationHistory: [(userTranscript: String, assistantResponse: String)],
        onTextChunk: @MainActor @Sendable (String) -> Void,
        onToolUseStart: @MainActor @Sendable (InteractiveToolCall) async -> InteractiveToolResult
    ) async throws -> InteractiveClaudeResult {

        // Safety cap so Claude can't infinite-loop us on tool_use. If we
        // exceed this we throw `interactiveLoopLimitExceeded`.
        let maximumNumberOfLoopIterations = 20

        // Encode the tool manifest once up-front. Anthropic expects `tools`
        // to be a JSON array of tool objects at the top level of the request.
        let toolsJSONEncoder = JSONEncoder()
        let toolsJSONData = try toolsJSONEncoder.encode(tools)
        guard let toolsJSONArray = try JSONSerialization.jsonObject(with: toolsJSONData) as? [[String: Any]] else {
            throw ClaudeAPIError.malformedToolUseInputJSON(rawJSONString: "tool manifest encoding failed")
        }

        // Build the initial user message content blocks — image, accessibility
        // snapshot JSON as a text block, and the raw user transcript as a
        // second text block. This ordering matches the spec in the feature doc.
        // Build the initial user message content blocks. If image data is
        // provided, include it as the first block (Show-mode-style screenshot
        // context). If empty, skip the image block entirely — Interactive mode
        // sends only the accessibility tree and transcript, which is sufficient
        // for Claude to plan tool calls without visual context.
        // Only send the user's transcript. The snapshot and screenshot are
        // NOT included — Claude has the `snapshot` and `screenshot` tools and
        // will call them when it needs context. This keeps the initial request
        // tiny and avoids re-sending 15-20K tokens of tree data on every turn.
        let initialUserMessageContentBlocks: [[String: Any]] = [
            [
                "type": "text",
                "text": userTranscript
            ]
        ]

        // Mutable message history that grows as the loop runs. We start with
        // the prepended conversation history (as plain-text turns) followed
        // by the new multi-content-block user turn.
        var runningMessagesForNextTurn: [[String: Any]] = []
        for historyEntry in conversationHistory {
            runningMessagesForNextTurn.append([
                "role": "user",
                "content": historyEntry.userTranscript
            ])
            runningMessagesForNextTurn.append([
                "role": "assistant",
                "content": historyEntry.assistantResponse
            ])
        }
        runningMessagesForNextTurn.append([
            "role": "user",
            "content": initialUserMessageContentBlocks
        ])

        // Accumulators that span the entire multi-turn loop.
        var fullConcatenatedTextAcrossAllTurns = ""
        var toolCallsExecutedAcrossAllTurns: [InteractiveToolCall] = []
        var numberOfTurnsExecuted = 0
        var lastObservedStopReason = ""

        // MULTI-TURN LOOP ================================================
        multiTurnLoop: while true {

            if numberOfTurnsExecuted >= maximumNumberOfLoopIterations {
                throw ClaudeAPIError.interactiveLoopLimitExceeded
            }

            let requestBodyForThisTurn = buildInteractiveRequestBody(
                toolsJSONArray: toolsJSONArray,
                interactiveSystemPrompt: interactiveSystemPrompt,
                runningMessagesForNextTurn: runningMessagesForNextTurn
            )

            let requestBodyData = try JSONSerialization.data(withJSONObject: requestBodyForThisTurn)
            var requestForThisTurn = makeAPIRequest()
            requestForThisTurn.httpBody = requestBodyData
            // Enables Anthropic's built-in context editing (clear_tool_uses_20250919)
            // so the server prunes stale tool_result payloads for us.
            requestForThisTurn.setValue(
                "context-management-2025-06-27",
                forHTTPHeaderField: "anthropic-beta"
            )

            let payloadMegabytes = Double(requestBodyData.count) / 1_048_576.0
            print("🌐 Claude interactive turn #\(numberOfTurnsExecuted + 1): \(String(format: "%.2f", payloadMegabytes))MB, \(tools.count) tool(s)")

            let (byteStream, httpResponse) = try await session.bytes(for: requestForThisTurn)

            guard let httpResponseAsHTTPURLResponse = httpResponse as? HTTPURLResponse else {
                throw ClaudeAPIError.interactiveHTTPError(
                    statusCode: -1,
                    responseBody: "Invalid HTTP response object"
                )
            }

            guard (200...299).contains(httpResponseAsHTTPURLResponse.statusCode) else {
                var errorBodyLineBuffer: [String] = []
                for try await errorResponseLine in byteStream.lines {
                    errorBodyLineBuffer.append(errorResponseLine)
                }
                let errorResponseBody = errorBodyLineBuffer.joined(separator: "\n")

                // Honor Retry-After on 429. Anthropic returns an integer number
                // of seconds to wait before retrying. We retry the same turn
                // exactly once per rate-limit event — if it's still limited on
                // the retry, we surface the error to the user.
                if httpResponseAsHTTPURLResponse.statusCode == 429 {
                    let retryAfterSeconds = Self.parseRetryAfterSeconds(
                        fromHTTPResponse: httpResponseAsHTTPURLResponse
                    ) ?? 30
                    print("⏳ Claude rate limited — retrying in \(retryAfterSeconds)s (Retry-After header)")
                    try await Task.sleep(nanoseconds: UInt64(retryAfterSeconds) * 1_000_000_000)
                    continue multiTurnLoop
                }

                throw ClaudeAPIError.interactiveHTTPError(
                    statusCode: httpResponseAsHTTPURLResponse.statusCode,
                    responseBody: errorResponseBody
                )
            }

            // ---- Per-turn SSE parsing state ----
            // Claude's streaming format emits `content_block_start` with an
            // index, followed by zero or more `content_block_delta` events
            // that carry either `text_delta` or `input_json_delta` payloads,
            // followed by a `content_block_stop` that finalizes the block at
            // that index. We track the currently-open block index and its
            // type so we know where to route each delta.

            // The full assistant message content blocks for THIS turn, in
            // the exact wire format Anthropic expects when we echo it back
            // as an assistant message in the next turn's messages array.
            var assistantContentBlocksForThisTurn: [[String: Any]] = []

            // Per-open-block scratch state. Only one content block is open
            // at a time in Anthropic's streaming format.
            var typeOfCurrentlyOpenContentBlock: String? = nil
            var accumulatedTextForCurrentTextBlock = ""
            var accumulatedToolUseInputJSONString = ""
            var currentToolUseBlockID = ""
            var currentToolUseName = ""

            // Collected tool_use blocks from THIS turn. Used to decide whether
            // to loop again (non-empty -> tool_use turn) and to construct the
            // tool_result user message for the next turn. All entries are
            // dispatched sequentially after the SSE stream drains.
            var toolUseBlocksEmittedInThisTurn: [InteractiveToolCall] = []

            // Tracks the stop_reason emitted in the final `message_delta` event.
            var stopReasonEmittedInThisTurn: String = ""

            // TODO: consolidate with analyzeImageStreaming's SSE loop once both
            // are stable. For safety during R17 we duplicate the SSE parsing
            // code here rather than refactoring the Show-mode path.
            sseEventLoop: for try await sseLine in byteStream.lines {
                guard sseLine.hasPrefix("data: ") else { continue }
                let jsonPayloadString = String(sseLine.dropFirst(6))
                guard jsonPayloadString != "[DONE]" else { break sseEventLoop }

                guard let jsonPayloadData = jsonPayloadString.data(using: .utf8),
                      let sseEventPayload = try? JSONSerialization.jsonObject(with: jsonPayloadData) as? [String: Any],
                      let sseEventType = sseEventPayload["type"] as? String
                else {
                    continue
                }

                switch sseEventType {

                case "message_start":
                    // Nothing to do — we don't track the assistant message id
                    // because we never reference it by id in subsequent turns.
                    break

                case "content_block_start":
                    // Start a new content block at the given index. Read the
                    // block type and — if it's a tool_use — stash the id and name.
                    _ = sseEventPayload["index"] as? Int
                    guard let contentBlockStartPayload = sseEventPayload["content_block"] as? [String: Any],
                          let contentBlockType = contentBlockStartPayload["type"] as? String
                    else {
                        continue
                    }
                    typeOfCurrentlyOpenContentBlock = contentBlockType
                    if contentBlockType == "text" {
                        accumulatedTextForCurrentTextBlock = ""
                    } else if contentBlockType == "tool_use" {
                        currentToolUseBlockID = contentBlockStartPayload["id"] as? String ?? ""
                        currentToolUseName = contentBlockStartPayload["name"] as? String ?? ""
                        accumulatedToolUseInputJSONString = ""
                    }

                case "content_block_delta":
                    // Deltas carry either text (text_delta) or partial JSON
                    // for the tool_use input object (input_json_delta).
                    guard let contentBlockDeltaPayload = sseEventPayload["delta"] as? [String: Any],
                          let contentBlockDeltaType = contentBlockDeltaPayload["type"] as? String
                    else {
                        continue
                    }
                    if contentBlockDeltaType == "text_delta",
                       let textDeltaString = contentBlockDeltaPayload["text"] as? String {
                        accumulatedTextForCurrentTextBlock += textDeltaString
                        fullConcatenatedTextAcrossAllTurns += textDeltaString
                        // Stream the just-arrived text chunk to the orchestrator
                        // so it can pipe to TTS in real-time if it wants to.
                        let textChunkToDeliver = textDeltaString
                        await onTextChunk(textChunkToDeliver)
                    } else if contentBlockDeltaType == "input_json_delta",
                              let partialJSONString = contentBlockDeltaPayload["partial_json"] as? String {
                        accumulatedToolUseInputJSONString += partialJSONString
                    }

                case "content_block_stop":
                    // Finalize the currently open block. If it was a tool_use,
                    // parse its accumulated JSON and construct an
                    // InteractiveToolCall that will be dispatched AFTER the
                    // full SSE stream has drained (so we can batch multiple
                    // tool_use blocks from the same turn into a single
                    // tool_result user message).
                    guard let typeOfBlockBeingClosed = typeOfCurrentlyOpenContentBlock else {
                        continue
                    }

                    if typeOfBlockBeingClosed == "text" {
                        // Echo the finalized text block into this turn's
                        // assistant content blocks so we can reuse it in the
                        // next turn's `messages` array.
                        assistantContentBlocksForThisTurn.append([
                            "type": "text",
                            "text": accumulatedTextForCurrentTextBlock
                        ])
                    } else if typeOfBlockBeingClosed == "tool_use" {
                        // Parse the accumulated partial_json into a Swift dict.
                        // Empty string means Claude sent no input — treat as {}.
                        let parsedToolUseInputDictionary: [String: Any]
                        if accumulatedToolUseInputJSONString.isEmpty {
                            parsedToolUseInputDictionary = [:]
                        } else {
                            guard let toolUseInputJSONData = accumulatedToolUseInputJSONString.data(using: .utf8),
                                  let parsedObject = try? JSONSerialization.jsonObject(with: toolUseInputJSONData) as? [String: Any]
                            else {
                                throw ClaudeAPIError.malformedToolUseInputJSON(
                                    rawJSONString: accumulatedToolUseInputJSONString
                                )
                            }
                            parsedToolUseInputDictionary = parsedObject
                        }

                        // Echo the finalized tool_use block into this turn's
                        // assistant content blocks. Anthropic requires the
                        // parsed input object (not the raw partial_json stream)
                        // when we echo it back in the next turn.
                        assistantContentBlocksForThisTurn.append([
                            "type": "tool_use",
                            "id": currentToolUseBlockID,
                            "name": currentToolUseName,
                            "input": parsedToolUseInputDictionary
                        ])

                        // Convert the parsed `[String: Any]` into the typed
                        // `[String: InteractiveToolCallArgument]` expected by
                        // `InteractiveToolCall`. Unsupported argument types
                        // (arrays, nested objects, null) are silently dropped —
                        // the v1 tool set only uses scalar arguments anyway.
                        var typedToolCallInputArguments: [String: InteractiveToolCallArgument] = [:]
                        for (argumentKey, argumentValue) in parsedToolUseInputDictionary {
                            if let argumentAsString = argumentValue as? String {
                                typedToolCallInputArguments[argumentKey] = .string(argumentAsString)
                            } else if let argumentAsBool = argumentValue as? Bool {
                                typedToolCallInputArguments[argumentKey] = .boolean(argumentAsBool)
                            } else if let argumentAsInt = argumentValue as? Int {
                                typedToolCallInputArguments[argumentKey] = .integer(argumentAsInt)
                            } else if let argumentAsDouble = argumentValue as? Double {
                                typedToolCallInputArguments[argumentKey] = .double(argumentAsDouble)
                            }
                            // Other types (NSNull, array, nested object) are
                            // intentionally dropped — not represented in the
                            // v1 `InteractiveToolCallArgument` enum.
                        }

                        let parsedInteractiveToolCall = InteractiveToolCall(
                            toolUseID: currentToolUseBlockID,
                            toolName: currentToolUseName,
                            input: typedToolCallInputArguments
                        )
                        toolUseBlocksEmittedInThisTurn.append(parsedInteractiveToolCall)
                        toolCallsExecutedAcrossAllTurns.append(parsedInteractiveToolCall)
                    }

                    // Clear the per-block scratch state so the next
                    // content_block_start can reinitialize it cleanly.
                    typeOfCurrentlyOpenContentBlock = nil
                    accumulatedTextForCurrentTextBlock = ""
                    accumulatedToolUseInputJSONString = ""
                    currentToolUseBlockID = ""
                    currentToolUseName = ""

                case "message_delta":
                    // Carries the final stop_reason on the last event before
                    // message_stop. We capture it to drive the loop decision.
                    if let messageDeltaPayload = sseEventPayload["delta"] as? [String: Any],
                       let stopReasonValue = messageDeltaPayload["stop_reason"] as? String {
                        stopReasonEmittedInThisTurn = stopReasonValue
                    }

                case "message_stop":
                    // Message is complete. Nothing to do — we'll break out
                    // of the SSE loop naturally when the byte stream ends.
                    break

                default:
                    // `ping`, `error`, and any future event types we don't
                    // recognize are safely ignored.
                    break
                }
            }

            // This turn's SSE stream is fully drained. Decide what to do next.
            numberOfTurnsExecuted += 1
            lastObservedStopReason = stopReasonEmittedInThisTurn

            // Treat max_tokens as a soft end — log it prominently so the
            // user hears something actually happened, but don't throw the
            // whole pipeline away. Anthropic returns partial content blocks
            // in the truncated turn, so accumulated text and completed
            // tool_use blocks are still usable.
            if stopReasonEmittedInThisTurn == "max_tokens" {
                print("⚠️ Claude hit max_tokens (\(4096)) mid-turn — ending loop with partial content")
                break multiTurnLoop
            }

            // `end_turn`, `refusal`, or any non-tool_use terminal reason means
            // we're done. Exit the multi-turn loop and return accumulated result.
            if stopReasonEmittedInThisTurn != "tool_use" {
                break multiTurnLoop
            }

            // At this point stop_reason is `tool_use`. Anthropic requires a
            // `tool_result` for EVERY `tool_use` block in the preceding
            // assistant turn, so we dispatch all of them sequentially and
            // batch the results into a single user message.
            if toolUseBlocksEmittedInThisTurn.isEmpty {
                // Anthropic says stop_reason is tool_use but we parsed zero
                // tool_use blocks — treat as end of conversation to avoid
                // infinite looping.
                break multiTurnLoop
            }

            // Dispatch every tool_use block in emission order and collect
            // the resulting tool_result content blocks for the next turn.
            var toolResultContentBlocksForNextUserTurn: [[String: Any]] = []
            for toolUseBlockFromThisTurn in toolUseBlocksEmittedInThisTurn {
                let toolResultFromDispatcher = await onToolUseStart(toolUseBlockFromThisTurn)
                let toolResultContentBlock: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": toolResultFromDispatcher.toolUseID,
                    "content": toolResultFromDispatcher.content,
                    "is_error": toolResultFromDispatcher.isError
                ]
                toolResultContentBlocksForNextUserTurn.append(toolResultContentBlock)
            }

            // Append the assistant turn (text + tool_use blocks) to the
            // running message history so the next request reconstructs the
            // full conversation state Anthropic expects.
            runningMessagesForNextTurn.append([
                "role": "assistant",
                "content": assistantContentBlocksForThisTurn
            ])

            // Append a user turn containing one tool_result block per
            // tool_use block Claude emitted. Order matches the assistant
            // turn's tool_use order, which is what Anthropic expects.
            // Older tool_results are pruned server-side by Anthropic's
            // context-editing feature — see buildInteractiveRequestBody.
            runningMessagesForNextTurn.append([
                "role": "user",
                "content": toolResultContentBlocksForNextUserTurn
            ])
        }
        // END MULTI-TURN LOOP ===========================================

        return InteractiveClaudeResult(
            fullConcatenatedText: fullConcatenatedTextAcrossAllTurns,
            toolCallsExecuted: toolCallsExecutedAcrossAllTurns,
            totalTurns: numberOfTurnsExecuted,
            finalStopReason: lastObservedStopReason
        )
    }

    /// Builds the JSON body for one turn of the Interactive multi-turn loop.
    /// Wires in three best-practice features documented by Anthropic:
    ///
    ///   1. **Prompt caching**: `cache_control: ephemeral` on the last tool
    ///      and the system prompt. The tool manifest + system prompt are
    ///      identical across every turn of a single invocation, so caching
    ///      them saves ~90% of repeated input tokens (5-minute TTL).
    ///
    ///   2. **Context editing**: `clear_tool_uses_20250919` tells Anthropic's
    ///      server to prune old `tool_result` blocks once the conversation
    ///      exceeds 40K input tokens, keeping only the 3 most recent tool
    ///      uses. Replaces our previous ad-hoc client-side compression.
    ///
    ///   3. **No parallel tool calls**: `tool_choice.disable_parallel_tool_use`
    ///      matches Clicky's sequential cursor-fly-then-dispatch UX. Without
    ///      this, Claude may emit 3 tool_use blocks per turn that we then
    ///      have to run one at a time anyway.
    private func buildInteractiveRequestBody(
        toolsJSONArray: [[String: Any]],
        interactiveSystemPrompt: String,
        runningMessagesForNextTurn: [[String: Any]]
    ) -> [String: Any] {
        var toolsJSONArrayWithCacheControl = toolsJSONArray
        if !toolsJSONArrayWithCacheControl.isEmpty {
            toolsJSONArrayWithCacheControl[toolsJSONArrayWithCacheControl.count - 1]["cache_control"] = [
                "type": "ephemeral"
            ]
        }

        let systemPromptContentBlocksWithCacheControl: [[String: Any]] = [
            [
                "type": "text",
                "text": interactiveSystemPrompt,
                "cache_control": ["type": "ephemeral"]
            ]
        ]

        let contextEditingConfiguration: [String: Any] = [
            "edits": [
                [
                    "type": "clear_tool_uses_20250919",
                    "trigger": ["type": "input_tokens", "value": 40000],
                    "keep": ["type": "tool_uses", "value": 3],
                    "clear_at_least": ["type": "input_tokens", "value": 8000]
                ]
            ]
        ]

        let sequentialOnlyToolChoice: [String: Any] = [
            "type": "auto",
            "disable_parallel_tool_use": true
        ]

        return [
            "model": model,
            "max_tokens": 4096,
            "stream": true,
            "tools": toolsJSONArrayWithCacheControl,
            "tool_choice": sequentialOnlyToolChoice,
            "system": systemPromptContentBlocksWithCacheControl,
            "messages": runningMessagesForNextTurn,
            "context_management": contextEditingConfiguration
        ]
    }

    /// Parses the `Retry-After` header from a 429 response. Anthropic returns
    /// an integer number of seconds. Returns nil if the header is missing or
    /// non-numeric, in which case the caller should fall back to a default
    /// backoff.
    private static func parseRetryAfterSeconds(
        fromHTTPResponse httpResponse: HTTPURLResponse
    ) -> Int? {
        guard let retryAfterHeaderValue = httpResponse.value(forHTTPHeaderField: "Retry-After"),
              let retryAfterSecondsInteger = Int(retryAfterHeaderValue.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return retryAfterSecondsInteger
    }
}
