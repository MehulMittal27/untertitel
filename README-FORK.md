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
- Cost guardrails for the cloud engine. It connects only once the source makes a sound, closes the connection after
  about 20 seconds of silence, pauses after about 3 minutes without speech (and then waits for you, unless you
  switch automatic resume on) and switches off completely after 15 minutes paused. Stop closes the connection at
  once, and the menu-bar icon shows billing whenever a connection is open. It takes one source at a time.
- The German line is a second OpenAI model with its own bill: about $2.04 per hour for English only, $3.06 with
  the German line. It is requested only when the Display setting shows it. The popover shows the rate for the
  current setting and an estimate of today's cost for both.
- A second cloud engine: Soniox real-time transcription with translation, about $0.12 per hour, text only, and it
  takes the glossary. It follows the same connection rules as OpenAI. Its key is entered in Settings and kept in
  the Keychain. It has not yet been run against the real service.
- A local log, `cloud-connections.log` beside the settings file, records every session and connection with its
  trigger and the seconds of audio sent.
- In cloud mode the overlay shows one caption at a time, like TV subtitles: centered, at most 70% of the screen wide,
  English large on top and German small below, on a dark rounded background. Long sentences are split into readable
  chunks. On-device mode keeps upstream's scrolling overlay.
- The menu-bar icon shows the state at a glance: outline when off, green while an on-device session runs, orange
  with a "$" while a cloud session is connected and billing, a green pause sign while a cloud session is paused.
- A global shortcut, `⌃⌥T` by default, switches subtitles on and off from any app and any desktop. It can be
  changed or cleared in Settings, which refuses Fn, bare keys and shortcuts macOS or most apps already use. A small
  "Subtitles on" / "Subtitles off" label confirms the toggle next to the caption area, and an optional sound (off
  by default) does the same.
- Automatic source selection: at each start the app picks, among the apps you have approved, the one that is in a
  call (using microphone and speaker), then one that is playing, with Safari preferred. An app is approved when you
  choose it or run a session on it. A call app you have not approved is offered in the popover and never started.
- The app never chooses what to listen to by itself. Upstream selects the first app in its list when nothing is
  selected; here a session only starts on a source you selected, or on the one your last session used if it is
  running. Otherwise the popover opens and asks. A selection saved by an earlier version is dropped once.
- Catch-up and copy: `⌃⌥↑` shows the last few captions above the current one, and `⌃⌥C` (or the clipboard button
  in the popover) copies the last two minutes, English line then German line per sentence. Both can be rebound.
- A session that hears nothing although its source is playing (usually a missing System Audio Recording
  permission) shows a yellow warning triangle in the menu bar and says which permission to check.
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
