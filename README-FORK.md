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
- Cost guardrails for the cloud engine: it pauses after about 3 minutes without speech and switches off completely
  after 15 minutes paused, takes one source at a time, and the popover shows the minutes streamed today with an
  estimated cost.
- In cloud mode the overlay shows one caption at a time, like TV subtitles: centered, at most 70% of the screen wide,
  English large on top and German small below, on a dark rounded background. Long sentences are split into readable
  chunks. On-device mode keeps upstream's scrolling overlay.
- The menu-bar icon shows the state at a glance: outline when off, green while an on-device session runs, orange
  with a "$" while a cloud session is connected and billing, a green pause sign while a cloud session is paused.
- A global shortcut, `⌃⌥T` by default, switches subtitles on and off from any app and any desktop. It can be
  changed or cleared in Settings, which refuses Fn, bare keys and shortcuts macOS or most apps already use. A small
  "Subtitles on" / "Subtitles off" label confirms the toggle next to the caption area, and an optional sound (off
  by default) does the same.
- Fix: the popover now opens on whichever desktop is in front. Before, it opened only on the desktop the app was
  started on (branch `fix/popover-on-active-desktop`, based on upstream).
- `CLAUDE.md` and `plan/` hold the project context and roadmap.

## Building

`scripts/build-app.sh` builds the app into `~/untertitel-build` (override with `UNTERTITEL_BUILD_DIR`) and prints
the path to launch. Always build this way, so there is only ever one copy of the app on the Mac: the script warns
when it finds a second copy, or when the app that is running was started before the build.

To make Xcode's own Build and Run use the same place, set File > Project Settings > Derived Data > Advanced >
Custom > Absolute, with Products `~/untertitel-build/Build/Products` and Intermediates
`~/untertitel-build/Build/Intermediates.noindex`.

## Signing your own builds

Builds are signed ad hoc by default, which makes macOS ask again for Keychain access and the System Audio Recording
permission after every rebuild. To avoid that, sign in to Xcode with your Apple ID, copy
`Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig` and set your team ID.

Forked from upstream commit `11eb6b8` (3 Oct 2026).
