# Soniox real-time API: notes for the second cloud engine (M5b)

Checked against Soniox's documentation on 12 Oct 2026. **Not yet run against the real service**: no key was
available and no live session was allowed. Anything marked (verify) needs a first run with a real key.

- WebSocket reference: https://soniox.com/docs/stt/api-reference/websocket-api
- Real-time translation: https://soniox.com/docs/stt/rt/real-time-translation
- Keepalive: https://soniox.com/docs/stt/rt/connection-keepalive
- Pricing: https://soniox.com/pricing

## What it is

Streaming speech-to-text with translation in the same call. Text only: there is no translated speech to discard.
About **$0.12 per hour** ($0.002 per minute). Soniox states it charges "for the full stream duration, not just the
audio processed", so an open connection costs money whether or not anyone speaks. The app's guardrails (connect on
the first sound, close after ~20 s of silence, pause after 3 min without speech, close at once on Stop) apply
unchanged, and matter just as much.

## Connection

- `wss://stt-rt.soniox.com/transcribe-websocket`
- Key in the `Authorization: Bearer <key>` header. The `api_key` field of the start message is deprecated and is
  not used.
- The client speaks first: one JSON configuration message, then audio at once. There is no acknowledgement.

```json
{
  "model": "stt-rt-v5",
  "audio_format": "s16le",
  "sample_rate": 24000,
  "num_channels": 1,
  "language_hints": ["de", "en"],
  "enable_endpoint_detection": true,
  "translation": { "type": "one_way", "target_language": "en" },
  "context": {
    "terms": ["Vertrieb"],
    "translation_terms": [{ "source": "Vertrieb", "target": "Sales" }]
  }
}
```

- `model`: `stt-rt-v5` is the example in the reference (verify it is the current real-time model).
- `context` carries the app's glossary: every term as a recognition hint, and each term that has a translation as
  a translation pair. At most 200 entries are sent (the engine's limit is 8000 tokens of context).
- Audio: binary frames of 16-bit little-endian mono PCM at 24 kHz, 200 ms each (the same chunks OpenAI gets).
- End of stream: an **empty text frame**. The app sends it and closes the socket without waiting.
- One connection carries at most 300 minutes of audio; then error 413. The app opens a new connection.

## Responses

```json
{ "tokens": [
    { "text": "Guten", "is_final": true,  "translation_status": "original" },
    { "text": " Morgen", "is_final": false, "translation_status": "original" },
    { "text": "Good", "is_final": true, "translation_status": "translation" }
  ],
  "final_audio_proc_ms": 400, "total_audio_proc_ms": 900 }
```

- Final tokens are append-only. **Non-final tokens are provisional**: each response's non-final tokens replace the
  previous response's. The app shows them in the draft and commits only final text.
- `translation_status`: `"translation"` for translated tokens; `"original"` or `"none"` for spoken ones.
- `<end>` (endpoint detected) and `<fin>` are markers, not text (verify they arrive as tokens with these texts).
- `{"tokens": [], "finished": true}` ends the stream.
- Errors: `{"error_code": 401, "error_type": "...", "error_message": "..."}`, then the server closes. 401, 402 and
  403 (bad key, no balance, no permission) end the session as a key problem; 413 reconnects; anything else ends
  the session and the app carries on with the on-device engine.

## Where it lives

`SonioxWire` in `Sources/V2SApp/Services/CloudEngineWire.swift` is the whole of the engine-specific code. The
connection rules are shared with OpenAI in `OpenAITranslateClient`. The key is stored in the Keychain under
`soniox-api-key`.

## Still unverified (needs a run with a real key)

- That `stt-rt-v5` is accepted and `s16le` at 24 kHz is the right format name.
- How quickly final tokens follow the speaker, and whether captions keep up as well as with OpenAI.
- Whether translated tokens arrive provisional first, as the app assumes they may.
- What the bill shows after a session with long silences.
