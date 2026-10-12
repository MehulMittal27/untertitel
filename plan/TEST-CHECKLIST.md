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

## M5 — OpenAI cloud engine (text only)
- [ ] Engine = OpenAI with a valid key: German and English text keep up with the speaker (English within ~1–2 s).
- [ ] The app plays **no sound**: only the original video/call audio is heard.
- [ ] Mixed language: when someone switches to English, the subtitle still shows their words.
- [ ] Compare with on-device mode on the same clip: is the lag clearly gone?
- [ ] After a 1-hour test, check usage in the OpenAI dashboard (expect ≈ $2).
- [ ] Popover shows "Today: N min ≈ $X" and it roughly matches the dashboard.
- [ ] Leave subtitles on with the call silent for 3+ minutes → overlay and status show "Paused - no audio";
      when someone speaks again the subtitles come back within a second or two, first words included.
- [ ] In cloud mode, picking a second source replaces the first (only one source selected).
- [ ] After a rebuild (signed with the Apple Development team), macOS does not ask again for Keychain access or
      the System Audio Recording permission.
- [ ] A call longer than the session limit: subtitles carry on across the reconnect (note how long the limit is).
- [ ] Invalid key → clear error, falls back to on-device.
- [ ] Wi-Fi off mid-session → message, falls back to on-device, no crash or retry storm.
- [ ] Latency log (DEBUG): median final English ≤ 2 s across a 10-minute clip; paste the numbers into the PR.
- [ ] Key not found in `~/Library/Application Support/<app>/` settings or in `log show` output.

## Overlay over calls
- [ ] Visible over full-screen Zoom and full-screen Teams.
- [ ] Behaviour while *you* share your screen (is the overlay captured in the share? note it).
- [ ] Multiple displays: overlay stays where you put it.
