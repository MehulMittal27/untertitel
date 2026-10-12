# Roadmap — milestones for Claude Code

Work in order. Each milestone: own branch, build passes, tests pass, then stop and report
(what changed, tests added, which `TEST-CHECKLIST.md` items Mehul should run).

Legend: **[upstream]** = should be acceptable as a PR to `franklioxygen/v2s` · **[fork-only]** = stays in our fork.

---

## M0 — Baseline and fork defaults [fork-only]

Goal: a working local build with German → English as the default pair.

Tasks
1. Build the app and run the test suite. Record the working build and test commands in `CLAUDE.md` (Environment).
   If tests fail on a clean checkout, report which ones and don't fix them yet.
2. Change `AppSettings.default` to `inputLanguageID: "de"`, `outputLanguageID: "en"`.
3. Add a `README-FORK.md` (short) saying what this fork changes and linking upstream.

Acceptance
- Clean build; test results reported.
- A fresh settings file starts as German → English; an existing settings file keeps the user's languages.

---

## M1 — Global toggle hotkey [upstream] (R1, R2, R4)

Goal: start/stop subtitles from anywhere with one key combo.

Tasks
1. Add a `HotkeyService` that registers a system-wide hotkey and calls `AppModel.toggleSession()` on the main actor.
   - Preferred: Carbon `RegisterEventHotKey` (no new dependency, works for `LSUIElement` apps, needs no
     Accessibility permission). Alternative: `sindresorhus/KeyboardShortcuts` (gives a recorder UI) — **ask first**.
