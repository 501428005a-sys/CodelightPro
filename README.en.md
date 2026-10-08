<div align="center">

<img src="docs/assets/icon.png" width="112" alt="CodelightPro icon">

# CodelightPro

**Let your agents do the work. Just glance up.**

A Dynamic Island for **Claude Code** and **Codex** on your Mac: see at a glance whether they're working,<br>
waiting for approval, or done. Approve commands right from the notch, and check your remaining quota anytime.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000?logo=apple&logoColor=white)](#install)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-F05138?logo=swift&logoColor=white)](Package.swift)
[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-3b82f6)](LICENSE)
[![Release](https://img.shields.io/github/v/release/501428005a-sys/CodelightPro?label=download&color=22c55e)](https://github.com/501428005a-sys/CodelightPro/releases/latest)

[简体中文](README.md) · **English**

<img src="docs/assets/hero.gif" width="860" alt="Screen recording: while Claude Code runs a task, the island in the notch changes color with its state and expands into an approval card when it asks for permission">

</div>

---

## Why

When Claude Code and Codex are both running, the real time sink isn't the waiting. It's **switching back to the terminal over and over to check whether they've stopped**. Maybe the task finished long ago, or maybe it's been stuck on a permission prompt for ten minutes.

CodelightPro hands that job to the strip at the top of your screen:

- 🟢 **Working**: a glow flows around the island, so you can get on with something else
- 🔴 **Needs approval**: the glow turns red and a notification pops up; click to approve
- 🔵 **Done**: the glow turns blue, so you know it's time to check the result

<table>
  <tr>
    <td align="center"><img src="docs/assets/strip-working.gif" width="260" alt="Working: a flowing green glow"><br><sub><b>Working</b></sub></td>
    <td align="center"><img src="docs/assets/strip-approval.gif" width="260" alt="Needs approval: a red glow"><br><sub><b>Needs approval</b></sub></td>
    <td align="center"><img src="docs/assets/strip-done.gif" width="260" alt="Done: a blue glow"><br><sub><b>Done</b></sub></td>
  </tr>
</table>

## Features

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/assets/approval.gif" alt="Screen recording: Claude Code asks to run git push origin main, the island expands into an approval card, and it collapses after Allow is clicked">
      <h3>Approve from the island</h3>
      When an agent wants to run a command, the approval card shows the tool, the project and the <b>full command</b>. Click Allow or Deny.
      You can still answer in the terminal as usual, and the card goes away by itself. Works with both Claude Code and Codex.
    </td>
    <td width="50%" valign="top">
      <img src="docs/assets/usage.gif" alt="Screen recording: clicking the island shows the 5-hour and weekly quotas for Codex and Claude Code with reset countdowns">
      <h3>All your quotas in one place</h3>
      5-hour quota, weekly quota and reset countdowns in a single panel.
      Codex works out of the box. Claude Code shows the same official percentages as <code>/status</code> after a one-time sign-in.
    </td>
  </tr>
</table>

### Island or floating window: drag to switch

<img src="docs/assets/modes.gif" width="640" alt="Screen recording: the floating window is dragged to the top center of the screen and morphs into the island, then dragged out again and turns back into a floating window">

Drag the floating window to the top center of the screen and it morphs into the notch. Press and drag the island down and it turns back into a window you can park in any corner.
Macs without a notch and external displays work too. The mode and screen you picked are remembered.

### Also

- **Project name**: the island shows the git project of the active session
- **Menu bar control center**: launch at login, auto-hide when idle, sounds, preferred display
- **Light and native**: a SwiftUI app whose always-on animations run in Core Animation and use almost no CPU
- **iPhone sync (optional)**: pair the Codelight iPhone app to see live status in the Dynamic Island and on the Lock Screen, and approve from your phone (see [below](#iphone-sync-optional))

> The interface is currently in Simplified Chinese only.

## Install

### Download

1. Download `CodelightPro-<version>.zip` from [Releases](https://github.com/501428005a-sys/CodelightPro/releases/latest), unzip it, and drag `CodelightPro.app` into Applications.
2. First launch: the app only has an ad-hoc signature and **is not notarized by Apple**, so macOS will block it. Open System Settings → Privacy & Security, scroll to the bottom and click **Open Anyway**. Or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/CodelightPro.app
   ```

3. A floating window appears in the top-right corner once it's running. Start a task in Claude Code or Codex and it lights up.

Requires macOS 13 or later. Universal binary for Apple silicon and Intel.

### Build from source

Requires Xcode 15+ or the matching Command Line Tools (Swift 5.9). No third-party dependencies.

```bash
git clone https://github.com/501428005a-sys/CodelightPro.git
cd CodelightPro
bash scripts/make_app.sh      # release build, packaged as CodelightPro.app (icon + ad-hoc signature)
open CodelightPro.app
```

For development you can also use `swift build` / `swift run`, or open `Package.swift` in Xcode.
`bash scripts/make_release.sh` builds a universal arm64 + x86_64 zip into `dist/`.

## Showing official Claude Code usage

Codex quotas are read locally with no setup. Claude subscription quotas only live on Anthropic's servers, so you need to sign in once:

- **Click "连接 Claude" (Connect Claude) in the panel** (recommended), or
- Run `bash scripts/setup_claude_token.sh` in a terminal (it runs `claude setup-token`)

The token is stored only on your Mac at `~/.codelightpro/token` with permission 600. Official usage then refreshes about every 60 seconds.

Credentials are looked up in this order: the `CLAUDE_CODE_OAUTH_TOKEN` environment variable → `~/.codelightpro/token` → the Claude Code CLI's own login (Keychain or `~/.claude/.credentials.json`) → the Claude desktop app's login cookie (macOS asks for Keychain access first, and you can decline).

## What it reads and writes

Part of the point of open-sourcing it: you can check that it doesn't do anything extra.

| Location | What happens |
|---|---|
| `~/.codex/`, `~/.claude/` | **Read-only** session state and local usage records. Your code is never read or uploaded |
| `~/.claude/settings.json` | Adds a few hooks that each append one status line, so "working / needs approval" is accurate. **Backed up first** to `settings.json.codelightpro-backup` |
| `~/.codex/hooks.json` | Adds one approval hook when approvals are on, also backed up first |
| `~/.codelightpro/` | Its own state, cache and token |
| Network | Only Anthropic's usage endpoints (`api.anthropic.com` / `claude.ai`). It connects to the relay you enter only if you set up iPhone sync. Codex quotas come from the local `codex app-server`; its tokens are never read |

The approval hook **never decides on its own**. If the app isn't running, approvals are turned off, you pick "在终端处理" (handle in terminal), or nobody answers within 5 minutes, it prints nothing and the agent shows its usual prompt.

## iPhone sync (optional)

The companion iPhone app **Codelight** shows live status in the Dynamic Island and on the Lock Screen, and lets you approve from your phone. Status goes through a relay service. You pair by scanning a QR code on your Mac, with no account needed. Only the status, project name and pending commands are synced.

The iPhone app and the relay service are **not open source and not part of this repository**. An iOS beta is coming soon. Without sync, CodelightPro runs entirely on your Mac.

## Known limitations

- Each tool tracks only **its most recently active session**.
- The interface is Simplified Chinese only for now.
- `claude setup-token` creates a long-lived token. If you get a 401 (expired or revoked), sign in again.

## Project layout

```
Sources/CodelightPro/
  AppDelegate.swift   Windows and panels: island / floating-window morphing, menu bar control center
  AppModel.swift      Global state and preferences
  Poller.swift        Polls every monitor every 2 seconds
  Monitors/           Reads ~/.codex and ~/.claude; Claude usage API; hook installation
  Services/           Relay sync client, launch at login, sounds
  UI/                 SwiftUI views; always-on animations (glow, pixel cat) use Core Animation
scripts/              Packaging, release, icon rendering, Claude token setup
```

## Contributing

Issues and PRs are welcome. Run `swift build` at least once after changing code, and attach a screenshot or recording for UI changes.
If you use an AI coding assistant, [AGENTS.md](AGENTS.md) covers the architecture and conventions.

## License

[GPL-3.0](LICENSE): free to use, modify and redistribute; modified versions you distribute must also be released under GPL-3.0.

Claude Code and Codex are products of Anthropic and OpenAI respectively. This project is not affiliated with either.
