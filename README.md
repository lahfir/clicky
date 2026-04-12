# Hi, this is Clicky.
It's an AI buddy that lives as a companion next to your cursor. It can see your screen, talk to you, and even point at stuff. Kinda like having a real teacher next to you.

Download it [here](https://www.clicky.so/) for free.

Here's the [original tweet](https://x.com/FarzaTV/status/2041314633978659092) that kinda blew up for a demo for more context.

![Clicky — an ai buddy that lives on your mac](clicky-demo.gif)

**Clicky has two modes.** One push-to-talk chord (`ctrl + option`), one environment variable to flip between modes:

- **Show mode** (default) — the original. Clicky watches your screen, explains what you're looking at, and flies its blue cursor around to point at specific UI elements. Great for "what does this button do?" and "how do I turn off this setting?"
- **Interactive mode** (set `CLICKY_INTERACTIVE_MODE=1` in your Xcode scheme and relaunch) — the new one. Clicky actually *drives* the app for you: clicks, types, navigates, opens things. Hold the chord, say what you want, release. You hear "on it", the amber cursor flies to each element as Clicky works, and at the end Clicky tells you what happened in one sentence. It's powered by [agent-desktop](https://github.com/lahfir/agent-desktop) (a separate CLI you install once) and Anthropic's native `tool_use` API with prompt caching and server-side context editing. Non-destructive by default — edit `InteractiveToolManifest.swift` to change what Clicky is allowed to do.

This is the open-source version of Clicky for those that want to hack on it, build their own features, or just see how it works under the hood.

## Get started with Claude Code

The fastest way to get this running is with [Claude Code](https://docs.anthropic.com/en/docs/claude-code).

Once you get Claude running, paste this:

```
Hi Claude.

Clone https://github.com/farzaa/clicky.git into my current directory.

Then read the CLAUDE.md. I want to get Clicky running locally on my Mac.

Help me set up everything — the Cloudflare Worker with my own API keys, the proxy URLs, and getting it building in Xcode. Walk me through it.
```

That's it. It'll clone the repo, read the docs, and walk you through the whole setup. Once you're running you can just keep talking to it — build features, fix bugs, whatever. Go crazy.

## Manual setup

If you want to do it yourself, here's the deal.

### Prerequisites

- macOS 14.2+ (for ScreenCaptureKit)
- Xcode 15+
- Node.js 18+ (for the Cloudflare Worker)
- A [Cloudflare](https://cloudflare.com) account (free tier works)
- API keys for: [Anthropic](https://console.anthropic.com), [AssemblyAI](https://www.assemblyai.com), [ElevenLabs](https://elevenlabs.io)

### 1. Set up the Cloudflare Worker

The Worker is a tiny proxy that holds your API keys. The app talks to the Worker, the Worker talks to the APIs. This way your keys never ship in the app binary.

```bash
cd worker
npm install
```

Now add your secrets. Wrangler will prompt you to paste each one:

```bash
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
```

For the ElevenLabs voice ID, open `wrangler.toml` and set it there (it's not sensitive):

```toml
[vars]
ELEVENLABS_VOICE_ID = "your-voice-id-here"
```

Deploy it:

```bash
npx wrangler deploy
```

It'll give you a URL like `https://your-worker-name.your-subdomain.workers.dev`. Copy that.

### 2. Run the Worker locally (for development)

If you want to test changes to the Worker without deploying:

```bash
cd worker
npx wrangler dev
```

This starts a local server (usually `http://localhost:8787`) that behaves exactly like the deployed Worker. You'll need to create a `.dev.vars` file in the `worker/` directory with your keys:

```
ANTHROPIC_API_KEY=sk-ant-...
ASSEMBLYAI_API_KEY=...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...
```

Then update the proxy URLs in the Swift code to point to `http://localhost:8787` instead of the deployed Worker URL while developing. Grep for `clicky-proxy` to find them all.

### 3. Update the proxy URLs in the app

The app has the Worker URL hardcoded in a few places. Search for `your-worker-name.your-subdomain.workers.dev` and replace it with your Worker URL:

```bash
grep -r "clicky-proxy" leanring-buddy/
```

You'll find it in:
- `CompanionManager.swift` — Claude chat + ElevenLabs TTS
- `AssemblyAIStreamingTranscriptionProvider.swift` — AssemblyAI token endpoint

### 4. Open in Xcode and run

```bash
open leanring-buddy.xcodeproj
```

In Xcode:
1. Select the `leanring-buddy` scheme (yes, the typo is intentional, long story)
2. Set your signing team under Signing & Capabilities
3. Hit **Cmd + R** to build and run

The app will appear in your menu bar (not the dock). Click the icon to open the panel, grant the permissions it asks for, and you're good.

### Permissions the app needs

- **Microphone** — for push-to-talk voice capture
- **Accessibility** — for the global keyboard shortcut (both chords) and (if you use Interactive mode) for agent-desktop to drive other apps
- **Screen Recording** — for taking screenshots when you use the hotkey
- **Screen Content** — for ScreenCaptureKit access

> Interactive mode needs a **separate** Accessibility grant for the `agent-desktop` CLI itself. See the [Interactive Mode](#interactive-mode) section for the full setup — it's an extra two clicks on first use.

## Interactive Mode

One chord, one env var. You still hold `ctrl + option` to talk to Clicky. If `CLICKY_INTERACTIVE_MODE` is set in your environment, releasing the chord fires the interactive pipeline (agent-desktop + Anthropic tool_use). If it's not set, Clicky is in Show mode and behaves exactly like it always has.

**How it feels.** The moment you release the chord, Clicky says "on it" so you know it heard you. Then it works silently — the amber cursor flies to each UI element it's about to touch, clicks happen, the tree changes, the cursor flies to the next thing. When it's done it speaks one short sentence about what it accomplished. No "taking a snapshot, now clicking the button, now…" play-by-play. Press Escape mid-sequence to cancel.

**What it can do.** The tool manifest in `InteractiveToolManifest.swift` is the authoritative allow-list — Anthropic only lets Claude call tools you declared. v1 exposes a deliberately non-destructive subset: observation (`snapshot`, `screenshot`, `find`), navigation (`click`, `focus`, `scroll`, `hover`, `expand`/`collapse`), text entry (`type`, `press`, `select`, `check`/`uncheck`/`toggle`), and app lifecycle (`launch`, `focus-window`, `list-apps`). Things that ship in agent-desktop but aren't in the manifest on purpose: `close-app`, `drag`, `set-value`, `right-click`, `clear`, raw mouse events, window resize/move, clipboard writes. Want Clicky to send Slack messages or delete files? Add the tool to the manifest yourself — it's one entry in an array.

### Turn it on

Two steps. Install the CLI, then set the env var.

```bash
npm install -g agent-desktop@0.1.11
```

Then in Xcode: **Product → Scheme → Edit Scheme → Run → Arguments → Environment Variables**, add `CLICKY_INTERACTIVE_MODE` with value `1`, and relaunch. Accepted values are `1`, `true`, `yes`, `enabled`, `on` — anything else (including unset) means Show mode.

You'll see a line in the Xcode console on launch confirming which mode you're in: `🤖 InteractiveModeConfiguration: ENABLED` or `… DISABLED`.

To turn it off, unset the variable and relaunch. There's no UI toggle on purpose — the whole thing is one env var so there's exactly one place to change.

### Grant accessibility to agent-desktop

macOS treats `agent-desktop` as a completely separate binary from Clicky, so it needs its own Accessibility grant — a second checkbox next to Clicky's in the same System Settings pane. First time Clicky tries to run a tool, macOS will prompt you. Click through, done.

You can also grant it proactively:

```bash
agent-desktop permissions --request
```

To check later, open **System Settings → Privacy & Security → Accessibility**. You should see both `leanring-buddy` and `agent-desktop` as separate entries. Both need to be on.

### How to use it

Hold `ctrl + option`, say what you want, release. You'll hear "on it" immediately, then the cursor flies around while Clicky works. At the end Clicky speaks one sentence about what happened. Press Escape mid-sequence to cancel.

Things that work well: *"open Finder and go to Downloads"*, *"open TextEdit and type hello world"*, *"in Docker Desktop search for gemma"*, *"scroll down"*, *"open System Settings and go to Displays"*.

Things to know: browsers (Chrome, Safari, Arc) and Electron apps (Slack, VS Code, Cursor, Discord, Notion, Linear, Figma) have unreliable accessibility trees, so Interactive mode's results in those apps are hit-or-miss — Show mode is usually a better fit. Native macOS apps (Finder, Mail, Messages, TextEdit, System Settings, Xcode, Docker Desktop, App Store, etc.) work well.

### Customizing what it can do

The tool manifest lives in `leanring-buddy/InteractiveToolManifest.swift` as a single static array called `v1Tools`. It declares one generic `agent_desktop` tool whose description lists every CLI command Claude is allowed to invoke. Add a command to the description, remove one, tighten an input schema — that's the only place to edit. There's no separate Swift-side deny list; Anthropic's API enforces that Claude can only call tools you declared, and the dispatcher passes args through to the CLI verbatim.

### Performance tuning (Anthropic best practices)

Interactive mode uses three documented features that matter for multi-turn tool loops:

- **Context editing** (`clear_tool_uses_20250919` via the `context-management-2025-06-27` beta header) — Anthropic prunes stale `tool_result` payloads server-side once the conversation exceeds 40K input tokens, keeping the 3 most recent tool uses. Accessibility snapshots are 200–300 KB each, so this is load-bearing.
- **Prompt caching** — `cache_control: ephemeral` on the last tool definition and the system prompt. The manifest + prompt are stable across every turn, so caching saves ~90% of the repeated input tokens (5-minute TTL). Cached tokens also don't count toward rate limits.
- **`disable_parallel_tool_use`** — Clicky dispatches tools sequentially anyway (so the cursor has time to fly to each element), so we force Claude to emit one tool_use per turn instead of fighting over parallel calls.

On 429s Clicky honors Anthropic's `Retry-After` header verbatim and retries the same turn once. The Worker proxy forwards both headers (`anthropic-beta` upstream, `Retry-After` downstream) — check `worker/src/index.ts` if you're running your own proxy.

### Troubleshooting

- **Pressing ctrl+option still points at things instead of acting** — `CLICKY_INTERACTIVE_MODE` isn't set, or is set to something Clicky doesn't recognize as enabled. Check the Xcode console for the `InteractiveModeConfiguration:` log line on launch.
- **"Interactive mode needs agent-desktop"** — install the CLI (`npm install -g agent-desktop@0.1.11`).
- **"I need accessibility permission for agent-desktop"** — grant it in System Settings or run `agent-desktop permissions --request`. Separate entry from Clicky's own grant.
- **"The window kept changing — try again"** — Clicky lost track of the UI between observations. Just invoke again.
- **"I can only act on native desktop apps"** — frontmost app is a browser or Electron. Clicky falls through to Show mode.

## Architecture

If you want the full technical breakdown, read `CLAUDE.md`. But here's the short version:

**Menu bar app** (no dock icon) with two `NSPanel` windows — one for the control panel dropdown, one for the full-screen transparent cursor overlay. Push-to-talk streams audio over a websocket to AssemblyAI, then hands off to one of two pipelines based on `CLICKY_INTERACTIVE_MODE`:

- **Show pipeline:** transcript + multi-monitor screenshot → Claude via streaming SSE → ElevenLabs TTS. Claude embeds `[POINT:x,y:label:screenN]` tags in responses to make the blue cursor fly to specific UI elements.
- **Interactive pipeline:** transcript → Claude via streaming SSE with Anthropic's native `tool_use` API, a generic `agent_desktop` tool, `clear_tool_uses_20250919` server-side context editing, and `cache_control: ephemeral` on the system prompt and tool manifest. Each `tool_use` block extracts a `@eN` ref from the args, queries its screen bounds via `agent-desktop get @eN --property bounds`, flies the amber cursor to the element, then dispatches the CLI command. One summary sentence spoken at the end.

All three APIs (Claude, AssemblyAI tokens, ElevenLabs TTS) are proxied through a Cloudflare Worker that holds the real keys as secrets.

## Project structure

```
leanring-buddy/          # Swift source (yes, the typo stays)
  CompanionManager.swift    # Central state machine
  CompanionPanelView.swift  # Menu bar panel UI
  ClaudeAPI.swift           # Claude streaming client
  ElevenLabsTTSClient.swift # Text-to-speech playback
  OverlayWindow.swift       # Blue cursor overlay
  AssemblyAI*.swift         # Real-time transcription
  BuddyDictation*.swift     # Push-to-talk pipeline
worker/                  # Cloudflare Worker proxy
  src/index.ts              # Three routes: /chat, /tts, /transcribe-token
CLAUDE.md                # Full architecture doc (agents read this)
```

## Contributing

PRs welcome. If you're using Claude Code, it already knows the codebase — just tell it what you want to build and point it at `CLAUDE.md`.

Got feedback? DM me on X [@farzatv](https://x.com/farzatv).
