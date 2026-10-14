# Manual test checklist (Mehul runs these on his Mac)

Claude Code can't hear audio or click permission dialogs, so these are run by hand after each milestone.
Easy German test audio: a German news clip or podcast on YouTube (e.g. Tagesschau) playing in Chrome or
in a Zoom/Teams test call shared from a second device.

## Every milestone
- [ ] App launches, menu-bar icon appears, no crash on Start/Stop ×5.
- [ ] Overlay shows German → English for a German clip.
- [ ] Wispr Flow dictation still works while subtitles are on (dictate a sentence into Notes).

## Cloud cost guardrails (added 12 Oct 2026)
- [ ] Press the hotkey with the source silent: the overlay says "No audio - not billing", the icon is a green
      muted speaker, never orange. Start playing German speech: within about a second the icon turns orange with
      "$" and the first words appear, not clipped.
- [ ] Pause the video for 20+ seconds: the icon goes back to the green muted speaker and "No audio - not billing".
      Play again: it reconnects by itself.
- [ ] Leave music or silence (no speech) for 3+ minutes: "Paused - no audio", green pause icon, with the hint to
      press the shortcut or Start. Play speech: nothing reconnects. Press the hotkey once: "Subtitles on", and
      subtitles return when there is sound.
- [ ] Settings > Engine > "Resume automatically after a pause" ON, start a new session, repeat the 3-minute pause:
      speech now brings the subtitles back by itself.
- [ ] Stop with the button, the hotkey and the overlay's X, each while the icon is orange: the icon leaves orange
      at once and never shows the outline first.
- [ ] Display = "Only show translated subtitle": captions show English only, the popover says ≈ $2.04 per hour;
      afterwards OpenAI's usage page shows `gpt-realtime-translate` minutes only, no `gpt-realtime-whisper`.
- [ ] Display = "Show both subtitles": popover says ≈ $3.06 per hour, and "Today" roughly matches the usage page
      for both models added together.
- [ ] Settings > Engine shows "English only ≈ $2.04/h, with original line ≈ $3.06/h" (Spoken language on
      Auto-detect), or names the language ("with German line") when one is chosen.
- [ ] After a session, `~/Library/Application Support/Untertitel/cloud-connections.log` lists the start, every connection
      opened and closed with its reason and seconds of audio, and the stop with what triggered it.
- [ ] Compare one day's log with OpenAI's 1-minute usage view: every billed minute has a connection in the log.

