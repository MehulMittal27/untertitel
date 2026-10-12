# Soniox real-time API — notes for M5

Collected 12 Oct 2026. **Check the official docs before coding; anything marked (verify) is unconfirmed.**
- Real-time translation guide: https://soniox.com/docs/stt/rt/real-time-translation
- WebSocket API reference: https://soniox.com/docs/stt/api-reference/websocket-api
- Keepalive: https://soniox.com/docs/speech-to-text/core-concepts/connection-keepalive
- A working open-source client to compare against (Python): Pipecat's `pipecat/services/soniox/stt.py`

## Connection

- Endpoint: `wss://stt-rt.soniox.com/transcribe-websocket`
- Auth (verify): Pipecat sends `"api_key"` **inside the first JSON config message**; the translation guide's examples
  use an `Authorization: Bearer <key>` header. Use whichever the API reference documents; supporting the config
  field is the safer default.
- Soniox also offers short-lived temporary keys (verify) — useful later if keys should never sit in the app.

## First message: config JSON

```json
{
  "api_key": "<from Keychain>",
  "model": "stt-rt-v5",
  "audio_format": "pcm_s16le",
  "sample_rate": 16000,
  "num_channels": 1,
  "language_hints": ["de"],
  "enable_endpoint_detection": true,
  "context": {
    "terms": ["Fürth", "Soniox"],
    "translation_terms": [{ "source": "Werkstudent", "target": "working student" }]
  },
  "translation": { "type": "one_way", "target_language": "en" }
}
```

- `context` keys per the translation guide: `general`, `text`, `terms`, `translation_terms`. The exact shape of
  `translation_terms` items is (verify).
- Optional: `enable_language_identification` (adds `language` per token; useful when people switch to English),
  `enable_speaker_diarization` (adds `speaker`). Pipecat also sends endpoint tuning fields
  (`max_endpoint_delay_ms`, `endpoint_sensitivity`) — leave at defaults first.

## Audio

- Binary WebSocket frames of raw `pcm_s16le`, 16 kHz, mono. The docs' example sends 3840-byte chunks
  (120 ms) about every 120 ms. v2s already produces 16 kHz mono Float32 — convert with clipping to Int16.
- Keepalive: send text `{"type": "keepalive"}` if no audio has been sent for a few seconds (Pipecat: every 5 s).
- Manual finalize (optional): text `{"type": "finalize"}` forces non-final tokens to finalize; answer includes `<fin>`.
- End of stream: send an **empty** text/binary frame (`""`); wait for a response with `"finished": true`, then close.

## Responses

```json
{
  "tokens": [
    { "text": "Wir", "is_final": true,  "translation_status": "original",    "language": "de", "start_ms": 480, "end_ms": 610 },
    { "text": " treffen", "is_final": false, "translation_status": "original", "language": "de", "start_ms": 620, "end_ms": 900 },
    { "text": "We", "is_final": false, "translation_status": "translation", "language": "en" }
  ],
  "finished": false
}
```

- `is_final: true` tokens arrive **once** — append them. Non-final tokens are a full replacement each response —
  keep only the latest set.
- `translation_status`: `"none"` (no translation configured), `"original"` (spoken token), `"translation"`
  (translated token). Translated tokens have **no timestamps**.
- Token `text` includes its leading space; concatenate as-is.
- Special tokens: `<end>` = endpoint detected (sentence/turn boundary); `<fin>` = reply to a manual finalize.
  Don't render them.
- Errors: `error_code` + `error_message` in a response, then the server closes. Treat auth errors as non-retryable.

## Assembly strategy (suggested)

```
state: finalOriginal, finalTranslation (strings since last <end>)
on response:
  nonFinalOriginal    = concat(non-final tokens where status == original)
  nonFinalTranslation = concat(non-final tokens where status == translation)
  for final tokens in order:
     original    → finalOriginal += text
     translation → finalTranslation += text
     "<end>"     → mark sentence boundary pending
  emit draft(German = finalOriginal + nonFinalOriginal, English = finalTranslation + nonFinalTranslation)
  if boundary pending and (finalTranslation complete or 1.5 s since boundary):
       emit sentence(German = finalOriginal, English = finalTranslation); reset
```

The translation for a sentence may finish after the `<end>` token for the original, so the sentence is emitted once
its English is final or after a short timeout. Test this with fixtures, including translation arriving 2 responses late.

## Pricing (for the settings screen)

$0.12 per hour real-time, translation included (soniox.com/pricing, checked 12 Oct 2026).
