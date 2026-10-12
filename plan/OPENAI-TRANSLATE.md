# OpenAI gpt-realtime-translate — notes for M5

Mehul chose this as the cloud engine (12 Oct 2026), instead of Soniox. Collected 12 Oct 2026 from OpenAI's docs.
**Check the live docs before coding; anything marked (verify) is not confirmed.**
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

Send a `session.update` after connecting (verify exact envelope against the guide):

```json
{
  "type": "session.update",
  "session": {
    "model": "gpt-realtime-translate",
    "audio": {
      "input": {
        "transcription": { "model": "gpt-realtime-whisper" },
        "noise_reduction": { "type": "near_field" }
      },
      "output": { "language": "en" }
    }
  }
}
```

- `audio.input.transcription` is what gives us the **German source line**. Keep it.
- `noise_reduction`: call audio is already clean and digital; test with and without (verify which helps).
- Server confirms with `session.created`.
- To end: send `session.close`; the server flushes remaining transcript output and replies `session.closed`.
  Then close the socket. On toggle-off, don't wait more than ~1 s for this.

## Audio in

- Client event `session.input_audio_buffer.append` with a base64 `audio` field.
- Format: **PCM16 little-endian, 24 kHz, mono**, base64-encoded.
  v2s's `processingBuffer` is 16 kHz mono Float32, so resample to 24 kHz (`AVAudioConverter`) and convert to Int16.
  Alternatively convert from the capture buffer before v2s downsamples it. Pick whichever is simpler and correct.
- **Stream continuously, including silence.** Don't gate audio on VAD.
- Batch into ~100 ms chunks (2,400 samples = 4,800 bytes before base64).
- There is no `response.create`, no turns, no conversation state.

## Events out

| Event | Meaning | Use |
| --- | --- | --- |
| `session.input_transcript.delta` | Source-language (German) transcript text, `event.delta` | German line |
| `session.output_transcript.delta` | Target-language (English) transcript text, `event.delta` | English line |
| `session.output_audio.delta` | Translated audio chunk (base64 24 kHz PCM16, 200 ms) | Discard. Never play. |
| `session.created` / `session.closed` | Session started / ended | Connection state |
| errors | Event type string not documented (the Java example checks `event.error()`) — log unknown event types in DEBUG | Fallback (R14) |

Deltas are **append-only text**. There is no documented sentence-boundary or "final" event (verify in the guide).

## Turning deltas into v2s drafts and sentences

v2s expects live drafts (`DraftSegment`) plus final `RecognizedSentence`s. Suggested approach:

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

## Measuring (R16)

The cookbook recommends measuring source-to-caption delay. Log per sentence (DEBUG only): audio time of speech end,
first German delta, first English delta, commit time.
