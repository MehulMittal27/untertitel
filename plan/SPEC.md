# Untertitel — Product spec

Source of truth for *what* we build. Full research and background live in the spec doc on claude.ai
("Live Call Subtitles DE→EN — Product Spec", 12 Oct 2026). This file is the condensed, buildable version.

## One-line summary

A macOS menu-bar app that listens only to the *other* people on a call and shows English subtitles of their German
speech in a floating overlay, toggled with one global hotkey. It never touches the microphone, so Wispr Flow
(dictation) keeps working alongside it.

## User

An English-speaking professional living in Germany who follows most German but loses detail in fast, technical or
dialect-heavy calls. Uses Wispr Flow for dictating notes during calls. Apple-silicon Mac.

## Requirements

### Toggle and control
- **R1 — Global toggle hotkey.** Default `⌃⌥T`, rebindable. Works while any app is frontmost. Press: capture starts,
  overlay appears. Press again: capture stops, overlay hides, any network stream closes.
- **R2 — No collision with Wispr Flow.** Our hotkeys must not use Wispr's push-to-talk key (Fn by default).
  Rebinding UI must reject conflicts with system shortcuts.
- **R3 — Menu-bar state.** Icon shows three states: off, listening, and *listening but no audio arriving*
  (catches the silent Core Audio permission failure).
- **R4 — Toggle feedback.** A subtle confirmation when toggling (icon change always; optional short sound, off by default).

### Audio source
- **R5 — Call-app auto-detect.** When toggled on with no explicit choice, pick the running call app — preferring one
  currently producing audio — from a known list (Zoom, Teams, Webex, WhatsApp, Signal, FaceTime, Slack, Discord;
  browsers last, for Meet). Tap only that app's output.
- **R6 — Manual override.** The existing source picker still works and wins over auto-detect.

### Captions
- **R7 — Two-line overlay.** English on top (primary), German underneath (smaller, quieter). English-only mode
  available. (v2s already does this; keep it.)
- **R8 — Catch-up.** A shortcut (default `⌃⌥↑`) expands the overlay to show recent history so you can catch up after
  looking away. "Copy last 2 minutes" puts recent English + German text on the clipboard (to paste into Wispr notes).

### Privacy
- **R9 — Never record.** No audio written to disk, ever. Transcript history stays in memory unless the user exports it.
- **R10 — On-device by default.** Default engine is Apple SpeechAnalyzer + Apple Translation; works fully offline.
- **R11 — Secrets in Keychain.** The OpenAI API key is stored in the Keychain only.

### Engines
- **R12 — Engine choice.** Settings offer *On-device* (default) or *Cloud (OpenAI)*. Both feed the same overlay.
- **R13 — Cloud engine.** OpenAI `gpt-realtime-translate` over WebSocket, target language English, with source
  transcription on, so both the German and English lines stream live. **Text only:** the app never plays the
  translated audio. About $0.034 per minute of call (~$2/hour). No glossary support in this mode.
- **R14 — Graceful fallback.** If the cloud connection fails or drops, show a status message and fall back to
  on-device without the user having to restart.

### Quality targets (measure, don't assume)
- **R15 — Latency.** Cloud: first partial English ≤ 1 s after speech, final line ≤ 2 s after sentence end.
  On-device: final line ≤ 5 s after sentence end.
- **R16 — Latency logger.** Debug builds log per-sentence timings (audio time of speech end → first draft →
  final source → final translation) so R15 can be measured.

## Non-goals (for now)
- Translating *your* speech for the other side, or speaking translations aloud.
- Windows or Intel Macs.
- Accounts, billing, team features.
- Meeting bots or integrations with Zoom/Teams APIs.

## Done means (v1, personal use)
- Mehul uses it in real German calls with Wispr Flow running, toggling it on and off mid-call, and prefers having it on.
- Median final English line ≤ 2 s on cloud mode across five recorded German calls (R15).
- No audio files on disk, no keys outside Keychain (R9, R11).
