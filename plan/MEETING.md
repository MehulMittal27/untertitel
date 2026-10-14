# M7 - Meeting transcription (in-person meetings, speaker labels, no translation)

Approved 14 Oct 2026. Built in steps, each on its own branch:

1. Speech-to-text comparison (results below; throwaway, nothing in the app).
2. Meeting mode with Apple speech-to-text: popover mode, window, consent note, indicator, ⌃⌥M. No new dependency.
3. FluidAudio: live speaker labels, Auto-detect through FluidAudio's live model, and the pass after Stop
   (Parakeet Ultra re-transcription plus the offline VBx speaker pass) on temporary encrypted audio.
4. Saving transcripts as Markdown in `~/Untertitel/Meetings` (opt-in) and deleting them.
5. Soniox with speaker labels, off by default.

## Rules (from the approved plan)

- Source: the microphone. "Meeting" mode in the popover, separate from call subtitles; only one runs at a
  time (starting a meeting stops subtitles; subtitles refuse to start during a meeting).
- Free and on-device by default, works without internet once the models are downloaded. Models download only
  through the Settings button; otherwise FluidAudio's offline switch is on.
- Consent note before every start, in English or German, with Start inside the note (one click).
- Visible "Transcribing meeting" indicator: red menu-bar icon and the window header.
- Transcripts are saved only when switched on, into `~/Untertitel/Meetings`, kept out of iCloud, one-click delete.
- Temporary audio for the pass after Stop stays on this Mac, encrypted, and is deleted right after.

## Speech-to-text comparison (14 Oct 2026, this Mac, FluidAudio 0.17.7)

FLEURS test set, first 200 utterances each: English (en_us, 32 min) and German (de_de, 47 min). Word error rate
in %, lower is better, all engines scored with the same normaliser (lowercase, no punctuation). "No digits"
leaves out sentences whose reference has numbers, which models write differently from the reference.

| Engine | When | EN | EN no digits | DE | DE no digits | Speed |
|---|---|---:|---:|---:|---:|---:|
| Apple SpeechAnalyzer, language chosen | live | 7.6 | 6.9 | 6.8 | 5.7 | 46-92x real time |
| FluidAudio live model (Nemotron multilingual), 2.24 s, language chosen | live | 9.8 | 7.2 | 10.0 | 7.4 | ~105x |
| FluidAudio live model, 2.24 s, auto | live | 9.6 | 6.9 | 10.1 | 7.7 | ~105x |
| FluidAudio live model, 1.12 s, auto | live | 9.7 | 7.0 | 10.1 | 7.7 | ~81x |
| Parakeet TDT v3, auto | after Stop | 5.6 | 4.4 | 5.4 | 4.4 | ~140x |
| Parakeet Ultra, auto | after Stop | 5.1 | 4.3 | 4.3 | 3.8 | ~140x |

- Apple with the wrong language (100 utterances): set to German on English speech 42.5 %, set to English on
  German speech 91.3 %. Apple cannot detect the language.
- Live delay: Apple shows text within about 0.1 s of the audio it covers (provisional words). The FluidAudio
  live model shows text once per chunk, about 1.1 s or 2.2 s behind by design. Parakeet works on finished audio.
- Downloads: live model 590 MB per delay setting, Parakeet Ultra 613 MB, Parakeet v3 461 MB.

Decision: with a spoken language chosen, live text comes from Apple (most accurate live, instant). With
Auto-detect (the default, for meetings that mix German and English), live text comes from the FluidAudio live
model at 1.12 s. After Stop, Parakeet Ultra re-transcribes the whole meeting, auto-detecting per sentence.

## How step 3 works

- `Packages/MeetingKit` is the only code that imports FluidAudio 0.17.7 (exact), with `traits: []` so the NeMo
  text-normalisation binary is not linked (SwiftPM still fetches it into its cache; the app contains none of it).
- Models: live multilingual Nemotron (`latin/1120ms`), Parakeet Ultra, LS-EEND `ami`, pyannote community-1 with
  VBx; about 1.3 GB in `~/Library/Application Support/FluidAudio/Models`, marked complete by
  `untertitel-meeting-models.json`. `MeetingModels.blockDownloads()` runs at launch; only Settings > Meeting >
  Download lifts it, for the length of the download.
