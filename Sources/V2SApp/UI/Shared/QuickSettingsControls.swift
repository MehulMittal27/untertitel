import SwiftUI

struct SettingsControlRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            content()
        }
    }
}

struct CommonLanguageMenuPicker: View {
    let interfaceLanguageID: String
    let options: [LanguageOption]
    @Binding var selection: String

    init(
        interfaceLanguageID: String,
        options: [LanguageOption] = LanguageCatalog.common,
        selection: Binding<String>
    ) {
        self.interfaceLanguageID = interfaceLanguageID
        self.options = options
        self._selection = selection
    }

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options) { option in
                Text(option.localizedDisplayName(in: interfaceLanguageID)).tag(option.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct DefaultableLanguageMenuPicker: View {
    let interfaceLanguageID: String
    let options: [LanguageOption]
    let defaultTitle: String
    @Binding var selection: String?

    init(
        interfaceLanguageID: String,
        options: [LanguageOption] = LanguageCatalog.common,
        defaultTitle: String,
        selection: Binding<String?>
    ) {
        self.interfaceLanguageID = interfaceLanguageID
        self.options = options
        self.defaultTitle = defaultTitle
        self._selection = selection
    }

    var body: some View {
        Picker("", selection: $selection) {
            Text(defaultTitle).tag(nil as String?)
            ForEach(options) { option in
                Text(option.localizedDisplayName(in: interfaceLanguageID)).tag(Optional(option.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct SourceMenuPicker: View {
    let sources: [InputSource]
    let interfaceLanguageID: String
    let emptyTitle: String
    @Binding var selection: String?

    var body: some View {
        Picker("", selection: $selection) {
            Text(emptyTitle).tag(nil as String?)
            ForEach(sources) { source in
                Text("\(source.category.displayName(in: interfaceLanguageID)) · \(source.name)")
                    .tag(Optional(source.id))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct SourceMultiSelectPicker: View {
    let sources: [InputSource]
    let interfaceLanguageID: String
    let emptyTitle: String
    @Binding var selection: Set<String>
    @State private var isPresented = false

    private var allSourceIDs: Set<String> {
        Set(sources.map(\.id))
    }

    private var internalSources: [InputSource] {
        sources.filter { $0.category == .application }
    }

    private var deviceSources: [InputSource] {
        sources.filter { $0.category == .microphone }
    }

    private var internalSourceIDs: Set<String> {
        Set(internalSources.map(\.id))
    }

    private var deviceSourceIDs: Set<String> {
        Set(deviceSources.map(\.id))
    }

    private var isAllSourcesSelected: Bool {
        sources.isEmpty == false && selection == allSourceIDs
    }

    private var isAllInternalSourcesSelected: Bool {
        internalSourceIDs.isEmpty == false && internalSourceIDs.isSubset(of: selection)
    }

    private var isAllDeviceSourcesSelected: Bool {
        deviceSourceIDs.isEmpty == false && deviceSourceIDs.isSubset(of: selection)
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Text(menuTitle)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 12)
                .padding(.trailing, 30)
                .frame(minWidth: 180, minHeight: 32, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.fill.quaternary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
            )
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 11)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if sources.isEmpty {
                    Text(emptyTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(16)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if internalSources.isEmpty == false {
                                Button {
                                    toggleAllInternalSources()
                                } label: {
                                    HStack(spacing: 10) {
                                        SelectionCheckmark(isSelected: isAllInternalSourcesSelected)
                                        Text(AppLocalization.string(.allInternalSources, languageID: interfaceLanguageID))
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }

                            if deviceSources.isEmpty == false {
                                Button {
                                    toggleAllDeviceSources()
                                } label: {
                                    HStack(spacing: 10) {
                                        SelectionCheckmark(isSelected: isAllDeviceSourcesSelected)
                                        Text(AppLocalization.string(.allDeviceSources, languageID: interfaceLanguageID))
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }

                            if internalSources.isEmpty == false || deviceSources.isEmpty == false {
                                Divider()
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 2)
                            }

                            ForEach(sources) { source in
                                Button {
                                    toggle(source.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        SelectionCheckmark(isSelected: selection.contains(source.id))
                                        Text("\(source.category.displayName(in: interfaceLanguageID)) · \(source.name)")
                                            .font(.callout)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .frame(width: 320, height: min(max(CGFloat(sources.count) * 34, 120), 280))
                }

                Divider()

                HStack {
                    Spacer()
                    Button(AppLocalization.string(.done, languageID: interfaceLanguageID)) {
                        isPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
        }
        .fixedSize(horizontal: false, vertical: false)
    }

    private var menuTitle: String {
        let selected = sources.filter { selection.contains($0.id) }
        switch selected.count {
        case 0:
            return emptyTitle
        case 1:
            return selected[0].name
        default:
            if isAllSourcesSelected {
                return AppLocalization.string(.allSources, languageID: interfaceLanguageID)
            }
            return AppLocalization.multipleSourcesText(count: selected.count, languageID: interfaceLanguageID)
        }
    }

    private func toggleAllInternalSources() {
        if isAllInternalSourcesSelected {
            selection.subtract(internalSourceIDs)
        } else {
            selection.formUnion(internalSourceIDs)
        }
    }

    private func toggleAllDeviceSources() {
        if isAllDeviceSourcesSelected {
            selection.subtract(deviceSourceIDs)
        } else {
            selection.formUnion(deviceSourceIDs)
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }
}

/// A checkmark column that keeps its width when the row is not selected.
private struct SelectionCheckmark: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: "checkmark")
            .opacity(isSelected ? 1 : 0)
            .accessibilityHidden(!isSelected)
            .frame(width: 12, alignment: .leading)
            .foregroundStyle(Color.accentColor)
    }
}

struct SubtitleModeMenuPicker: View {
    let interfaceLanguageID: String
    let showsDetail: Bool
    @Binding var selection: SubtitleMode

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(SubtitleMode.allCases, id: \.self) { mode in
                if showsDetail {
                    VStack(alignment: .leading) {
                        Text(mode.displayName(in: interfaceLanguageID))
                        Text(mode.detail(in: interfaceLanguageID))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(mode)
                } else {
                    Text(mode.displayName(in: interfaceLanguageID)).tag(mode)
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct SubtitleDisplayModeMenuPicker: View {
    let interfaceLanguageID: String
    @Binding var selection: SubtitleDisplayMode

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(SubtitleDisplayMode.allCases, id: \.self) { mode in
                Text(mode.displayName(in: interfaceLanguageID)).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

extension RecognitionEngine {
    func displayName(in interfaceLanguageID: String) -> String {
        switch self {
        case .onDevice:
            return AppLocalization.string(.engineOnDevice, languageID: interfaceLanguageID)
        case .openAITranslate:
            return AppLocalization.string(.engineOpenAI, languageID: interfaceLanguageID)
        case .sonioxTranslate:
            return AppLocalization.string(.engineSoniox, languageID: interfaceLanguageID)
        }
    }
}

struct RecognitionEngineMenuPicker: View {
    let interfaceLanguageID: String
    @Binding var selection: RecognitionEngine

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(RecognitionEngine.allCases) { engine in
                Text(engine.displayName(in: interfaceLanguageID)).tag(engine)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

/// What the cloud engine costs and how much of it was used today. Shown wherever the
/// engine can be chosen, so the price is visible before subtitles are switched on.
struct CloudEngineCostSummary: View {
    @ObservedObject var model: AppModel
    /// Settings shows what each Display choice costs; the popover only the current one.
    var showsBothRates = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(model.cloudHourlyRateText, systemImage: "dollarsign.circle")
                .monospacedDigit()
            if showsBothRates, model.recognitionEngine == .openAITranslate {
                Label(model.cloudHourlyRatesText, systemImage: "text.bubble")
                    .monospacedDigit()
            }
            Label(model.cloudUsageTodayText, systemImage: "clock")
                .monospacedDigit()
            if model.hasAPIKey(for: model.recognitionEngine) == false {
                Label(
                    model.providerText(model.localized(.cloudFallbackMissingKey)),
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            model.refreshCloudUsage()
        }
    }
}

/// Automatic selection and, when a call app the user has not approved looks like the
/// call, the offer to use it.
struct AutomaticSourceControls: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsControlRow(label: model.localized(.sourceAutomatic)) {
                Toggle("", isOn: $model.selectsSourceAutomatically)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.sessionState == .running)
            }
            if let suggestion = model.suggestedSource, let text = model.suggestedSourceText {
                HStack(spacing: 8) {
                    Label(text, systemImage: "phone.bubble")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(model.localized(.useSourceFormat, suggestion.name)) {
                        model.useSuggestedSource()
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

/// The apps automatic selection may pick, each removable.
struct ApprovedSourcesList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.localized(.approvedApps))
                .font(.callout)
                .foregroundStyle(.secondary)
            if model.approvedSourceIDs.isEmpty {
                Text(model.localized(.approvedAppsEmpty))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(model.approvedSourceIDs, id: \.self) { id in
                HStack {
                    Text(model.approvedSourceName(for: id))
                        .font(.callout)
                    Spacer()
                    Button(model.localized(.removeKey), role: .destructive) {
                        model.removeApprovedSource(id)
                    }
                    .controlSize(.small)
                }
            }
            Text(model.localized(.approvedAppsHint))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// What the spoken language means for the selected engine: a warning when the device
/// cannot work with it, otherwise a quiet note.
struct LanguageNotices: View {
    @ObservedObject var model: AppModel
    var showsServerSpeechNotice = false

    var body: some View {
        if let notice = model.spokenLanguageNotice {
            Label(notice, systemImage: model.spokenLanguageNoticeBlocksStart ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.caption)
                .foregroundStyle(model.spokenLanguageNoticeBlocksStart ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if showsServerSpeechNotice, model.recognitionEngine == .onDevice,
           let notice = model.serverSpeechRecognitionNotice {
            Label(notice, systemImage: "icloud")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shown when the selected cloud engine cannot make subtitles in the chosen language.
struct SubtitleLanguageNotice: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let notice = model.subtitleLanguageNotice {
            Label(notice, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SecondaryRefreshButton: View {
    let title: String
    var systemImage = "arrow.clockwise"
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

struct LanguageResourcesFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SecondaryRefreshButton(
            title: model.localized(.refreshLanguageResources),
            action: model.refreshLanguageResources
        )

        if !model.languageResourceStatuses.isEmpty {
            LanguageResourceStatusListView(statuses: model.languageResourceStatuses)
        }
    }
}

extension AppModel {
    var selectedSourcesBinding: Binding<Set<String>> {
        Binding(
            get: { self.selectedSourceIDs },
            set: { self.chooseSources($0) }
        )
    }

    var recognitionEngineSelectionBinding: Binding<RecognitionEngine> {
        Binding(
            get: { self.recognitionEngine },
            set: {
                // Like the language pair, the engine belongs to the running session.
                guard self.sessionState != .running else { return }
                self.recognitionEngine = $0
            }
        )
    }

    var selectedSourceOptionalBinding: Binding<String?> {
        Binding(
            get: { self.selectedSourceID },
            set: { self.selectedSourceID = $0 }
        )
    }

    /// Languages can change while subtitles run: the session starts again with them.
    var inputLanguageSelectionBinding: Binding<String> {
        Binding(
            get: { self.inputLanguageID },
            set: {
                let languageID = self.supportedSpeechInputLanguageID($0)
                guard languageID != self.inputLanguageID else { return }
                self.inputLanguageID = languageID
                self.applyLanguageChangeToRunningSession()
            }
        )
    }

    var outputLanguageSelectionBinding: Binding<String> {
        Binding(
            get: { self.outputLanguageID },
            set: {
                guard $0 != self.outputLanguageID else { return }
                self.outputLanguageID = $0
                self.applyLanguageChangeToRunningSession()
            }
        )
    }

    var subtitleModeSelectionBinding: Binding<SubtitleMode> {
        Binding(
            get: { self.subtitleMode },
            set: { self.subtitleMode = $0 }
        )
    }

    var subtitleDisplayModeSelectionBinding: Binding<SubtitleDisplayMode> {
        Binding(
            get: { self.subtitleDisplayMode },
            set: { self.subtitleDisplayMode = $0 }
        )
    }

    var interfaceLanguageSelectionBinding: Binding<String> {
        Binding(
            get: { self.interfaceLanguageID },
            set: { self.interfaceLanguageID = $0 }
        )
    }
}
