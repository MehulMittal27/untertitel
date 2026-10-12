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
| `App/AppModel.swift` (~3.4k lines) | Central `ObservableObject`: settings, sources, session start/stop, caption queue, draft + final translation, transcript, overlay state | The hotkey calls `toggleSessionFromHotkey()` (the Start/Stop button's `toggleSession()` plus `toggleFeedback` for the label and sound). `@Published sessionState`. Don't restructure. |
| `App/AppDelegate.swift` | App lifecycle, single-instance lock, source refresh timer | `installToggleHotkey()` wires `HotkeyService`, the toggle sound and the popover-on-failure callback. |
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
| `UI/StatusBar/StatusBarController.swift` | `NSStatusItem`, popover, `updateStatusItem(_:)` | The popover window must keep `popoverCollectionBehavior`, or it opens on the wrong desktop. M3 icon states go through `StatusItemAppearance`. |
| `UI/StatusBar/StatusItemAppearance.swift` | Pure mapping: session + cloud state → icon symbol, color, "$" marker | Off / on-device / cloud billing / cloud paused / error. |
| `UI/StatusBar/StatusBarPopoverView.swift`, `UI/Shared/QuickSettingsControls.swift` | Popover with Start/Stop, source + language pickers | The Start/Stop button shows the shortcut; engine picker lives here too. |
| `UI/Settings/SettingsView.swift` | Settings window | Shortcut card (`ShortcutSettingsSection` in `HotkeyRecorderView.swift`), engine + API key field (M5). |
| `UI/Overlay/OverlayWindowController.swift`, `OverlayView.swift` | Floating subtitle window, history (`overlayHistoryVisibleCount`, `scrollOverlayHistory(by:)` in AppModel ~844–856) | Catch-up shortcut (M4) drives the existing history. |
| `UI/Overlay/CaptionOverlayView.swift` | Cloud-mode overlay: one caption block like TV subtitles (`CaptionOverlayContent`, `CaptionOverlayLayout`, `CaptionBlockView`) | Used while `AppModel.usesCaptionOverlay`; the scrolling flow in `OverlayView` stays for on-device mode. History is still collected for M4's catch-up. |
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
| M1 hotkey (built) | `HotkeyService` + `CarbonHotkeyRegistrar` (`Services/HotkeyService.swift`) → `AppModel.toggleSessionFromHotkey()`; `HotkeyBinding`, `HotkeyBindingRules` (`Models/HotkeyBinding.swift`); `SystemShortcutCatalog` reads the shortcuts macOS has enabled; `AppSettings.toggleHotkey` / `playsToggleSound` / `showsToggleLabel`; `HotkeyRecorder` + `ShortcutSettingsSection` in Settings; `ToggleConfirmationController` shows "Subtitles on/off" next to the caption area; `SystemToggleSoundPlayer`. macOS does not report a combination another app already registered, so that clash cannot be detected. |
| M2 auto-detect (built) | `CallAppDetector` + `CallAppCatalog` (`Services/CallAppDetector.swift`, pure ranking: in a call > playing > running, then Safari, dedicated call apps, other browsers, then most recently used); `ApplicationAudioActivityProbe` (in `LiveTranscriptionSession.swift`, reads Core Audio's per-process microphone and speaker flags); `AppModel.applyAutomaticSourceSelection` runs inside `refreshSources()` while no session runs. It picks **only among `approvedSourceIDs`** (apps the user chose or ran a session on); an unapproved call app becomes `suggestedSource`, shown in the popover, never started. `chooseSources(_:)` is the picker's path: it approves and switches automatic selection off. |
| M3 no-audio state (built) | `LiveTranscriptionSession.start(captureHealthHandler:)` reports `CaptureHealthEvent` (`.silentWhileSourcePlays` from the existing capture-health check, `.receivingAudio` when signal returns) → `CaptureSilenceTracker` → `AppModel.isCaptureSilent` → yellow warning triangle in `StatusItemAppearance`, plus the permission hint in the status line, the overlay placeholder and the popover. The existing check fires after 8 s of silence while the app plays (then 15, 30, 60 s); that timing was left as it is. |
| M4 catch-up and copy (built) | `TranscriptEntry.createdAt` (memory only); `RecentTranscriptFormatter` (last 120 s, translation line then original line); `AppModel.copyRecentTranscript()` and `toggleCatchUp()`; `CaptionCatchUpView` + `CaptionCatchUpLayout` in `CaptionOverlayView.swift` (cloud overlay; the on-device overlay pages its existing history instead); `AppHotkeys` holds the three `HotkeyService`s (toggle, catch-up, copy), each with its own `CarbonHotkeyRegistrar`; `OverlayNotice` reuses the confirmation label for "Copied the last 2 minutes". |
| M6 daily driver (built) | Display name "Untertitel": `CFBundleDisplayName` in `Config/Info.plist`, `AppBuildInfo.displayName`, the usage descriptions and every localized string that named the app. The bundle identifier, product name and executable stay `v2s`. `AppDelegate.wasLaunchedAsLoginItem` keeps Settings closed at a login launch (the launch-at-login toggle itself is upstream's `LaunchAtLoginService`). `scripts/build-app.sh --release` builds the optimized app and removes the debug copy. `AppModel.disclosureText` / `copyDisclosure()` behind the speech-bubble button in the popover footer. **Not changed, needs a decision: Sparkle still points at upstream's update feed.** |
| M5b Soniox engine (built, never run live) | `CloudEngineWire` (`Services/CloudEngineWire.swift`) separates an engine's wire format from the connection rules: `OpenAIWire` and `SonioxWire`. `OpenAITranslateClient` runs either (`Configuration.wire`). `TranslateDeltaAssembler.setProvisional` shows Soniox's non-final tokens without committing them. `RecognitionEngine.sonioxTranslate`, `SecretAccount.sonioxAPIKey`, `CloudUsageLedger.sonioxSecondsByDay`. Notes: `plan/SONIOX.md`. |
| M5 cloud engine (built) | `RecognitionBackend.openAITranslate`; `LiveTranscriptionSession.start(cloudEngine:)`; `OpenAITranslateClient` + `TranslateDeltaAssembler`; `RecognizedSentence.translatedText` + `DraftSegment.translatedText`; `AppModel.translatedText(for:)` and `handlePartialDraft` short-circuit when the engine supplied a translation; `AppModel.startSession(fallback:)` restarts on-device when the cloud engine fails. |
