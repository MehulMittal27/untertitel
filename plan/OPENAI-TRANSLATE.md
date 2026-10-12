# OpenAI gpt-realtime-translate — notes for M5

Mehul chose this as the cloud engine (12 Oct 2026), instead of Soniox. Collected 12 Oct 2026 from OpenAI's docs.
Checked against the live guide and event reference on 12 Oct 2026 while building M5; the corrections are folded in
below and the points that only a run with a real key can settle are listed under "Still unverified".
- Event reference: https://developers.openai.com/api/reference/resources/realtime/translation-client-events and
  `.../translation-server-events`
- Model page: https://developers.openai.com/api/docs/models/gpt-realtime-translate
- Cookbook with working browser, Twilio and LiveKit demos:
  https://developers.openai.com/cookbook/examples/voice_solutions/realtime_translation_guide
- The cookbook links a "Live Translation guide" with the full event reference — read it for error events and
  whether audio output can be turned off.

## What it is

A streaming speech-to-speech translation model. It returns **translated audio plus transcript deltas while the
source audio is still arriving**.

**Mehul wants text only.** We use the transcripts: the English line (output transcript) and the German line (input
transcript). The app must **never play the translated audio**. The docs (checked 12 Oct 2026) show no field to turn
audio output off, so receive `session.output_audio.delta` and discard it without decoding. Price is per minute of
input audio, so the unused audio adds no cost. If the guide later documents a text-only option, use it.

- Price: **$0.034 per minute** of audio (~$2.04/hour), billed by duration.
- Source language: auto-detected (70+ languages). Target: `en` is supported.
- No custom prompts, so **no glossary support** with this engine. Keep the on-device glossary path unchanged.

## Connection (native macOS app → WebSocket)

- `wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate`
- Header: `Authorization: Bearer <OpenAI API key from Keychain>`.
  (The browser demo uses short-lived client secrets from `POST /v1/realtime/translations/client_secrets` to keep the
  key out of web pages. For a personal native app with the key in the Keychain, a direct key is fine.)
- WebRTC is also offered (`POST /v1/realtime/translations/calls` with an SDP offer). Use WebSocket: no WebRTC stack
  needed, and we already have PCM buffers.

## Session config

The server sends `session.created` first (it carries `expires_at`: sessions have a time limit, length not
documented). Then send `session.update`; the server answers `session.updated`.

```json
{
  "type": "session.update",
  "session": {
    "audio": {
      "input": {
        "transcription": { "model": "gpt-realtime-whisper" },
        "noise_reduction": null
      },
      "output": { "language": "en" }
    }
  }
}
```

- The **model is set in the URL only**. `session.update` accepts just `audio.output.language`,
  `audio.input.transcription` and `audio.input.noise_reduction`; there is no text-only switch.
- `audio.input.transcription` is what gives us the **German source line**. Keep it.
- `noise_reduction`: `near_field` is meant for headset microphones and `far_field` for room microphones. App audio
  is neither, so the app sends `null` (off). Compare by hand if recognition is poor.
- To end: send `session.close`; the server flushes remaining transcript output and replies `session.closed`.
  Then close the socket. On toggle-off, don't wait more than ~1 s for this.

## Audio in

- Client event `session.input_audio_buffer.append` with a base64 `audio` field.
- Format: **PCM16 little-endian, 24 kHz, mono**, base64-encoded.
  v2s's `processingBuffer` is 16 kHz mono Float32, so resample to 24 kHz (`AVAudioConverter`) and convert to Int16.
  Alternatively convert from the capture buffer before v2s downsamples it. Pick whichever is simpler and correct.
- **Stream continuously, including silence.** Don't gate audio on VAD.
- Batch into **200 ms chunks** (4,800 samples = 9,600 bytes before base64). The engine consumes 200 ms frames;
  shorter chunks are buffered server-side and longer ones are split.
- If audio stops and later resumes, the model treats it as contiguous, so the app sends silence whenever the
  capture delivers nothing.
- There is no `response.create`, no turns, no conversation state.

## Events out

| Event | Meaning | Use |
| --- | --- | --- |
| `session.input_transcript.delta` | Source-language (German) transcript text, `event.delta` | German line |
| `session.output_transcript.delta` | Target-language (English) transcript text, `event.delta` | English line |
| `session.output_audio.delta` | Translated audio chunk (base64 24 kHz PCM16, 200 ms) | Discard. Never play. |
| `session.created` / `session.updated` / `session.closed` | Session started / configured / ended | Connection state |
| `error` | `error.type`, `error.code`, `error.message`. Most errors are recoverable and leave the session open | Fatal only before the session is configured (R14) |

Deltas are **append-only text**, with an optional `elapsed_ms` (position on the audio timeline, 200 ms steps).
There is no sentence-boundary or "final" event: confirmed in the event reference.

An invalid API key is refused *after* a successful WebSocket handshake, with an `error` event of type
`invalid_request_error` and code `invalid_api_key` (observed 12 Oct 2026 with a made-up key).

## Turning deltas into v2s drafts and sentences

v2s expects live drafts (`DraftSegment`) plus final `RecognizedSentence`s. This was the suggested approach;
`TranslateDeltaAssembler` follows it with two changes found while building: a commit also waits until no delta has
arrived for ~0.35 s (the translation trails the source, and committing mid-stream splits a sentence from its
translation), and the long-monologue cut is triggered by the translation's length and takes the same number of
sentences from the source.

```
german += input delta ; english += output delta
emit draft(German = tail of german since last commit, English = tail of english since last commit)

commit a sentence when either:
  - English tail ends with . ? ! and v2s VAD reports silence ≥ ~300 ms, or
  - VAD silence ≥ ~1.2 s (speaker paused), or
  - tail exceeds ~200 characters (long monologue): cut at the last punctuation
on commit: emit RecognizedSentence(text: German tail, translatedText: English tail); advance both commit markers
```

- The model **waits for enough context** before translating (German verb-final sentences), so English can trail the
  German slightly. That's expected; don't commit English before VAD silence.
- **Mixed language:** if someone speaks English, the model may emit no translation for that part. When the German
  (input) tail has text but no English arrives within ~1.5 s after silence, commit with the source text as the
  English line.
- Keep this logic in a pure type (`TranslateDeltaAssembler`) so it can be unit-tested with scripted event sequences.

## Cost guardrails (added 12 Oct 2026)

Billing follows audio duration, silence included, so the app limits what it streams:
- after ~3 minutes without speech the connection is closed and the overlay shows "Paused - no audio"; it reopens by
  itself when speech returns, replaying the last second of audio so the first words are not lost;
- a pause that lasts 15 minutes stops the session fully, as if subtitles had been switched off, so a forgotten
  session cannot start billing again later (time the Mac spends asleep counts);
- the cloud engine takes one source at a time;
- the popover shows minutes streamed today and the estimated cost, kept in a local file only.

## Still unverified (needs a run with a real key)

- How long a session lasts before `expires_at`. The app reconnects at a pause shortly before it.
- Whether the German (`gpt-realtime-whisper`) deltas carry punctuation.
- Real latency, and whether the `OpenAI-Safety-Identifier` header shown in the docs' examples is ever required
  (the app does not send it).

## Measuring (R16)

The cookbook recommends measuring source-to-caption delay. Log per sentence (DEBUG only): audio time of speech end,
first German delta, first English delta, commit time.
