# Untertitel (fork of v2s)

This is a personal fork of [franklioxygen/v2s](https://github.com/franklioxygen/v2s), a macOS menu-bar app that
captures audio from another app, transcribes it on-device and shows translated subtitles in an overlay.
The upstream [README](README.md) still describes how the app works.

The fork is being turned into Untertitel: live German to English subtitles for video calls, switched on and off
with one global hotkey. The plan is in [`plan/`](plan/ROADMAP.md).

## What this fork changes so far

- A fresh install starts with German as the spoken language and English as the subtitle language
  (upstream: English to Simplified Chinese). Existing settings files keep the languages they already have.
- `CLAUDE.md` and `plan/` hold the project context and roadmap.

Forked from upstream commit `11eb6b8` (3 Oct 2026).
