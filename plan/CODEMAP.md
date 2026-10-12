# Code map — v2s as of upstream commit `11eb6b8` (3 Oct 2026)

Line numbers are approximate and will drift. Search for the symbol names, don't trust the numbers.
All paths are under `Sources/V2SApp/`.

## How audio becomes a subtitle today

```
InputSource (app or mic)                      Models/InputSource.swift
  └─ AppModel.startSession()                  App/AppModel.swift ~560
       └─ LiveTranscriptionSession.start(     Services/LiveTranscriptionSession.swift ~255
            source:, localeIdentifier:, modeConfig:, contextualStrings:,
            transcriptHandler: (RecognizedSentence) -> Void,   // final source sentences
            partialHandler:   (DraftSegment?) -> Void,         // live draft
            errorHandler:, fatalErrorHandler:)
            ├─ ApplicationAudioCapture        same file ~3187  (Core Audio process tap,
            │                                  CATapDescription(monoMixdownOfProcesses:) ~3250)
            ├─ append(audioBuffer:)           ~1084  → 16 kHz mono Float32 `processingBuffer`,
            │                                  noise cleanup, Silero VAD, then:
            │     recognitionBackend == .speechAnalyzer → appendToSpeechAnalyzer(_:) ~1126
            │     else legacy SFSpeechRecognizer request
            └─ results → TranscriberResultLedger ~2703 → transcriptHandler / partialHandler
  AppModel.enqueueRecognizedSentence(...)     ~1965  → QueuedCaption (~3288)
       └─ translateCaption(_:) ~2662 → translatedText(for:) ~2846
             └─ TranslationCoordinator.translate(...)   Services/TranslationCoordinator.swift
  AppModel.handlePartialDraft(...) ~1639 → scheduleDraftTranslation(...) ~1756
       └─ TranslationCoordinator.translate(...) for live drafts
  → overlayState (OverlayPreviewState) → UI/Overlay/OverlayWindowController + OverlayView
```

## Key files

