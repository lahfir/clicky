# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude.

Clicky has **two modes**, selected by the `CLICKY_INTERACTIVE_MODE` environment variable (read once at launch via `InteractiveModeConfiguration`). There is only ONE push-to-talk chord, `ctrl + option`:

- **Show mode** (default — env var unset): Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay flies to and points at UI elements Claude references on any connected monitor, via `[POINT:x,y:label:screenN]` tags embedded in the response.
- **Interactive mode** (set `CLICKY_INTERACTIVE_MODE=1` in the Xcode scheme, relaunch): Clicky sends Claude the frontmost window screenshot + a sanitized accessibility-tree snapshot from the `agent-desktop` CLI, and exposes agent-desktop commands as Claude tools via Anthropic's native `tool_use` API. Claude orchestrates a multi-turn loop (snapshot → decide → act → snapshot → ...) and Clicky dispatches each tool call to the external CLI, narrating each action via TTS. The tool manifest is the authoritative allow-list — Claude cannot call tools not in the manifest. v1 is non-destructive (no `close_app`, no `drag`, no raw `set_value`, etc.).

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 4.6 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support. Show mode captures all displays; Interactive mode captures only the frontmost window of the target app.
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap. **One chord only** (`ctrl + option`). The env var `CLICKY_INTERACTIVE_MODE` decides what that chord does on release — Show pipeline or Interactive pipeline.
- **Element Pointing (Show mode)**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Desktop Automation (Interactive mode)**: Clicky spawns the external [`agent-desktop`](https://github.com/lahfir/agent-desktop) CLI via `Process()` to capture accessibility-tree snapshots and dispatch actions (click/type/focus/scroll/launch/etc.). Each agent-desktop command is exposed to Claude as a `tool_use` capability; Claude orchestrates in a multi-turn loop. The tool manifest in `InteractiveToolManifest.swift` is the authoritative allow-list.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

**Interactive Mode — Tool-Use over Tag Grammar**: Interactive mode uses Anthropic's native `tool_use` API with a multi-turn loop, NOT a custom tag grammar. Each agent-desktop CLI command is declared as a Claude tool in `InteractiveToolManifest.swift`. Claude picks tools, calls them, Clicky dispatches to `AgentDesktopRunner`, returns `tool_result`, Claude continues. The tool manifest is the authoritative allow-list — to change what Claude can do, edit the manifest. **No hardcoded verb filtering, no transcript-intent overlap checks, no tag tokenizer.** The LLM decides what to do; Clicky provides tools.

**Interactive Mode — Single Chord + Env Var Toggle**: Clicky has exactly ONE push-to-talk chord, `ctrl + option`. The mode is controlled by the `CLICKY_INTERACTIVE_MODE` environment variable, read once at app launch by `InteractiveModeConfiguration.isEnabled`. Show mode is the default; set the env var in the Xcode scheme to flip the chord's release handler to the Interactive pipeline. No second chord, no UI toggle, no UserDefaults drift. The env var approach was chosen after rejecting a two-chord design that collided with common `cmd+shift+X` app shortcuts and created confusing muscle memory. The tradeoff: toggling modes requires a relaunch. That's fine because it's a developer/power-user knob, not a per-invocation choice.

**Interactive Mode — Outbound Data Sanitization**: Before the accessibility snapshot leaves the machine (via the existing `/chat` Worker route), `InteractiveOutboundSafety` strips values from secure text fields (`AXSecureTextField`), credential-manager apps (1Password/Bitwarden/Keychain Access bundle IDs), and any string matching a credential-pattern regex (OpenAI `sk-`, Stripe `sk_`/`rk_live_`, GitHub `ghp_`/`gho_`, AWS `AKIA`, Google `AIza`, PEM headers, JWTs). Same safety is applied to `type` tool payloads at dispatch time — Claude's refusal comes back as a `tool_result` error that the model can adapt to.

**Interactive Mode — Silent Cursor-Driven Execution**: Claude is instructed to emit no text between `tool_use` blocks; the cursor overlay is the visual affordance. Before each tool dispatch, `CompanionManager.flyCursorAndDispatchInteractiveToolCall` extracts the first `@eN` ref from the args, queries its bounds via `agent-desktop get @eN --property bounds` (~30ms), converts the AX coordinates to AppKit global, sets `detectedElementScreenLocation`, and sleeps 700ms so the overlay's bezier flight animation lands before the action fires. Any text Claude emits before a tool call is discarded; only the trailing text block after `end_turn` is spoken via `ElevenLabsTTSClient.speakTextAndAwaitCompletion`, capped at 60 characters. Escape cancels in-flight execution via a global `NSEvent.addGlobalMonitorForEvents` listener installed only during execution.

**Interactive Mode — Stale Tool Result Compression**: Snapshot JSON is 200–300KB per invocation. Within a single multi-turn `analyzeInteractiveRequest` loop, `ClaudeAPI.compressStaleInteractiveToolResults` walks the accumulated message history after each new `tool_result` append and replaces every older tool_result whose content exceeds 2000 bytes with a short placeholder, keeping the linkage to its `tool_use_id` intact. Only the latest snapshot survives in-context, which keeps per-turn tokens bounded and prevents the Anthropic 30K tokens/minute rate limit from cutting off multi-step operations. Stale snapshot refs are useless anyway because UI mutations invalidate them.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1026 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~220 | Screenshot capture using ScreenCaptureKit. `captureAllScreensAsJPEG()` is the existing multi-display method — unchanged, used by Show mode. `captureFrontmostWindowAsJPEG(targetProcessIdentifier:)` is the new sibling used by Interactive mode: filters `SCShareableContent.windows` by PID, picks the frontmost visible window, captures via `SCContentFilter(desktopIndependentWindow:)`, applies the same 1280 max-edge cap, returns a single `CompanionScreenCapture`. DPI scale is derived from the window's containing `SCDisplay` (pixels/points ratio). |
| `BuddyDictationManager.swift` | ~870 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. **Also hosts** `enum BuddyPushToTalkShortcut` with the single `ctrl + option` chord. `ShortcutTransition` is a plain `.none/.pressed/.released` enum — mode selection lives in `InteractiveModeConfiguration`, not in the chord parser. |
| `InteractiveModeConfiguration.swift` | ~60 | Reads the `CLICKY_INTERACTIVE_MODE` environment variable at first access and exposes `InteractiveModeConfiguration.isEnabled: Bool` as a lazy static. The entire mode-toggle surface: one env var, one accessor, one log line at launch. `CompanionManager.handleShortcutTransition` checks this on push-to-talk release and routes to either the Show pipeline or the Interactive pipeline. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `InteractiveToolManifest.swift` | ~450 | **Interactive mode tool manifest.** Declarative Swift structs that encode the v1 non-destructive agent-desktop commands as Anthropic `tool_use` tools. Contains `InteractiveTool`, `InteractiveToolInputSchema`, `InteractiveToolProperty`, `InteractiveToolCall`, `InteractiveToolCallArgument`, `InteractiveToolResult`, and `InteractiveToolDispatcher` which maps each tool call to the corresponding `AgentDesktopRunner` method. **Editing this file is how you change what Claude can do in Interactive mode.** |
| `InteractiveOutboundSafety.swift` | ~230 | **Interactive mode outbound data sanitization.** Pure-Foundation static namespace. Strips values from secure text fields, credential-manager apps, and secret-pattern-matching strings in accessibility snapshots before they leave the machine. Also exposes `containsSecret(_:)` used by the `type` tool dispatch to refuse payloads that look like API keys, JWTs, PEM-formatted keys, etc. Zero UI, zero networking, zero hardcoded intent checks. |
| `AgentDesktopRunner.swift` | ~950 | **Interactive mode subprocess bridge.** `actor`-based wrapper around the external `agent-desktop` CLI. Discovers the binary via PATH + common install locations, version-pins to `0.1.11` minimum, probes accessibility permission via `agent-desktop status`, and exposes typed async methods for each allow-listed verb (`snapshot`, `click`, `type`, `press`, `focus`, `scroll`, `launchApp`, `listApps`, `find`, etc.). All arguments pass via `Process.arguments` as a `[String]` array — never shell-interpolated. Per-invocation timeouts via detached watchdog Tasks. Non-JSON stdout is sanitized through the secret-redaction helper before being wrapped in a thrown error so keys can never leak into logs or analytics. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~132 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions. |
| `ClaudeAPI.swift` | ~600 | Claude vision API client. Show mode uses `analyzeImageStreaming(...)` (SSE text streaming, `max_tokens: 1024`). Interactive mode uses the sibling `analyzeInteractiveRequest(...)` which adds multi-turn `tool_use` loop support: sends the tool manifest + scoped screenshot + sanitized snapshot, streams both text deltas (via `onTextChunk` callback) AND `tool_use` blocks (via `onToolUseStart` callback which returns an `InteractiveToolResult`), then continues the conversation until `stop_reason: end_turn`. Hard loop cap of 20 iterations. `max_tokens: 4096` for Interactive. Both methods coexist; Show mode is byte-for-byte untouched. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~240 | ElevenLabs TTS client. `speakText(_:)` is the existing fire-and-forget method (returns when playback *starts*) — unchanged, used by Show mode. `speakTextAndAwaitCompletion(_:)` is a new sibling method used by Interactive mode: creates a fresh private `AudioPlayerFinishDelegate` adapter, stores a `CheckedContinuation` under an `NSLock`, calls `player.play()`, and awaits the delegate callback. Ensures at-most-once continuation resume across the delegate-finish, decode-error, `stopPlayback()`, and `play()==false` paths. Exposes `isPlaying` for transient cursor scheduling. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `worker/src/index.ts` | ~142 | Cloudflare Worker proxy. Three routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token). |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
