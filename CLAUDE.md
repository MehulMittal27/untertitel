# CLAUDE.md — Untertitel (fork of v2s)

## What this repo is

This is Mehul's fork of [franklioxygen/v2s](https://github.com/franklioxygen/v2s), a macOS menu-bar app
that captures audio from another app, transcribes it on-device and shows translated subtitles in an overlay.

We are turning it into **Untertitel**: live **German → English** subtitles for video calls (Zoom, Teams, Meet,
WhatsApp, Webex…), switched on and off with **one global hotkey**, designed to run **alongside Wispr Flow**
(Wispr owns the microphone; we only tap the call app's speaker output). Personal tool first, possibly a product later.

## Read these before writing code

1. `plan/SPEC.md` — what we are building and why (requirements have IDs like R3; cite them in commits/PRs).
2. `plan/CODEMAP.md` — where things live in the v2s codebase and the seams to change. **Verify line numbers; they drift.**
3. `plan/ROADMAP.md` — milestones M0–M6. Work **one milestone at a time**, in order, unless told otherwise.
4. `plan/SONIOX.md` — only needed for M5 (cloud engine).
5. `plan/TEST-CHECKLIST.md` — manual checks Mehul runs on his Mac after each milestone.

## Environment

- macOS 26 or newer, Apple silicon, Xcode 26. Speech transcription needs macOS 26 (SpeechAnalyzer).
- Build: `xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug build`
- Tests: try `swift test` first, then `xcodebuild -project v2s.xcodeproj -scheme v2s test`. **In M0, record here
  which command works**, so later sessions don't rediscover it.
- Dependencies: Swift Package Manager (Sparkle is the only third-party package today).

## Working rules

- **One milestone = one branch = one PR-sized change.** Branch names: `m1-global-hotkey`, `m2-call-app-autodetect`, …
- **Build and run the tests before saying a milestone is done.** Add unit tests for new logic (the repo already has
  a good test suite in `Tests/V2STests`; follow its style).
- Each milestone in the roadmap is marked **[upstream]** or **[fork-only]**.
  - **[upstream]** branches must be acceptable as a pull request to `franklioxygen/v2s`: no changes to `plan/`,
    `CLAUDE.md`, app name or bundle ID; no German-only defaults; follow existing code style; every user-facing string
    goes through `AppLocalization` (add keys the same way existing ones are added); no new dependencies without asking.
  - **[fork-only]** branches can change defaults, naming and add the cloud engine.
- **Minimal seams, no big refactors.** `AppModel.swift` (~3.4k lines) and `LiveTranscriptionSession.swift` (~3.9k lines)
  are large and subtle (caption queueing, draft promotion, translation timeouts). Add narrow hooks; do not reorganise them.
- **Privacy is a hard requirement (R9–R11):**
  - Never write audio to disk. Never log transcript or translation text outside `#if DEBUG`.
  - API keys live in the Keychain only — never in `AppSettings`, UserDefaults, logs, or the repo.
  - The on-device path must keep working with no network; the cloud engine is optional and off by default.
- `AppSettings` has a custom decoder: **every new field needs a `decodeIfPresent` fallback** so old settings files load.
- `TranslationSession` is view-anchored (`.translationTask` via `v2sTranslationHost`); don't try to use Apple
  Translation outside the existing `TranslationCoordinator` path.
- The app is `LSUIElement` (no Dock icon by default). Global hotkeys must work while another app is frontmost.

## Ask Mehul before

- Adding any dependency, changing the bundle identifier, signing, entitlements, Sparkle/update feeds or `scripts/release.sh`.
- Deleting or weakening existing tests.
- Anything that sends audio or text off the machine other than the opt-in Soniox engine in M5.

## What you can't verify here

You can't join a real call, click permission dialogs, or hear audio. At the end of each milestone, list the manual
checks from `plan/TEST-CHECKLIST.md` that apply, so Mehul can run them on his Mac.