## Source choice (added 12 Oct 2026)
- [ ] First launch after this change: no source is selected (the popover says "Choose an input source before
      starting", Start is greyed out). Pressing the hotkey opens the popover and starts nothing.
- [ ] Choose a source and run a session. Quit that app, press the hotkey: the popover opens and asks; nothing else
      (Activity Monitor, Finder) is picked, and the icon never turns orange.
- [ ] Open that app again and press the hotkey: subtitles start on it without asking.
- [ ] Quit and relaunch Untertitel: the chosen source is still selected.

## Menu-bar icon (added 12 Oct 2026)
- [ ] Clicking the icon opens the popover from every desktop and with any app in front (Chrome, Safari, a terminal),
      including over a full-screen app. One click opens it, the next click closes it.
- [ ] With the popover open, switch desktops: it closes, and one click on the new desktop opens it again.
- [ ] Icon states at a glance: outline = off; green filled = on-device session; orange filled with "$" = a cloud
      connection is open (billing); green muted speaker = cloud session on, no audio, not billing; green pause =
      cloud session paused (not billing); "!" = error.
- [ ] Hovering the icon shows the current status line as a tooltip.

## M1 — Hotkey
- [ ] `⌃⌥T` toggles subtitles with Zoom/Teams/Chrome frontmost.
- [ ] `⌃⌥T` works from every desktop, including over a full-screen app.
- [ ] Toggle mid-sentence: overlay hides immediately; turning back on resumes within a few seconds.
- [ ] Rebind to another combo, quit, relaunch: new binding works, old one doesn't.
- [ ] Clear the binding: no hotkey active.
- [ ] Wispr Flow push-to-talk and the hotkey don't interfere.
- [ ] Each toggle with the hotkey shows "Subtitles on" / "Subtitles off" just under the caption area for about a
      second; switching the label off in Settings stops it. Toggling with the popover button shows no label.
- [ ] With the sound switched on in Settings: a short high sound for on, a lower one for off, and neither shows up
      in the subtitles. Off by default.
- [ ] The popover's Start/Stop button shows the shortcut; after clearing it, the button shows none.
- [ ] Pressing the hotkey twice quickly while a cloud session is still connecting starts one session, not two.
- [ ] Settings refuses a key without Control/Option/Command, anything with Fn, and `⌘Space` or `⌘C`, each with a
      reason; Esc cancels recording.
- [ ] Cloud mode: the icon turns orange with "$" within a moment of pressing the hotkey, and back to the outline
      on the second press.

## M2 — Auto-detect
- [ ] Fresh state ("Pick the call app automatically" on, nothing approved), Meet or Teams call open in Safari,
      press the hotkey: nothing starts; the popover opens and offers "Safari is in a call" with a "Use Safari"
      button. Click it, then Start: subtitles run on Safari, and Safari is listed under Settings > Approved apps.
- [ ] Next call in Safari: the hotkey starts on Safari at once, and the label says "Subtitles on - Safari".
- [ ] Approve a second app (choose it once, then switch automatic back on). Call in one, music in the other:
      the hotkey picks the one in the call.
- [ ] A call app you never approved is in a call while Safari is idle: the hotkey starts nothing and offers it.
- [ ] Choose an app in the picker by hand: "Pick the call app automatically" switches off and that app stays.
- [ ] Remove an app under Settings > Approved apps: it is no longer picked, only offered.
- [ ] Does a muted Meet tab still count as "in a call"? Note the result.
- [ ] Note any bundle IDs that were wrong and fix the list (only Safari, Chrome and FaceTime were checked).

## Languages (added 14 Oct 2026)
- [ ] Popover and Settings show "Spoken Language" (Auto-detect) and "Subtitle Language" (English).
- [ ] OpenAI, Auto-detect: a German clip, then a French or Spanish clip, both subtitle in English without touching
      anything. The note under the picker says OpenAI detects the language.
- [ ] OpenAI: the subtitle list has exactly 13 languages. Switch to German while a French clip runs: within a few
      seconds the subtitles continue in German, the earlier lines stay in catch-up, and the icon never shows "off"
      while connected.
- [ ] With Display on "Show both subtitles", an English speaker with subtitles in English shows their words as
      spoken (once, not twice). (On "Only show translated subtitle" OpenAI may show nothing for such speech.)
- [ ] Soniox (once a key is set): Auto-detect works; choose a spoken language and the note says it is a hint; the
      subtitle list offers 60 languages (try Swahili or Dutch).
- [ ] On-device with Auto-detect: an orange note says it needs a spoken language; ⌃⌥T does not start and opens the
      popover with that message. Choose German: it starts.
- [ ] Choose Dutch subtitles, then switch the engine to OpenAI: an orange note says OpenAI cannot make Dutch
      subtitles, and Start shows the same message instead of connecting.
- [ ] The confirmation label reads "Subtitles on – Safari – → English".

## M3 — No-audio state
- [ ] Switch off the app's permission under System Settings > Privacy & Security > Screen & System Audio
      Recording, start a session on a playing source: within about 10 seconds the menu-bar icon becomes a yellow
      warning triangle, and the status line, overlay and popover name the app and the permission to check.
- [ ] Switch the permission back on (macOS may ask to quit and reopen): subtitles work and the icon is normal.
- [ ] In cloud mode the icon is never orange while the warning shows.
- [ ] Muted call / nobody speaking for 30 s → no false warning while the app isn't playing audio.

## M4 — Catch-up and copy
- [ ] During a session, `⌃⌥↑` shows the last few captions above the current one; `⌃⌥↑` again hides them.
- [ ] `⌃⌥C` shows "Copied the last 2 minutes"; pasting into a note (Wispr Flow active) gives the English line then
      the German line per sentence, with no duplicates and nothing older than about two minutes.
- [ ] With Display on "Only show translated subtitle", the copy has English lines only.
- [ ] `⌃⌥C` with nothing said in the last two minutes says "Nothing to copy yet" and leaves the clipboard alone.
- [ ] The popover's clipboard button does the same as `⌃⌥C`.
- [ ] Both shortcuts can be rebound and cleared in Settings, and Settings refuses a combination another of the
      app's shortcuts already uses.

## Cloud-mode overlay (added 12 Oct 2026)
- [ ] One caption block only, centered, never wider than about 70% of the screen; nothing runs off the screen.
- [ ] English at most 2 lines (large), German at most 2 lines (small, below); no stacked history lines.
- [ ] Dark rounded background stays readable over a bright video.
- [ ] A long sentence is shown in chunks of roughly 12 to 16 words; no caption starts with a comma or full stop.
- [ ] A new caption replaces the old one in place, without overlapping fades.
- [ ] When speech stops, the last caption stays long enough to read, then the block disappears.
- [ ] On-device mode still shows the original scrolling overlay.

## M5 — OpenAI cloud engine (text only)
- [ ] Engine = OpenAI with a valid key: German and English text keep up with the speaker (English within ~1–2 s).
- [ ] The app plays **no sound**: only the original video/call audio is heard.
- [ ] Mixed language: when someone switches to English, the subtitle still shows their words.
- [ ] Compare with on-device mode on the same clip: is the lag clearly gone?
- [ ] After a 1-hour test, check usage in the OpenAI dashboard (expect ≈ $2 English only, ≈ $3 with the German
      line).
- [ ] Popover shows "Today: N min ≈ $X" and it roughly matches the dashboard.
- [ ] Leave subtitles on with no speech for 3+ minutes → overlay and status show "Paused - no audio". With
      automatic resume switched on, the subtitles come back when someone speaks, first words included.
- [ ] Leave it paused for 15+ minutes → subtitles switch off completely (icon back to off, overlay gone), and
      audio afterwards does not bring them back.
- [ ] In cloud mode, picking a second source replaces the first (only one source selected).
- [ ] After a rebuild (signed with the Apple Development team), macOS does not ask again for Keychain access or
      the System Audio Recording permission.
- [ ] A call longer than the session limit: subtitles carry on across the reconnect (note how long the limit is).
- [ ] Invalid key → clear error, falls back to on-device.
- [ ] Wi-Fi off mid-session → message, falls back to on-device, no crash or retry storm.
- [ ] Latency log (DEBUG): median final English ≤ 2 s across a 10-minute clip; paste the numbers into the PR.
- [ ] Key not found in `~/Library/Application Support/<app>/` settings or in `log show` output.

## M5b - Soniox cloud engine (first run with a real key)
- [ ] Settings > Engine: save a Soniox API key (the row says "Saved in Keychain"), choose "Cloud (Soniox)".
- [ ] German speech: German and English captions keep up with the speaker; words may change for a moment before
      they settle. Note whether it is as fast as OpenAI.
- [ ] The cost guardrails behave exactly as with OpenAI: nothing connects before there is sound, 20 seconds of
      silence close the connection, 3 minutes without speech pause, Stop leaves orange at once.
- [ ] A glossary term is recognized and translated as written in the glossary.
- [ ] The popover says ≈ $0.12 per hour, and after a session Soniox's usage page roughly matches "Today".
- [ ] A wrong key: clear message naming Soniox, and the session carries on with the on-device engine.
- [ ] `cloud-connections.log` says "Soniox engine" for these sessions.

## M6 - Daily driver
- [ ] After the rename, the first launch of `Untertitel.app`: the engine, Display, approved apps and today's cost
      are as before, `~/Library/Application Support/Untertitel` holds the files and the old `v2s` folder is gone.
      Activity Monitor lists "Untertitel". No permission prompt appears again, and the OpenAI key is still saved.
- [ ] "Open Untertitel at Login" is in the state you left it; log out and in: `Untertitel.app` opens, not a missing
      `v2s.app`.
- [ ] The popover header, the tooltip, the Settings window title and the System Settings permission lists say
      "Untertitel". Permissions and the saved API key still work (the bundle ID did not change).
- [ ] Settings > "Open Untertitel at Login" on, log out and in: the icon appears in the menu bar and **no Settings
      window opens**. Opening the app yourself still shows Settings.
- [ ] `scripts/build-app.sh --release`, quit, launch the Release app from the path it prints: everything works, and
      the Debug copy is gone. Switch "Open at Login" off and on again afterwards (the app's path changed).
- [ ] The speech-bubble button in the popover footer opens a menu: English, Deutsch, and the spoken language when
      known. Each copies the note in that language, naming OpenAI or Soniox in cloud mode and saying "on my Mac" in
      on-device mode.
- [ ] Settings > General has no update controls: no "Check for updates automatically", no "Check for Updates".
      "Open Untertitel at Login" sits in the first card. The app never offers an update.

## M7 - Meeting transcription
- [ ] Popover: "Subtitles | Meeting" switch. Meeting shows Start Meeting with ⌃⌥M, Microphone, Spoken Language.
- [ ] ⌃⌥M (or Start Meeting) opens the consent note on the current desktop; English/Deutsch switch; Copy says
      "Note for the chat copied"; Cancel starts nothing; **Start Meeting in the note starts at once** (one click).
- [ ] While running: red menu-bar icon, tooltip "Transcribing meeting", macOS's orange microphone dot; the window
      header shows a red dot and a running clock.
- [ ] Spoken Language German, speak German into the Mac: text appears live, grey while provisional.
- [ ] Wispr Flow dictation still works while a meeting is transcribed.
- [ ] ⌃⌥T during a meeting: subtitles do not start, the status says why. Starting a meeting while subtitles run
      stops the subtitles.
- [ ] Stop Meeting (or ⌃⌥M): the last sentence still arrives, the clock stops, Copy Transcript gives
      "[m:ss] text" lines, the red icon goes away.
- [ ] Closing the window during a meeting keeps it running; "Show Transcript Window" brings it back.
- [ ] Settings > Meeting > Meeting Models: Download shows progress (about 1.3 GB, once); afterwards the row says
      "Downloaded, 1.3 GB". Then switch Wi-Fi off: a whole meeting still works.
- [ ] Spoken Language Auto-detect (models downloaded): a German and English conversation is transcribed live,
      about a second behind, with "Speaker 1/2/..." labels.
- [ ] After Stop the header says "Improving the transcript and speakers..." with progress; then the transcript is
      replaced by the cleaner one. Names you gave speakers during the meeting carry over.
- [ ] Click a speaker's name, type a name, Enter: it changes everywhere, and Copy Transcript uses it.
- [ ] During a meeting, `~/Library/Application Support/Untertitel/MeetingAudio` holds one unreadable `.spool` file;
      after the improvement it is empty.
- [ ] Delete the models in Settings: Auto-detect says it needs them again; a chosen language still works.
- [ ] Save Transcripts off (default): after a meeting nothing appears in `~/Untertitel/Meetings`; the next
      consent note warns that the last transcript will be cleared.
- [ ] Save Transcripts on: the consent note adds "I keep the written transcript as my notes."; after Stop the window
      says "Saved as ... Meeting.md"; the Markdown file opens with speakers and times; rename a speaker and the
      file follows.
- [ ] "Delete Transcript" in the window removes the file and clears the window in one click. Settings > Delete All
      Transcripts asks once, then empties the folder.
- [ ] `git -C ~/untertitel status` never lists `Meetings/` (the folder is the project folder's twin on this Mac).

## Overlay over calls
- [ ] Visible over full-screen Zoom and full-screen Teams.
- [ ] Behaviour while *you* share your screen (is the overlay captured in the share? note it).
- [ ] Multiple displays: overlay stays where you put it.
