# Manual test checklist (Mehul runs these on his Mac)

Claude Code can't hear audio or click permission dialogs, so these are run by hand after each milestone.
Easy German test audio: a German news clip or podcast on YouTube (e.g. Tagesschau) playing in Chrome or
in a Zoom/Teams test call shared from a second device.

## Every milestone
- [ ] App launches, menu-bar icon appears, no crash on Start/Stop ×5.
- [ ] Overlay shows German → English for a German clip.
- [ ] Wispr Flow dictation still works while subtitles are on (dictate a sentence into Notes).

## M1 — Hotkey
- [ ] `⌃⌥T` toggles subtitles with Zoom/Teams/Chrome frontmost.
- [ ] Toggle mid-sentence: overlay hides immediately; turning back on resumes within a few seconds.
- [ ] Rebind to another combo, quit, relaunch: new binding works, old one doesn't.
- [ ] Clear the binding: no hotkey active.
- [ ] Wispr Flow push-to-talk and the hotkey don't interfere.

## M2 — Auto-detect
- [ ] Zoom (or Teams) in a call + Chrome playing music → picks the call app.
- [ ] Only a Google Meet tab in Chrome → picks Chrome.
- [ ] Manually chosen source still wins.
- [ ] Note any bundle IDs that were wrong and fix the list.

## M3 — No-audio state
- [ ] Revoke "Screen & System Audio Recording" for the app → warning icon + hint within ~5 s.
- [ ] Re-grant → icon returns to normal once audio flows.
- [ ] Muted call / nobody speaking for 30 s → no false warning while the app isn't playing audio.

## M4 — Catch-up and copy
- [ ] `⌃⌥↑` expands and collapses history during a call.
- [ ] `⌃⌥C` then paste into notes: last ~2 minutes, English + German lines, no duplicates.

## M5 — Soniox
- [ ] Engine = Soniox with a valid key: first English words within ~1 s of speech.
- [ ] Glossary term (e.g. a colleague's surname) comes out spelled right.
- [ ] Invalid key → clear error, falls back to on-device.
- [ ] Wi-Fi off mid-session → message, falls back to on-device, no crash or retry storm.
- [ ] Latency log (DEBUG): median final English ≤ 2 s across a 10-minute clip; paste the numbers into the PR.
- [ ] Key not found in `~/Library/Application Support/<app>/` settings or in `log show` output.

## Overlay over calls
- [ ] Visible over full-screen Zoom and full-screen Teams.
- [ ] Behaviour while *you* share your screen (is the overlay captured in the share? note it).
- [ ] Multiple displays: overlay stays where you put it.
