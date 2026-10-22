<p align="center">
  <img src="Packaging/AppIcon-preview.png" width="160" alt="Mate icon">
</p>

<h1 align="center">Mate</h1>

<p align="center">
  A free, open-source macOS app that shows <b>how much is left of your AI agents' usage limits</b>, right by the notch.
</p>

<p align="center"><a href="https://mate-mac.app"><b>mate-mac.app</b></a> · <a href="README.es.md">Leer en español</a></p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-lightgrey" alt="macOS 14+">
</p>

---

While an agent is working, a small ring next to the notch shows the tightest limit of the one you are using (the 5-hour session, the week…), colored by pace. Hover over the notch and a black panel drops out of it with every meter, its reset time and whether you are on track or about to run out. Alerts slide down from the notch at 75, 90 and 100 %.

In Uruguay, *mate* is passed around and refilled over and over, a bit like a usage quota; in English a *mate* is a companion.

Mate is inspired by [Agent Limit](https://agentlimit.app), a well-made paid app that had the idea first: if you want a polished, supported product, go buy it. Mate is an independent open-source take on the same idea, for **every agent and several accounts per agent**. It shares no code with it.

> The interface follows your Mac's language: Spanish or English (any other language gets English). It can also be chosen in Settings → General.

## Features

- **Pill by the notch**: a ring with the percentage of the tightest window of the active agent; it shows up while an agent is writing its session logs and hides when nothing is running (or always, if you prefer).
- **Panel on hover**: session and weekly meters (plus Opus/Sonnet, billing cycle, monthly budget or daily quotas when the provider has them), reset times, pace, the project you are in and a live session row with elapsed time and tokens. Swipe sideways with two fingers or click the dots to go through your accounts. Right-click for Usage, Settings, Refresh now, Pause and Quit.
- **Pace**: *on track*, *going fast*, *runs out at 16:40* (a projection from the last hour), *limit reached*.
- **Alerts from the notch** when a window crosses 75 / 90 / 100 % and when it resets; thresholds and providers can be changed, and system notifications are optional.
- **Usage window**: tokens per day for the last 7 days and a 30-day breakdown by model with an estimated API-price cost, from the agents' local logs.
- **Several accounts per agent**: picked up automatically when you `/login` with another account (Mate keeps a copy of the previous one), added with the provider's own sign-in (Claude and Codex), or by pointing at another `CLAUDE_CONFIG_DIR` / `CODEX_HOME`. Rename, color, hide or delete them.
- **Macs without a notch and external displays**: Mate draws its own notch.
- **Light**: native Swift, no polling. It reacts to file-system events and wakes up only to fetch usage (every 5 minutes while an agent is active, every 30 otherwise). About 0 % CPU and ~10 MB of memory at rest.
- *Coming soon:* **Use in Claude Code**, a one-click switch of Claude Code's active account.

## Providers

| Agent | Where Mate reads the session | What it asks, and where |
|---|---|---|
| Claude (Claude Code) | Keychain item `Claude Code-credentials`, identity in `~/.claude.json` | Usage windows from `api.anthropic.com` (`/api/oauth/usage`); token refresh (only accounts Mate owns) at `platform.claude.com`. Token counts from `~/.claude/projects/**/*.jsonl` |
| Codex | `~/.codex/auth.json` (or `$CODEX_HOME`) | Usage from `chatgpt.com` (`/backend-api/wham/usage`); token refresh (only accounts Mate owns) at `auth.openai.com`. Token counts from `~/.codex/sessions` |
| Cursor | Cursor's `state.vscdb` (read only) | Current billing period from `api2.cursor.sh` |
| Gemini CLI | `~/.gemini/oauth_creds.json` (read only) | Daily quota per model from `cloudcode-pa.googleapis.com` |
| GitHub Copilot | The Copilot apps' token in `~/.config/github-copilot`, else `gh auth token` (read only) | Premium requests quota from `api.github.com` |
| Grok | No local session: a management key and team id you enter in Settings → Grok | Monthly API spend from xAI's management API (`management-api.x.ai`), against the budget you set |

> **Warning: these are undocumented endpoints.** None of them is an official, public API for third parties: they are the calls the agents' own apps and dashboards make. They can change or stop working at any time, and a provider could object to them being used this way. Each provider is isolated in its own file so it can be fixed in an update. Use Mate at your own risk.

## Privacy

- **Each token goes only to its own provider's server** (the table above). Redirects to another host are refused. The only other connection is the update check, to `api.github.com` (and GitHub's download servers when you accept an update).
- **No telemetry, no accounts, no analytics.** Nothing about you leaves the Mac.
- **Accounts an agent is using are read-only.** Mate never refreshes or rewrites the token of the account Claude Code or Codex is logged in with (refresh tokens rotate: doing so would log the agent out). If that token has expired, Mate waits for the agent to refresh it and meanwhile shows the last data with "N min ago". Cursor, Gemini CLI and Copilot are always read-only.
- **Accounts Mate owns** (a previous account the agent stopped using, or one added with "Add Account…") keep their tokens only in Mate's own keychain items (`io.github.coru29.Mate.<provider>`), and Mate refreshes them. Deleting such an account deletes Mate's copy and never touches the agent's session.
- **What the switch writes (coming soon).** "Use in Claude Code" will be the only place where Mate writes to an agent's session: it will replace Claude Code's keychain item `Claude Code-credentials` and the visible identity (`oauthAccount`) in `~/.claude.json` with the chosen account, after saving a copy to undo it, and it asks before the first time. It is not built yet.
- Data (accounts without tokens, usage samples, daily token totals) lives in `~/Library/Application Support/Mate/`; preferences in the `io.github.coru29.Mate` defaults domain.