2. Default binding `⌃⌥T`. Store the binding in `AppSettings` (new field with `decodeIfPresent` fallback).
3. Settings: a shortcut recorder row, a "Clear" option, and a warning if the combo is a common system shortcut.
   Never allow a bare `Fn` binding (Wispr Flow's default push-to-talk key).
4. If toggled on with no source selected: for this milestone, open the popover with the existing
   "choose an input source" message. (M2 replaces this with auto-detect.)
5. Show the shortcut in the popover next to Start/Stop.
6. Optional toggle sound, **off by default** (setting).
7. Localize all new strings in `AppLocalization`.

Tests
- Unit-test binding persistence and decoding of old settings files without the new field.
- Unit-test that the toggle action maps to start when idle and stop when running (inject a fake model if needed).

Acceptance
- Hotkey toggles subtitles while Zoom/Teams/Chrome is frontmost.
- Rebinding persists across relaunch; clearing it disables the hotkey.

---

## M2 — Call-app auto-detect [upstream] (R5, R6)

Goal: pressing the hotkey "just works" during a call without picking a source.

Tasks
1. Add `CallAppDetector` with a ranked list of bundle IDs (verify each on Mehul's Mac with
   `osascript -e 'id of app "Zoom"'`, etc., and correct the list):
   - Tier 1 (dedicated call apps): `us.zoom.xos`, `com.microsoft.teams2`, `com.microsoft.teams`, `Cisco-Systems.Spark`
     (Webex), `net.whatsapp.WhatsApp`, `org.whispersystems.signal-desktop`, `com.apple.FaceTime`,
     `com.tinyspeck.slackmacgap`, `com.hnc.Discord`
   - Tier 2 (browsers, for Meet / Teams web): `com.google.Chrome`, `com.apple.Safari`, `company.thebrowser.Browser`,
     `com.microsoft.edgemac`, `org.mozilla.firefox`, `com.brave.Browser`
2. Ranking: running **and** currently producing audio (`AudioHardwareProcess(...).isRunningOutput`, already used in
   `ApplicationAudioCapture`) beats merely running; tier 1 beats tier 2; ties → most recently active app.
3. In `startSession()`: only when the user has **no** source selected, use the detector's pick and show
   "Listening to <App>" in the overlay placeholder / status. An explicit selection always wins (R6).
4. If nothing is found, fall back to M1 behaviour (prompt to choose).

Tests
- Pure ranking tests with fake app lists and fake "is playing" flags.

Acceptance
- With Zoom in a call and Chrome playing music, the hotkey picks Zoom.
- With only a Meet tab in Chrome, it picks Chrome.

---

## M3 — "No audio" state in the menu bar [upstream] (R3)

Goal: make silent capture failures visible.

Tasks
1. Add a callback from `LiveTranscriptionSession` to `AppModel` that fires when
   `.silentWhileAppIsPlaying` is detected (and when `.receivingAudio` resumes). Also fire it if no audio
   arrives at all within ~5 s of start.
2. Publish a flag on `AppModel` (e.g. `isCaptureSilent`), and in `StatusBarController.updateStatusIcon` show a
   distinct icon/tint for running-but-silent.
3. Popover/overlay hint: "No audio from <App>. Check System Settings › Privacy & Security › Screen & System Audio
   Recording." (Localize; check the exact System Settings wording on macOS 26.)

Tests
- Unit-test the state transitions (silent → audible → silent) with a fake event source.

Acceptance
- Denying system-audio permission shows the warning state within ~5 s instead of a silent overlay.

---

## M4 — Catch-up and copy for Wispr notes [fork-only] (R8)

Goal: make the subtitles useful alongside dictated notes.

Tasks
1. Add a timestamp to `TranscriptEntry` (in memory only).
2. Global shortcut `⌃⌥↑` (same `HotkeyService`): toggles the overlay between normal and an expanded history view,
   driving the existing `overlayHistoryVisibleCount` / `scrollOverlayHistory`.
3. Global shortcut `⌃⌥C` and a popover button: copy the last 2 minutes as plain text, English line then German line
   per sentence, to the clipboard.
4. Make both bindings configurable like M1.

Acceptance
- During a call, `⌃⌥C`, then pasting into a note (with Wispr Flow active), gives clean bilingual lines.

---

## M5 — Cloud engine: Soniox real-time with translation [fork-only] (R12–R14, R16)

Goal: sub-2-second English subtitles, better on dialects. Read `plan/SONIOX.md` first.

Tasks
1. **Engine setting.** `AppSettings.recognitionEngine: .onDevice | .soniox` (default `.onDevice`). Engine picker in
   Settings and popover. API key field in Settings, saved to the **Keychain** (new tiny `KeychainStore`).
2. **Client.** `Services/SonioxStreamingClient.swift` using `URLSessionWebSocketTask`:
   connect → send config JSON → stream binary audio → parse token responses → keepalive → clean shutdown.
   Pure, testable token-assembly logic in its own type (`SonioxTokenAssembler`).
3. **Audio in.** In `LiveTranscriptionSession`, add `RecognitionBackend.soniox`. When selected, skip
   SpeechAnalyzer setup, and in `append(audioBuffer:)` convert the 16 kHz mono Float32 `processingBuffer` to
   `pcm_s16le` and send it (batch to ~100–120 ms frames). Keep VAD running (it's only used for timing).
4. **Results out.** Extend `RecognizedSentence` and `DraftSegment` with optional `translatedText`.
   The assembler emits:
   - drafts: current German (final + non-final original tokens) and current English (translation tokens);
   - sentences: on an endpoint token (`<end>`), the finished German sentence plus its English. If the English for that
     sentence isn't final yet, wait up to ~1.5 s for it, then emit with what exists.
5. **Skip Apple Translation when the engine translated.** In `AppModel.translatedText(for:)` and the draft path
   (`handlePartialDraft` / `scheduleDraftTranslation`), use the engine's `translatedText` when present. Carry it on
   `QueuedCaption`. Don't change behaviour for the on-device engine.
6. **Glossary → context.** `glossary` keys → `context.terms`; key/value pairs → `context.translation_terms`.
7. **Fallback (R14).** On connect failure, auth error, or a dropped socket mid-session: status message, then restart
   the session on the on-device engine automatically. Never crash, never retry in a tight loop.
8. **Latency logger (R16, DEBUG only).** Per sentence: speech-end audio time, first draft time, final German time,
   final English time. Write to `Logger` with `.private` text redaction; never log transcript text in release.

Tests
- `SonioxTokenAssembler` against recorded JSON fixtures in `Tests/V2STests/Fixtures/` (write a few by hand from
  the documented format: non-final replacement, final append, translation tokens arriving later, `<end>`, `finished`).
- Float32 → Int16 conversion (clipping, length).
- Settings decoding with/without the new fields; Keychain store with a fake.

Acceptance
- With a key set and engine = Soniox, a German YouTube clip played in Chrome shows English drafts within ~1 s.
- Pulling the network mid-session falls back to on-device with a visible message.
- No API key appears in settings files, logs or the repo (`grep` the repo and `~/Library/Application Support`).

---

## M6 — Make it a daily driver [fork-only]

Tasks
1. Rename the app display name to "Untertitel" (bundle ID change: **ask first**), new menu-bar glyph optional.
2. Launch-at-login toggle (`SMAppService`).
3. Ad-hoc signed Release build script for Mehul's own Mac (no notarization yet).
4. A short "disclosure" snippet in the popover to copy into meeting chat:
   "I'm using live English captions — nothing is recorded."

---

## Later (not now)
- Upstream PR for the engine seam if the v2s maintainer is interested.
- Speaker labels (Soniox diarization), Windows port, more language pairs.
- **OpenSuperWhisper as a reference** ([Starmel/OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper), Swift, MIT):
  - its global-hotkey code (modifier-only keys, mouse buttons) if M1's hotkey needs more than a plain key combo;
  - Parakeet via FluidAudio as a second free on-device engine, if Apple's German recognition is weak in real calls.
    Not streaming today, so evaluate before M5 rather than building on it.
