# Contributing to Mate

Thanks for helping! Issues and pull requests are welcome in English or Spanish.

## Build and test

Only the Xcode Command Line Tools (Swift 6) are needed.

```sh
scripts/test.sh                 # unit tests (MateCore, Swift Testing); --filter <regex> for a subset
scripts/check-localization.sh   # lists visible texts without an English translation
scripts/build.sh                # build/Mate.app (release, arm64, signed)
scripts/install.sh              # build, install to /Applications and launch
scripts/measure-idle.sh         # CPU and memory at rest (run before every release, see below)
```

`swift test` does not run Swift Testing when only the Command Line Tools are installed, so use `scripts/test.sh`.

Live checks without your real accounts: `build/Mate.app/Contents/MacOS/Mate --fake` runs two scripted Claude-shaped
accounts with no network and no keychain. Point `MATE_DATA_DIR` and `MATE_DEFAULTS_SUITE` at scratch values so a test
run never touches your real data and preferences. `--open-panel`, `--demo-alert`, `--open-usage` and the
`--snapshot*` switches are documented in `Sources/Mate/App/DebugCLI.swift`.

## Adding a provider

Each agent is one file in `Sources/Mate/Providers/` implementing the `Provider` protocol, with its response and log
parsing in `Sources/MateCore` and tests against anonymized fixtures in `Tests/MateCoreTests/Fixtures`. Two rules
are not negotiable:

- A token is sent only to its own provider's host.
- An account the agent is logged in with (`owner == .agent`) is never refreshed or written.

## Commit messages: Conventional Commits

Versions are computed from commit messages, so every commit follows [Conventional Commits](https://www.conventionalcommits.org):

```
type(optional scope): summary in imperative mood
```

| Type | Use it for | Effect on the next version |
|---|---|---|
| `feat` | a new feature | minor: 0.1.0 → 0.2.0 (1.2.0 → 1.3.0) |
| `fix` | a bug fix | patch: 0.1.0 → 0.1.1 |
| `perf` | a performance improvement | patch |
| `refactor`, `docs`, `style`, `test`, `build`, `ci`, `chore` | everything else | no release by itself |
| `type!:` or a `BREAKING CHANGE:` footer | an incompatible change | from 1.0 on, major: 1.2.0 → 2.0.0. While Mate is 0.x, minor |

Mate stays in 0.x until 1.0.0 is chosen on purpose (`scripts/release.sh --major`, or editing `VERSION` by hand):
a breaking change never jumps to 1.0.0 by itself.

Examples: `fix: keep the pill when the menu bar hides`, `feat(codex): in-app sign-in`, `docs: translate the readme`.

**Pull requests are squash-merged**: the whole PR lands as one commit whose message is the PR title, so the **PR
title** must follow this format. The commits inside your branch can be anything.

Run this once after cloning to have git reject messages that don't follow the format:

```sh
git config core.hooksPath scripts/hooks
```

## Releases (maintainers)

```sh
scripts/measure-idle.sh            # 0 % CPU and < 30 MB at rest, measured for 10 minutes
scripts/release.sh --dry-run       # shows the next version and its release notes
scripts/release.sh [notes.md]      # tests, bumps VERSION, signed DMG, tag vX.Y.Z, GitHub release
```

The release notes are generated from the `feat`, `fix` and `perf` commits since the last tag and are bilingual:
Spanish first, then a `<!-- en -->` line, then English (the app shows the half in its language, and the website
splits on it too). A notes file of your own must keep that separator. 0.x versions are published as GitHub
pre-releases; installed 0.x copies take them, 1.x copies only take stable releases. The asset is always `Mate.dmg`.

Every release must be signed with the project's identity: installed copies only accept updates signed with the same
certificate, and that is also what keeps macOS's "Always Allow" answer for the keychain items. `scripts/sign.sh`
uses the keychain in `MATE_SIGNING_KEYCHAIN` (by default Rambla's, `~/Desktop/Proyectos/scroll/.signing/`) and its
password from `RAMBLA_SIGNING_PASSWORD` or the login keychain item `io.github.coru29.Rambla.signing`. It never
creates an identity. Keep a private, offline backup of both.

`measure-idle.sh` launches the installed app (or `--app <path>`, or measures a running one with `--pid`), waits
60 s and samples `top` every second for 10 minutes with the panel closed; it fails above 0.1 % average CPU or 30 MB.
To measure without your real accounts:

```sh
MATE_DATA_DIR=$(mktemp -d) MATE_DEFAULTS_SUITE=mate-idle scripts/measure-idle.sh --app build/Mate.app -- --fake
```

## Translations

The interface is written in Spanish in the code (Rioplatense, with *vos*): those Spanish texts are the keys. The
English text lives in `Packaging/en.lproj/Localizable.strings`, which is also what a Mac in any other language shows;
`Packaging/es.lproj` maps each key to itself.

- In SwiftUI, a string literal (`Text("…")`, `Button("…")`, `Toggle("…", …)`) is translated by itself. Anywhere else
  (menus, alerts), wrap visible text in `String(localized: "…")`. Data that is never translated (names, paths) goes
  through `Text(verbatim:)`.
- After adding or changing a visible text, add its English line (and its Spanish one) and run
  `scripts/check-localization.sh`.

## Code

- Swift 6 toolchain, language mode 5, no third-party dependencies (only Apple frameworks and the system `libsqlite3`).
- Pure logic goes in `Sources/MateCore` with tests; AppKit, SwiftUI, network and keychain code in `Sources/Mate`.
- Mate must stay at 0 % CPU when idle: react to events, don't poll. No repeating timers; every timer sets a tolerance
  of at least 10 % of its interval.
