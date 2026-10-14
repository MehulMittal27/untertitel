# CLAUDE.md — Untertitel (fork of v2s)

## What this repo is

This is Mehul's fork of [franklioxygen/v2s](https://github.com/franklioxygen/v2s), a macOS menu-bar app
that captures audio from another app, transcribes it on-device and shows translated subtitles in an overlay.

We are turning it into **Untertitel**: live subtitles for video calls (Zoom, Teams, Meet, WhatsApp, Webex…) from
any spoken language into a chosen one (German → English is the main use), switched on and off with **one global
hotkey**, designed to run **alongside Wispr Flow** (subtitles only tap the call app's speaker output). Since M7 it
also has a **Meeting mode**: in-person meetings through the microphone, transcribed with speaker labels, no
translation (`plan/MEETING.md`). Personal tool first, possibly a product later.

## Read these before writing code

1. `plan/SPEC.md` - what we are building and why (requirements have IDs like R3; cite them in commits/PRs).
2. `plan/CODEMAP.md` - where things live in the v2s codebase and the seams to change. **Verify line numbers; they drift.**
3. `plan/ROADMAP.md` - milestones M0–M6. Work **one milestone at a time**, in order, unless told otherwise.
4. `plan/OPENAI-TRANSLATE.md` and `plan/SONIOX.md` - the two cloud engines, text only.
5. `plan/MEETING.md` - M7 meeting mode: design, the speech-to-text comparison, FluidAudio, known issues.
6. `plan/TEST-CHECKLIST.md` - manual checks Mehul runs on his Mac after each milestone.

## Environment

- macOS 26 or newer, Apple silicon, Xcode 26. Speech transcription needs macOS 26 (SpeechAnalyzer).
- Build: `scripts/build-app.sh` (Xcode 26.6 on macOS 26.5.2), or `scripts/build-app.sh --release` for the optimized
  app; each run removes the other configuration's copy. It runs
  `xcodebuild -project v2s.xcodeproj -scheme v2s -configuration Debug build` into one fixed folder, so the app only
  ever exists at `~/untertitel-build/Build/Products/Debug/Untertitel.app`, and it warns when another copy exists or
  the running app is older than the build. Do not call `xcodebuild` with a different build folder: a second
  `Untertitel.app` is a stale build waiting to be launched. The app runs as the process `Untertitel`; the Xcode
  target, scheme and Swift module are still called `v2s`.
- Tests: `swift test` (verified in M0). `xcodebuild ... test` does not work: the `v2s` scheme has no test action.
  Do not run `swift test` and `xcodebuild` at the same time on a fresh clone - both download Sparkle and collide.
- Upstream's `OverlayWindowControllerTests.testRecordingVisibilityUsesNewPublishedStyleValue` used to fail (on
  macOS 26.5.2 a window's `sharingType` set back to `.readOnly` after `.none` read `.none`); since 14 Oct 2026 it
  passes. Expect 0 failures and 4 skipped: three tap real app audio (`V2S_AUDIO_TAP_TESTS=1`), and
  `MeetingEndToEndTests` runs the real meeting models on a recording (`UNTERTITEL_MEETING_E2E_AUDIO=<16 kHz wav>`;
  it downloads the models if missing; make a test recording with `say -v Anna ...` and `afconvert`).
- Dependencies: Swift Package Manager. Sparkle (update feed removed, updater never starts) and FluidAudio 0.17.7,
  which only `Packages/MeetingKit` imports, with `traits: []` so its prebuilt NeMo binary is not linked. The Xcode
  project references MeetingKit as a local package.
- New Swift files must be added to `v2s.xcodeproj/project.pbxproj` by hand (file reference, group, Sources phase):
  the project lists files explicitly, so `swift build` passing does not mean the Xcode build sees them.
- Signing: `Config/Signing.xcconfig` signs ad hoc unless `Config/Signing.local.xcconfig` (git-ignored, copy the
  `.example`) names an Apple Development team. Without it macOS re-asks for Keychain access and the System Audio
  Recording permission after every rebuild.

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
- **Privacy is a hard requirement (R9–R11, R19):**
  - Never write audio to disk, with two exceptions in Meeting mode: the encrypted spool for the pass after Stop
    (`MeetingAudioSpool`, key in memory, deleted once read) and the opt-in "Keep last meeting audio for diagnosis"
    (`MeetingDebugStore`, `~/Library/Application Support/Untertitel/MeetingDiagnosis`, deleted after 24 h).
    Never log transcript or translation text outside `#if DEBUG`.
  - API keys live in the Keychain only — never in `AppSettings`, UserDefaults, logs, or the repo.
  - The on-device path must keep working with no network; the cloud engines are optional and off by default.
  - Meeting transcripts are saved only when switched on, to `~/Meeting Transcripts` (never inside this checkout:
    `.gitignore` also ignores `/Meetings/` and `*.spool`). Before any push, check that no transcript, audio or key
    is in the commits.
- `AppSettings` has a custom decoder: **every new field needs a `decodeIfPresent` fallback** so old settings files load.
- `TranslationSession` is view-anchored (`.translationTask` via `v2sTranslationHost`); don't try to use Apple
  Translation outside the existing `TranslationCoordinator` path.
- The app is `LSUIElement` (no Dock icon by default). Global hotkeys must work while another app is frontmost.

## Ask Mehul before

- Adding any dependency, changing the bundle identifier, signing, entitlements, Sparkle/update feeds or `scripts/release.sh`.
- Deleting or weakening existing tests.
- Anything that sends audio or text off the machine other than the opt-in OpenAI and Soniox engines (subtitles,
  and Soniox live or file transcription for meetings).
- Playing any audio from the app. The OpenAI engine returns translated speech; it must be discarded, never played.

## Meeting mode facts (M7)

- Models (about 1.3 GB) live in `~/Library/Application Support/FluidAudio/Models`; complete when
  `untertitel-meeting-models.json` is there. Downloads happen only from Settings > Meeting > Download;
  `MeetingModels.blockDownloads()` keeps FluidAudio offline otherwise.
- Live: Apple SpeechAnalyzer for a chosen language, FluidAudio's Nemotron model for Auto-detect, LS-EEND (`ami`)
  for live speakers. After Stop: pyannote community-1 + VBx (clustering threshold 0.6, FluidAudio's default) and
  Parakeet Ultra, or Soniox's file API. The user's "People speaking" hint (Auto/2/3/4+) sets the after-Stop pass's
  speaker count; LS-EEND has no such setting.
- Diagnosis: `/usr/bin/log show --last 1d --info --predicate 'process == "Untertitel" AND (category == "meeting"
  OR category == "meetingModels")'` shows each meeting's setup, the live speaker count, and the pass after Stop
  (speakers found, threshold, hint, peak level). With the diagnosis setting on, the last meeting's audio and speaker
  turns are in `MeetingDiagnosis/last-meeting.wav` and `.json` (no transcript text).

## What you can't verify here

You can't join a real call, click permission dialogs, or hear audio. At the end of each milestone, list the manual
checks from `plan/TEST-CHECKLIST.md` that apply, so Mehul can run them on his Mac.
