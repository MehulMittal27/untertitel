# Untertitel (fork of v2s)

This is a personal fork of [franklioxygen/v2s](https://github.com/franklioxygen/v2s), a macOS menu-bar app that
captures audio from another app, transcribes it on-device and shows translated subtitles in an overlay.
The upstream [README](README.md) still describes how the app works.

The fork is being turned into Untertitel: live German to English subtitles for video calls, switched on and off
with one global hotkey. The plan is in [`plan/`](plan/ROADMAP.md).

## What this fork changes so far

- A fresh install starts with German as the spoken language and English as the subtitle language
  (upstream: English to Simplified Chinese). Existing settings files keep the languages they already have.
- An optional cloud engine: OpenAI `gpt-realtime-translate`, text only. It streams the selected app's audio to
  OpenAI and shows the German and English transcripts; the translated speech it returns is discarded and never
  played. Off by default. The API key is entered in Settings and stored in the Keychain only. If the connection
  fails, the session carries on with the on-device engine.
- Cost guardrails for the cloud engine: it pauses after about 3 minutes without speech, takes one source at a time,
  and the popover shows the minutes streamed today with an estimated cost.
- `CLAUDE.md` and `plan/` hold the project context and roadmap.

## Signing your own builds

Builds are signed ad hoc by default, which makes macOS ask again for Keychain access and the System Audio Recording
permission after every rebuild. To avoid that, sign in to Xcode with your Apple ID, copy
`Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and set your team ID.

Forked from upstream commit `11eb6b8` (3 Oct 2026).
