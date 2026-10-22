# Security policy

Mate reads the sessions your AI agents left on the Mac (tokens in files and in the keychain), sends them to those
agents' servers to read your usage, and updates itself. All of that deserves care, so security reports are very welcome.

## Reporting a vulnerability

Please report it **privately** through [GitHub's private vulnerability reporting](https://github.com/Coru29/mate/security/advisories/new)
instead of opening a public issue. Spanish or English is fine. You will get an answer within a few days, and a fix
will be released as soon as possible with credit to you (unless you prefer otherwise).

Only the latest release is supported.

## What Mate does and does not do

- **Tokens go only to their own provider**: Claude's to `api.anthropic.com` and `platform.claude.com`, Codex's to
  `chatgpt.com` and `auth.openai.com`, Cursor's to `api2.cursor.sh`, Gemini CLI's to `cloudcode-pa.googleapis.com`,
  Copilot's to `api.github.com`, and the Grok management key to `management-api.x.ai`. Requests use an ephemeral
  `URLSession` (no cookies, no disk cache) and a redirect to another host is refused.
- **Accounts an agent is logged in with are read-only**: Mate never refreshes or rewrites their tokens. Cursor,
  Gemini CLI and Copilot are always read-only. The planned "Use in Claude Code" switch (not built yet) will be the
  only exception: on an explicit click it will write the chosen account into Claude Code's keychain item and
  `~/.claude.json`, keeping a copy to undo it.
- **Tokens Mate owns** (accounts the agent stopped using, or added with Mate's own sign-in) and the Grok key live
  only in the keychain, under `io.github.coru29.Mate.<provider>`. Nothing secret is written to disk or to the logs.
- **Mate's saved copies are as exposed as the agents' own sessions.** Mate creates its keychain items through
  `/usr/bin/security`, so they live in your login keychain with Apple's `security` tool in their access list: any
  process running as your user can read them with `security find-generic-password -w` without a prompt. That is the
  same exposure as Claude Code's own `Claude Code-credentials` item (read the same way) and Codex's plaintext
  `~/.codex/auth.json`: the keychain keeps them out of plain files, not away from other software you run.
- **No telemetry.** Besides the providers, the only network request is the update check: `api.github.com/repos/Coru29/mate/releases`
  shortly after launch and once a day (it can be turned off in Settings → Updates), and the DMG download from
  GitHub when you accept an update.
- **Updates are installed only if the downloaded app satisfies the running app's code-signing designated
  requirement** (same bundle id and same certificate). Anything else is refused.
- Data in `~/Library/Application Support/Mate/`: accounts (ids, emails, names, no tokens), usage samples, log read
  offsets and daily token totals per model. Nothing leaves the Mac.

Especially interesting reports: a way to make Mate send a token to another host, to make it refresh or overwrite an
agent's session, or to make the updater install code that is not signed by the project.
