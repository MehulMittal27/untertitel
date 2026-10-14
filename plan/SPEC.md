# Untertitel — Product spec

Source of truth for *what* we build. Full research and background live in the spec doc on claude.ai
("Live Call Subtitles DE→EN — Product Spec", 12 Oct 2026). This file is the condensed, buildable version. Since
14 Oct 2026 the app is multilingual: any spoken language to the subtitle language you choose (English by default);
German to English is no longer built in.

## One-line summary

A macOS menu-bar app that listens only to the *other* people on a call and shows subtitles of their speech in the
language you choose, in a floating overlay, toggled with one global hotkey. It never touches the microphone, so
Wispr Flow (dictation) keeps working alongside it.

## User

An English-speaking professional living in Germany who follows most German but loses detail in fast, technical or
dialect-heavy calls, and who also joins calls in other languages. Uses Wispr Flow for dictating notes during calls.
Apple-silicon Mac.

## Requirements

### Toggle and control
- **R1 — Global toggle hotkey.** Default `⌃⌥T`, rebindable. Works while any app is frontmost. Press: capture starts,
  overlay appears. Press again: capture stops, overlay hides, any network stream closes.
- **R2 — No collision with Wispr Flow.** Our hotkeys must not use Wispr's push-to-talk key (Fn by default).
  Rebinding UI must reject conflicts with system shortcuts.
- **R3 — Menu-bar state.** Icon shows three states: off, listening, and *listening but no audio arriving*
  (catches the silent Core Audio permission failure).
- **R4 — Toggle feedback.** A subtle confirmation when toggling (icon change always; optional short sound, off by
  default; a short label such as "Subtitles on – Safari – → English").

### Audio source
- **R5 — Call-app auto-detect.** When toggled on with no explicit choice, pick the running call app — preferring one
  currently producing audio — from a known list (Zoom, Teams, Webex, WhatsApp, Signal, FaceTime, Slack, Discord;
  browsers last, for Meet). Tap only that app's output.
- **R6 — Manual override.** The existing source picker still works and wins over auto-detect.

### Captions
- **R7 — Two-line overlay.** The subtitle language on top (primary), the original underneath (smaller, quieter).
  Subtitle-only mode available. (v2s already does this; keep it.)
- **R7a - Languages.** "Spoken language" (default *Auto-detect*) and "Subtitle language" (default English) in
  Settings and in the popover, switchable while subtitles run (the session restarts on the same source with the new
  pair and keeps its transcript).
  - OpenAI needs no spoken language (it detects 70+); its subtitle languages are its 13 targets: English, Spanish,
    Portuguese, French, Japanese, Russian, Chinese, German, Korean, Hindi, Indonesian, Vietnamese, Italian
    (OpenAI's realtime translation guide, checked 14 Oct 2026).
  - Soniox runs with language identification on; a chosen spoken language is sent as a hint, Auto-detect sends none.
    Any of its 60 languages can be the subtitle language.
  - On-device cannot detect the language: it needs an explicit spoken language, and the UI says so. A cloud session
    that falls back to the device mid-call uses the language detected in what was said so far.
  - A cloud engine never starts in a subtitle language it cannot make; the UI names the problem.
- **R7b - Speech already in the subtitle language** is shown as it was spoken, not translated or dropped.
- **R8 — Catch-up.** A shortcut (default `⌃⌥↑`) expands the overlay to show recent history so you can catch up after
  looking away. "Copy last 2 minutes" puts recent subtitle + original text on the clipboard (to paste into Wispr
  notes).

### Privacy
- **R9 — Never record.** No audio written to disk, ever. Transcript history stays in memory unless the user exports it.
- **R10 — On-device by default.** Default engine is Apple SpeechAnalyzer + Apple Translation; works fully offline.
- **R11 — Secrets in Keychain.** The OpenAI and Soniox API keys are stored in the Keychain only.

### Engines
- **R12 — Engine choice.** Settings offer *On-device* (default), *Cloud (OpenAI)* or *Cloud (Soniox)*. All feed the
  same overlay.
- **R13 — Cloud engines.** OpenAI `gpt-realtime-translate` over WebSocket into the chosen subtitle language, with
  source transcription only while the original line is shown (a second billed model). **Text only:** the app never
  plays the translated audio. About $0.034 per minute of call (~$2/hour), $0.051 with the original line. No
  glossary support in this mode. Soniox (`stt-rt-v5`, one-way translation, about $0.12/hour) is the second cloud
  engine and takes the glossary.
- **R14 — Graceful fallback.** If the cloud connection fails or drops, show a status message and fall back to
  on-device without the user having to restart.

### Quality targets (measure, don't assume)
- **R15 — Latency.** Cloud: first partial subtitle ≤ 1 s after speech, final line ≤ 2 s after sentence end.
  On-device: final line ≤ 5 s after sentence end.
- **R16 — Latency logger.** Debug builds log per-sentence timings (audio time of speech end → first draft →
  final source → final translation) so R15 can be measured.

### Meeting transcription (M7, see plan/MEETING.md)
- **R17 - Meeting mode.** In-person meetings through the microphone, no translation, separate from call
  subtitles (only one runs at a time), own shortcut `⌃⌥M`. Live transcript in its own window, speakers labelled
  "Speaker 1/2/..." and renamable.
- **R18 - Consent and indicator.** A consent note to read out or paste appears before every start, with Start in
  it. While a meeting runs, the menu-bar icon is red and the window says "Transcribing meeting".
- **R19 - Exceptions to R9 and "never touches the microphone".** Meeting mode uses the microphone. Its audio is
  kept on this Mac only for the pass after Stop, encrypted with a key held in memory, and deleted right after;
  transcripts are written to `~/Meeting Transcripts` only when the user switches saving on.
- **R20 - Optional cloud for meetings.** Off by default: Soniox live with speaker labels (about $0.12/h), and/or
  Soniox's recorded-file pass after Stop (about $0.10/h), files deleted at Soniox afterwards. The consent note
  says what is sent.

## Non-goals (for now)
- Translating *your* speech for the other side, or speaking translations aloud.
- Windows or Intel Macs.
- Accounts, billing, team features.
- Meeting bots or integrations with Zoom/Teams APIs.

## Done means (v1, personal use)
- Mehul uses it in real German calls with Wispr Flow running, toggling it on and off mid-call, and prefers having it on.
- Median final subtitle line ≤ 2 s on cloud mode across five recorded calls (R15), most of them German.
- No audio files on disk, no keys outside Keychain (R9, R11).