See [SECURITY.md](SECURITY.md).

## Requirements

macOS 14 Sonoma or later on Apple silicon.

## Install

1. Download **[Mate.dmg](https://github.com/Coru29/mate/releases/latest/download/Mate.dmg)** from [Releases](https://github.com/Coru29/mate/releases) (or build it, below) and drag **Mate** to Applications.
2. Mate is not notarized by Apple, so macOS will not open it the first time. **Right-click the app → Open** (on recent macOS, go to **System Settings → Privacy & Security** and click **Open Anyway**), or run `xattr -dr com.apple.quarantine /Applications/Mate.app`.
3. A short guide finds the agents signed in on your Mac. When macOS asks **"Mate wants to access … in your keychain"** (for Claude Code's item), enter your password and click **Always Allow**: Mate reads that item, and with "Always Allow" macOS doesn't ask again, not even after updates (they are signed with the same certificate).

Mate has no Dock icon and no menu-bar icon: it lives in the notch. Opening it again from Applications or Spotlight opens Settings.

### Updates

Mate checks GitHub shortly after it starts and once a day (Settings → Updates turns it off). When a new version is out, it asks; it downloads the release, verifies it is signed with the same certificate as the running app, replaces itself and reopens. Versions 0.x are published as GitHub pre-releases, and 0.x copies take them.

## Build from source

Only the Xcode **Command Line Tools** are needed (Swift 6); Xcode itself is not required.

```sh
git clone https://github.com/Coru29/mate && cd mate
scripts/test.sh                 # unit tests (Swift Testing)
scripts/check-localization.sh   # every visible text has its English line
scripts/build.sh                # build/Mate.app, signed
scripts/dmg.sh                  # build/Mate.dmg
scripts/install.sh              # copy to /Applications and launch
build/Mate.app/Contents/MacOS/Mate --fake   # scripted accounts, no network, no keychain
```

**Signing**: `scripts/sign.sh` signs with the project's identity ("Rambla Local Signing", shared with [Rambla](https://github.com/Coru29/rambla)) and never creates one. **Forks need their own identity**: create a self-signed code-signing certificate in a keychain of your own and point `MATE_SIGNING_KEYCHAIN` at it (its password in `RAMBLA_SIGNING_PASSWORD`). A build signed with another identity works, but macOS asks for the keychain permission again, and it does not accept the official updates (nor do official copies accept it).

**Versions and releases**: commits follow [Conventional Commits](https://www.conventionalcommits.org) and the version is computed from them. See [CONTRIBUTING.md](CONTRIBUTING.md).

## How it works

- `MateCore` is a pure Swift library: the model, pace, alert thresholds, token ownership rules, the parsers of every provider's responses and logs, and the daily aggregates. It is covered by unit tests with anonymized fixtures.
- The app (AppKit + SwiftUI) draws the notch in a non-activating panel above the menu bar that only takes mouse events where something is visible. Activity comes from one FSEvents stream over the agents' session folders; usage fetches, resets and the "idle" state are one-shot timers with a wide tolerance, and the background fetches and the daily update check go through `NSBackgroundActivityScheduler`. No repeating timers.
- Each provider implements one protocol (find sessions, read the identity, fetch usage, refresh when Mate owns the token, read logs incrementally). Adding an agent is adding a file.

## Credits

Inspired by [Agent Limit](https://agentlimit.app). Provider details learned from Agent Limit's behavior and from the open-source [CodexBar](https://github.com/steipete/CodexBar).

## License

[MIT](LICENSE)