| File | What it does | Notes for us |
| --- | --- | --- |
| `App/AppModel.swift` (~3.4k lines) | Central `ObservableObject`: settings, sources, session start/stop, caption queue, draft + final translation, transcript, overlay state | `toggleSession()` ~550 is what the hotkey calls. `@Published sessionState`. Don't restructure. |
| `App/AppDelegate.swift` | App lifecycle, single-instance lock, source refresh timer | Register the global hotkey here (or in a small new `HotkeyService`). |
| `Services/LiveTranscriptionSession.swift` (~3.9k lines) | Capture + recognition per source; also contains `ApplicationAudioCapture`, `ApplicationCaptureHealth` (~3020), recovery policy | Cloud engine plugs in at `append(audioBuffer:)` via a new `RecognitionBackend` case. |
| `Services/TranslationCoordinator.swift` | Wraps Apple `TranslationSession` (view-anchored via `.translationTask`) | Leave as-is; cloud engine bypasses it by supplying translations. |
| `Services/SourceCatalogService.swift` | Lists running regular apps (`NSWorkspace`) and microphones as `InputSource`s | Auto-detect (M2) builds on `loadSnapshot()`. App source ids look like `app:<bundleID>`. |
| `Services/GlossaryService.swift` | Applies `glossary: [String: String]` | On-device only. The OpenAI translate model takes no custom prompts or glossary. |
| `Services/SileroVADEngine.swift`, `SileroVADHysteresis.swift` | Voice activity detection (Core ML) | Untouched. |
| `Services/SentenceBoundaryHeuristics.swift` | Sentence segmentation for on-device path | Cloud path commits sentences in `TranslateDeltaAssembler` (VAD silence + punctuation). |
| `Models/AppSettings.swift` | Persisted settings (`Codable`, custom decoder with fallbacks) | Defaults are `inputLanguageID: "de"`, `outputLanguageID: "en"` since M0 (upstream: `"en"` / `"zh-Hans"`). New fields need `decodeIfPresent` fallbacks. |
| `Services/SettingsStore.swift` | Loads/saves `AppSettings` | Never store API keys here. |
| `Services/KeychainStore.swift` | `SecretStore` protocol + Keychain implementation | The OpenAI key lives here only (M5). |
| `Services/OpenAITranslateClient.swift`, `OpenAITranslateEvent.swift` | Cloud engine: WebSocket session, pause/resume, reconnect before expiry; wire format | Text only. Output audio events are dropped unread. |
| `Services/TranslateDeltaAssembler.swift` | Pure: transcript deltas → drafts and sentences | Unit-tested with scripted events. |
| `Services/CloudAudioEncoder.swift` | Capture → 24 kHz mono PCM16 in 200 ms chunks | Fed from the raw capture, before the 16 kHz cleanup. |
| `Services/CloudUsageLedger.swift` | Seconds streamed per day, for the cost estimate | Local file `cloud-usage.json` next to the settings. |
| `Models/SessionState.swift` | `idle / running / error` | M3 adds a "no audio" signal (separate published flag is less invasive than a new case — decide in M3). |
| `Models/SubtitleSegment.swift` | `DraftSegment` (draft text, stable prefix, scores) | M5 adds optional `translatedText`. |
| `UI/StatusBar/StatusBarController.swift` | `NSStatusItem`, `updateStatusIcon(for:)` ~70 | M3 icon states live here. |
| `UI/StatusBar/StatusBarPopoverView.swift`, `UI/Shared/QuickSettingsControls.swift` | Popover with Start/Stop, source + language pickers | Hotkey hint and engine picker can go here. |
| `UI/Settings/SettingsView.swift` | Settings window | Hotkey recorder (M1), engine + API key field (M5). |
| `UI/Overlay/OverlayWindowController.swift`, `OverlayView.swift` | Floating subtitle window, history (`overlayHistoryVisibleCount`, `scrollOverlayHistory(by:)` in AppModel ~844–856) | Catch-up shortcut (M4) drives the existing history. |
| `UI/Settings/TranscriptView.swift`, `AppModel.transcriptText(isTranslation:)` ~2176 | Transcript view + text export | "Copy last 2 minutes" (M4) builds on `transcriptEntries`. Entries have no timestamps today. |
| `Localization/AppLocalization.swift` | All UI strings, keyed by `AppTextKey` | Every new string goes here (required for upstream PRs). |
| `Config/Info.plist` | `LSUIElement`, `NSAudioCaptureUsageDescription`, `NSSpeechRecognitionUsageDescription` | M5 needs network access only if the app is sandboxed — check entitlements first. |

## Things that already exist (don't rebuild them)

- Per-app audio capture with automatic rebuild when the app's audio processes change or go silent
  (`ApplicationCaptureEvent`, `ApplicationCaptureHealth`, `.silentWhileAppIsPlaying`). The UI is **not** told when
  this happens — M3 adds that.
- `AudioHardwareProcess(id:).isRunningOutput` is already used (~3553) to check whether an app is playing audio;
  reuse it for auto-detect in M2.
- Draft vs final captions, late-translation backfill, translation timeouts and session recovery.
- Glossary, transcript summary (Apple Intelligence), overlay styling, Sparkle updates.

## Seams we add

| Milestone | Seam |
| --- | --- |
| M1 hotkey | New `HotkeyService` (registered from `AppDelegate`) → `appModel.toggleSession()`; settings field for the binding. |
| M2 auto-detect | New `CallAppDetector` that ranks `SourceCatalogService` app sources; used by `startSession()` only when no source is selected. |
| M3 no-audio state | New callback from `LiveTranscriptionSession` to `AppModel` when capture is silent while the app plays, and when audio resumes → published flag → `StatusBarController`. |
| M5 cloud engine (built) | `RecognitionBackend.openAITranslate`; `LiveTranscriptionSession.start(cloudEngine:)`; `OpenAITranslateClient` + `TranslateDeltaAssembler`; `RecognizedSentence.translatedText` + `DraftSegment.translatedText`; `AppModel.translatedText(for:)` and `handlePartialDraft` short-circuit when the engine supplied a translation; `AppModel.startSession(fallback:)` restarts on-device when the cloud engine fails. |
