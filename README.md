# Clicky

An AI buddy that lives next to your cursor. It can see your screen, talk to you, point at stuff, and drive your apps.

Download it [here](https://www.clicky.so/) · [Original tweet](https://x.com/FarzaTV/status/2041314633978659092)

![Clicky](clicky-demo.gif)

## Two modes, one chord

Hold `ctrl + option`, say what you want, release. What happens depends on `CLICKY_INTERACTIVE_MODE`:

- **Show mode** (default) — Clicky explains what's on your screen and flies its blue cursor to point at things.
- **Interactive mode** (`CLICKY_INTERACTIVE_MODE=1`) — Clicky actually clicks, types, and navigates for you.

## Quick start (Claude Code)

```
Clone https://github.com/farzaa/clicky.git.
Read CLAUDE.md and walk me through setup.
```

## Manual setup

**Prereqs:** macOS 14.2+, Xcode 15+, Node 18+, Cloudflare account, API keys for [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), [ElevenLabs](https://elevenlabs.io).

### 1. Worker

```bash
cd worker
npm install
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
```

Set `ELEVENLABS_VOICE_ID` in `wrangler.toml` under `[vars]`.

Deploy: `npx wrangler deploy` → copy the `*.workers.dev` URL.

**Local dev:** create `worker/.dev.vars` with the same keys, then `npx wrangler dev` (serves on `http://localhost:8787`).

### 2. Point the app at your Worker

```bash
grep -rn "clicky-proxy" leanring-buddy/
```

Replace the URL in the matches (`CompanionManager.swift`, `AssemblyAIStreamingTranscriptionProvider.swift`).

### 3. Build

```bash
open leanring-buddy.xcodeproj
```

- Scheme: `leanring-buddy` (the typo is intentional, don't rename it)
- Signing & Capabilities: set your team
- Cmd+R

Menu bar icon → click → grant Microphone, Accessibility, Screen Recording.

## Interactive mode

### 1. Install the CLI

```bash
npm install -g agent-desktop@0.1.11
```

### 2. Set the env var in Xcode

**Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables**, add `CLICKY_INTERACTIVE_MODE = 1`, relaunch.

Console confirms on launch: `🤖 InteractiveModeConfiguration: ENABLED`.

### 3. Grant agent-desktop accessibility

First run prompts you, or do it now:

```bash
agent-desktop permissions --request
```

**System Settings → Privacy & Security → Accessibility** should show both `leanring-buddy` and `agent-desktop`.

### 4. Use it

Hold `ctrl + option`, speak, release.

- You hear "on it" immediately
- Amber cursor flies to each UI element
- One sentence summary at the end
- Escape cancels

**Works well:** Finder, Mail, Messages, TextEdit, System Settings, Xcode, Docker Desktop, App Store.

**Hit-or-miss:** browsers (Chrome, Safari, Arc) and Electron apps (Slack, VS Code, Cursor, Discord, Notion, Linear, Figma) — use Show mode for those.

### 5. Customize what it can do

Edit `leanring-buddy/InteractiveToolManifest.swift`. The `v1Tools` array declares every agent-desktop command Claude is allowed to call. Non-destructive by default (no `close-app`, `drag`, `set-value`, raw mouse, window resize).

## Troubleshooting

- **Pressing the chord still points at things** — `CLICKY_INTERACTIVE_MODE` not set. Check the console log on launch.
- **"agent-desktop not found"** — install it: `npm install -g agent-desktop@0.1.11`.
- **"I need accessibility permission for agent-desktop"** — separate grant from Clicky's. Run `agent-desktop permissions --request`.
- **Rate limit 429** — automatic retry via Anthropic's `Retry-After` header.
- **Hit max_tokens** — raise `max_tokens` in `ClaudeAPI.swift` or shorten the task.

## Architecture

Menu bar app, no dock icon. Two `NSPanel` windows: control panel dropdown + full-screen transparent cursor overlay. Push-to-talk → AssemblyAI websocket → transcript → one of two pipelines:

- **Show:** transcript + screenshot → Claude SSE → ElevenLabs TTS. `[POINT:x,y:label:screenN]` tags fly the cursor.
- **Interactive:** transcript → Claude `tool_use` multi-turn loop → `agent-desktop` CLI. Uses Anthropic's context editing (`clear_tool_uses_20250919`), prompt caching (`cache_control: ephemeral`), and `disable_parallel_tool_use`. Bounds fetched on-demand via `agent-desktop get @eN --property bounds`.

All three APIs proxied through a Cloudflare Worker holding the keys.

Full breakdown: [`CLAUDE.md`](CLAUDE.md).

## Project layout

```
leanring-buddy/          # Swift source (typo is permanent)
  CompanionManager.swift         # Central state machine
  ClaudeAPI.swift                # Claude streaming + tool_use loop
  InteractiveToolManifest.swift  # Tool allow-list
  AgentDesktopRunner.swift       # agent-desktop CLI wrapper
  InteractiveOutboundSafety.swift # Secret redaction
  OverlayWindow.swift            # Cursor overlay
worker/src/index.ts      # Cloudflare Worker (/chat, /tts, /transcribe-token)
CLAUDE.md                # Full architecture doc
```

## Contributing

PRs welcome. DM [@farzatv](https://x.com/farzatv) with feedback.
