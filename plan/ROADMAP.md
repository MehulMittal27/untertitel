# Roadmap — milestones for Claude Code

Each milestone: own branch, build passes, tests pass, then stop and report
(what changed, tests added, which `TEST-CHECKLIST.md` items Mehul should run).

**Order (changed 12 Oct 2026 after M0 testing): M0 ✓ → M5 → M1 → M2 → M3 → M4 → M6.**
On-device mode lags too much for live calls, so the cloud engine (M5) comes first.

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

## M5 — Cloud engine: OpenAI gpt-realtime-translate, text only [fork-only] (R12–R14, R16)

Goal: English subtitles that keep up with the speaker. On-device mode lags badly in Mehul's tests (12 Oct 2026):
even the German recognition is seconds behind. Read `plan/OPENAI-TRANSLATE.md` first.
**Text only:** the app shows the German and English transcripts and never plays the translated audio.

Tasks
1. **Engine setting.** `AppSettings.recognitionEngine: .onDevice | .openAITranslate` (default `.onDevice`). Engine
   picker in Settings and popover. OpenAI API key field in Settings, saved to the **Keychain** (new tiny
   `KeychainStore`). Show the price hint "≈ $2 per hour of calls" next to the picker.
2. **Client.** `Services/OpenAITranslateClient.swift` using `URLSessionWebSocketTask`:
   connect (Bearer key header) → `session.update` → stream `session.input_audio_buffer.append` →
   parse events → `session.close` on stop. Discard `session.output_audio.delta` without decoding.
3. **Audio in.** In `LiveTranscriptionSession`, add `RecognitionBackend.openAITranslate`. When selected, skip
   SpeechAnalyzer setup, and in `append(audioBuffer:)` resample to **24 kHz mono PCM16**, batch ~100 ms, base64,
   send. Stream continuously including silence. Keep VAD running (used for sentence commits, see 4).
4. **Results out.** Extend `RecognizedSentence` and `DraftSegment` with optional `translatedText`.
   A pure `TranslateDeltaAssembler` turns `session.input_transcript.delta` (German) and
   `session.output_transcript.delta` (English) into drafts and committed sentences, using VAD silence and punctuation
   for boundaries (strategy in `OPENAI-TRANSLATE.md`). If English is missing for a segment (speaker used English),
   commit with the source text as the English line.
5. **Skip Apple Translation when the engine translated.** In `AppModel.translatedText(for:)` and the draft path
   (`handlePartialDraft` / `scheduleDraftTranslation`), use the engine's `translatedText` when present. Carry it on
   `QueuedCaption`. Don't change behaviour for the on-device engine.
6. **Glossary:** not supported by this model (no custom prompts). Leave the glossary UI as-is and show a one-line
   note that it applies to on-device mode only.
7. **Fallback (R14).** On connect failure, auth error, or a dropped socket mid-session: status message, then restart
   the session on the on-device engine automatically. Never crash, never retry in a tight loop.
8. **Latency logger (R16, DEBUG only).** Per sentence: speech-end audio time, first German delta, first English
   delta, commit time. Use `Logger` with `.private` redaction; never log transcript text in release.
9. **Keep the engine interface clean** so another cloud engine (e.g. Soniox) can be added later as one new client
   plus one assembler.
10. **Cost guardrails (added 12 Oct 2026).** Close the cloud session after ~3 min without audio and show
    "Paused - no audio"; after 15 minutes paused, stop fully as if toggled off; cloud mode takes one source at a
    time; the popover shows minutes streamed today and the estimated cost (local only).
11. **Signing.** Sign with Mehul's Apple Development team so Keychain access and the System Audio Recording
    permission survive rebuilds (`Config/Signing.xcconfig`).

Tests
- `TranslateDeltaAssembler` with scripted event sequences: English trailing German, punctuation + silence commit,
  long monologue cut, English-speaker segment with no translation, `session.closed` flush.
- Float32 16 kHz → PCM16 24 kHz conversion (length, clipping) and base64 chunking.
- Event decoding: unknown event types are ignored; output audio events are dropped.
- Settings decoding with/without the new fields; Keychain store with a fake.

Acceptance
- With a key set and engine = OpenAI, a German YouTube clip played in Chrome shows German and English text that
  keeps up with the speaker (target: English within ~1–2 s of speech). No sound is played by the app.
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
- Soniox as a cheaper second cloud engine (~$0.12/hour vs ~$2/hour, has glossary support); API notes were in the
  first version of this plan.
- Speaker labels, Windows port, more language pairs.
- **OpenSuperWhisper as a reference** ([Starmel/OpenSuperWhisper](https://github.com/Starmel/OpenSuperWhisper), Swift, MIT):
  - its global-hotkey code (modifier-only keys, mouse buttons) if M1's hotkey needs more than a plain key combo;
  - Parakeet via FluidAudio as a second free on-device engine, if Apple's German recognition is weak in real calls.
    Not streaming today, so evaluate before M5 rather than building on it.