- Live: Apple for a chosen language, the Nemotron model for Auto-detect (`FluidLiveRecognizer`, sentences cut by
  `LiveWordSegmenter`), speakers from LS-EEND (`FluidSpeakerTracker`), matched by time overlap
  (`MeetingAlignment.speaker`) and numbered in order of appearance.
- Audio for the pass after Stop: `MeetingAudioSpool`, 16-bit blocks sealed with AES-GCM, key in memory only, file
  mode 600, folder excluded from backups, deleted as soon as it is read; leftovers removed at launch.
- After Stop: offline diarization plus Parakeet Ultra on the whole meeting, words grouped by speaker
  (`MeetingAlignment.segments`), names carried over by overlap (`carryNames`). A failure keeps the live transcript.

End-to-end check (14 Oct 2026, opt-in test `MeetingEndToEndTests`, 43 s synthetic meeting, three macOS voices,
German and English): live text and labels arrived while it played; after Stop the transcript was redone in about
9 s and the audio file was gone. The offline speaker pass placed every turn boundary within about 0.1 s but put the
two male voices into one speaker (2 found, 3 present); a sentence that switches language midway ("Klar, kein
Problem. We are about twelve percent over plan") came out garbled in both passes.

## How step 4 works

- Settings > Meeting > Save Transcripts (off by default). After Stop (and after the improved pass), the transcript
  is written as `YYYY-MM-DD HH-MM Meeting.md` (title, duration, speakers, then speaker and time per turn; speech
  that looks like Markdown is escaped), file mode 600. Renaming a speaker afterwards rewrites the file.
- `MeetingTranscriptStore` refuses to write when the folder, links resolved, lies in iCloud Drive
  (`~/Library/Mobile Documents`), a File Provider folder (`~/Library/CloudStorage`: Dropbox, OneDrive, Google
  Drive), `~/Dropbox`, or is an iCloud item; it checks before creating anything. `~/Untertitel` is outside the
  Desktop and Documents folders iCloud can sync.
- One click deletes a meeting's file for good (window). Settings > Delete All Transcripts asks once first.
- With saving off, the consent note warns when the previous meeting's transcript would be cleared.
- Case-insensitive file system: `~/Untertitel/Meetings` is the same folder as `~/untertitel/Meetings` inside this
  checkout, so `.gitignore` ignores `/Meetings/`.

## How step 5 works (Soniox, off by default)

Settings > Meeting has two choices, also in the popover:
- Live Transcription: On this Mac (default) or Soniox (about $0.12/h). Soniox runs on the same cloud client as
  subtitles, with Soniox's advice for meetings (14 Oct 2026): speaker diarization on, endpoint detection off,
  no translation, language identification on, the spoken language as a hint unless Auto-detect. Subtitles keep
  endpoint detection on. The connection is not closed after 20 s of silence (speaker numbers restart with every
  connection); the 3-minute no-speech pause stays, shown in the window with Resume (auto-resume follows the
  existing setting, off by default). The connection opens only once there is sound, Stop closes it at once, the
  menu-bar icon shows the orange "$" while it is open, and the window shows the meeting's cost.
- After Stop: Improve on this Mac (default; needs the models), Improve with Soniox (recorded-file API,
  `stt-async-v5`, about $0.10/h), or Keep the live transcript. The Soniox pass uploads the meeting once as a WAV
  built in memory, with speaker diarization, polls until done, reads the tokens, and deletes the transcription
  and the file at Soniox, also when it fails. The audio is kept locally (encrypted spool) only when a pass
  after Stop will use it.
- The consent note says what goes to Soniox: live ("while we talk") and/or the recording afterwards ("once ...
  and deleted there right after"); with nothing sent it keeps "nothing is sent anywhere".
- Usage goes into the cost record: live seconds at the real-time price, file seconds at the file price.

## Licences

FluidAudio: Apache-2.0 (its prebuilt text-normalisation binary is switched off). Models: Parakeet v3 and Ultra
CC-BY-4.0, Nemotron multilingual streaming OpenMDW-1.1, LS-EEND MIT, pyannote community-1 diarization
CC-BY-4.0 (attribution in the app's acknowledgements).
