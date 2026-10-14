import SwiftUI

struct StatusBarPopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meeting: MeetingController
    @ObservedObject var meetingModels: MeetingModelsService
    let showMeetingWindow: () -> Void
    let closePopover: () -> Void
    let openAdvancedSettings: () -> Void
    let showTranscript: () -> Void
    let quitApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider().padding(.horizontal, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch model.appMode {
                    case .subtitles:
                        sourceSection
                        engineSection
                        languageSection
                        overlaySection
                    case .meeting:
                        meetingSection
                    }
                }
                .padding(16)
            }
            Divider().padding(.horizontal, 16)
            footerSection
        }
        .frame(width: 340)
        .background(.regularMaterial)
        .environment(\.locale, model.interfaceLocale)
        .v2sTranslationHost(model: model)
        .onChange(of: model.sessionState) { _, newState in
            if newState == .running {
                closePopover()
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Image(systemName: "captions.bubble.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.appDisplayName)
                        .font(.headline)
                    Text(headerStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    VersionLink(
                        versionText: model.appVersionDisplayText,
                        repositoryURL: model.appRepositoryURL,
                        font: .caption2.monospacedDigit()
                    )
                    Text(headerBadgeText)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.fill.tertiary, in: Capsule())
                }
            }
            Picker("", selection: $model.appMode) {
                Text(model.localized(.subtitlesMode)).tag(AppMode.subtitles)
                Text(model.localized(.meetingMode)).tag(AppMode.meeting)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch model.appMode {
            case .subtitles:
                Button {
                    model.toggleSession()
                } label: {
                    SessionActionButtonLabel(
                        title: model.sessionButtonTitle,
                        symbolName: model.sessionButtonSymbolName,
                        showsActivity: model.showsSessionWaitIndicator,
                        shortcutHint: model.toggleHotkeyDisplayText
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isSessionButtonDisabled || meeting.isActive)
            case .meeting:
                MeetingActionButton(model: model, meeting: meeting)
            }
        }
        .padding(16)
    }

    /// The status line under the app's name: the meeting's while the popover is in
    /// meeting mode or a meeting runs, the subtitles' otherwise.
    private var headerStatusText: String {
        guard model.appMode == .meeting || meeting.isActive else {
            return model.statusMessage
        }
        switch meeting.state {
        case .starting, .running: return model.localized(.meetingTranscribing)
        case .finishing, .improving: return model.localized(.meetingFinishing)
        case .failed(let message): return message
        case .idle, .consent: return model.localized(.ready)
        }
    }

    private var headerBadgeText: String {
        guard model.appMode == .meeting || meeting.isActive else {
            return model.sessionBadgeText
        }
        let state: SessionState = meeting.isActive ? .running : .idle
        return state.displayName(in: model.resolvedInterfaceLanguageID)
    }

    // MARK: - Meeting

    private var meetingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(model.localized(.meetingSection), icon: "person.2.wave.2")
            Text(model.localized(.meetingModeHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            MeetingControls(model: model, meeting: meeting, models: meetingModels)
            SecondaryRefreshButton(
                title: model.localized(.meetingShowWindow),
                systemImage: "macwindow",
                action: showMeetingWindow
            )
        }
    }

    // MARK: - Input Source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(model.localized(.inputSource), icon: "mic.fill")
            SettingsControlRow(label: model.localized(.sourceShort)) {
                SourceMultiSelectPicker(
                    sources: model.allSources,
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    emptyTitle: model.allSources.isEmpty ? model.localized(.noSources) : model.localized(.choose),
                    selection: model.selectedSourcesBinding
                )
            }
            AutomaticSourceControls(model: model)
            if let hint = model.captureSilentHint {
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SecondaryRefreshButton(
                title: model.localized(.refreshSources),
                action: model.refreshSources
            )
        }
    }

    // MARK: - Engine

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(model.localized(.recognitionEngine), icon: "cpu")
            SettingsControlRow(label: model.localized(.recognitionEngine)) {
                RecognitionEngineMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    selection: model.recognitionEngineSelectionBinding
                )
                .disabled(model.sessionState == .running)
            }
            if model.recognitionEngine.isCloud {
                CloudEngineCostSummary(model: model)
            }
        }
    }

    // MARK: - Languages

    private var languageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(model.localized(.languages), icon: "globe")
            SettingsControlRow(label: model.localized(.spokenLanguage)) {
                CommonLanguageMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    options: model.spokenLanguageOptions,
                    selection: model.inputLanguageSelectionBinding
                )
            }
            LanguageNotices(model: model, showsServerSpeechNotice: true)
            SettingsControlRow(label: model.localized(.subtitleLanguage)) {
                CommonLanguageMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    options: model.subtitleLanguageOptions,
                    selection: model.outputLanguageSelectionBinding
                )
            }
            SubtitleLanguageNotice(model: model)
            SettingsControlRow(label: model.localized(.modeShort)) {
                SubtitleModeMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    showsDetail: false,
                    selection: model.subtitleModeSelectionBinding
                )
            }
            SettingsControlRow(label: model.localized(.displayShort)) {
                SubtitleDisplayModeMenuPicker(
                    interfaceLanguageID: model.resolvedInterfaceLanguageID,
                    selection: model.subtitleDisplayModeSelectionBinding
                )
            }
            LanguageResourcesFooter(model: model)
        }
    }

    // MARK: - Overlay

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader(model.localized(.overlay), icon: "rectangle.on.rectangle")
                Spacer()
                Button {
                    model.copyRecentTranscript()
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.hasRecentTranscript == false)
                .help(model.localized(.copyRecentShortcut))
                .accessibilityLabel(model.localized(.copyRecentShortcut))
                Button {
                    showTranscript()
                } label: {
                    Text(model.localized(.transcript))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button {
                    if model.isOverlayVisible { model.toggleOverlayVisibility() }
                    else { model.showOverlayPreview() }
                } label: {
                    Text(model.isOverlayVisible ? model.localized(.hideOverlay) : model.localized(.showPreview))
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            VStack(spacing: 6) {
                SettingsControlRow(label: model.localized(.textOutline)) {
                    Toggle("", isOn: textOutlineEnabledBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                SettingsControlRow(label: model.localized(.attachToSource)) {
                    Toggle("", isOn: attachToSourceBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
            VStack(spacing: 8) {
                compactSlider(
                    label: model.localized(.opacity),
                    value: overlayOpacityBinding, in: 0.0 ... 1.0,
                    display: "\(Int((model.overlayStyle.backgroundOpacity * 100).rounded()))%"
                )
                compactSlider(
                    label: model.localized(.fontSize),
                    value: translatedFontBinding, in: 8 ... 34,
                    display: "\(Int(model.overlayStyle.translatedFontSize.rounded()))pt"
                )
                compactSlider(
                    label: model.localized(.sourceSize),
                    value: sourceFontBinding, in: 5 ... 28,
                    display: "\(Int(model.overlayStyle.sourceFontSize.rounded()))pt"
                )
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button { openAdvancedSettings() } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(model.localized(.advancedSettings))
            Button { quitApp() } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(model.localized(.quit))
            .help(model.localized(.quit))
            Menu {
                Section(model.localized(.disclosureButton)) {
                    ForEach(model.disclosureLanguageIDs, id: \.self) { languageID in
                        Button(model.disclosureLanguageName(for: languageID)) {
                            model.copyDisclosure(in: languageID)
                        }
                    }
                }
            } label: {
                Image(systemName: "text.bubble")
            }
            // Drawn like the plain buttons beside it, not as a pop-up control.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .accessibilityLabel(model.localized(.disclosureButton))
            .help(model.localized(.disclosureButton))
            Spacer()
            if model.selectedSources.isEmpty == false {
                Text(model.selectedSourceDisplayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Layout helpers

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    private func compactSlider(
        label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        display: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(display)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    // MARK: - Bindings

    private var overlayOpacityBinding: Binding<Double> {
        Binding(
            get: { model.overlayStyle.backgroundOpacity },
            set: { v in model.updateOverlayStyle { $0.backgroundOpacity = v } }
        )
    }
    private var translatedFontBinding: Binding<Double> {
        Binding(
            get: { model.overlayStyle.translatedFontSize },
            set: { v in model.updateOverlayStyle { $0.translatedFontSize = v } }
        )
    }
    private var textOutlineEnabledBinding: Binding<Bool> {
        Binding(
            get: { model.overlayStyle.showsTextOutline },
            set: { v in model.updateOverlayStyle { $0.showsTextOutline = v } }
        )
    }
    private var attachToSourceBinding: Binding<Bool> {
        Binding(
            get: { model.overlayStyle.attachToSource },
            set: { v in model.updateOverlayStyle { $0.attachToSource = v } }
        )
    }
    private var sourceFontBinding: Binding<Double> {
        Binding(
            get: { model.overlayStyle.sourceFontSize },
            set: { v in model.updateOverlayStyle { $0.sourceFontSize = v } }
        )
    }
}

struct VersionLink: View {
    @Environment(\.openURL) private var openURL

    let versionText: String
    let repositoryURL: URL?
    let font: Font

    var body: some View {
        Group {
            if let repositoryURL {
                Button {
                    openURL(repositoryURL)
                } label: {
                    versionLabel
                }
                .buttonStyle(.plain)
                .help(repositoryURL.absoluteString)
            } else {
                versionLabel
                    .help(versionText)
            }
        }
    }

    private var versionLabel: some View {
        Text(verbatim: versionText)
            .font(font)
            .foregroundStyle(.secondary)
    }
}
