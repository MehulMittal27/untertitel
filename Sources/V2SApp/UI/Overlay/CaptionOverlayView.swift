import AppKit
import SwiftUI

/// What the single-caption overlay shows at one moment: one large line block and,
/// optionally, one small line block below it. No history.
struct CaptionOverlayContent: Equatable {
    /// The large text: the translation when it is shown.
    var primaryText: String
    /// The small text below: the original speech. Empty when it is not shown.
    var secondaryText: String
    /// A status message such as "Listening…", not something that was said.
    var isStatus: Bool

    /// Picks the current caption: the live draft while someone is speaking, otherwise
    /// the last finished one. Nil when there is nothing to show.
    static func resolve(
        state: OverlayPreviewState,
        showsTranslated: Bool,
        showsOriginal: Bool,
        isStatusText: (String) -> Bool
    ) -> CaptionOverlayContent? {
        let draftSource = displayText(state.draftSourceText ?? "")

        let translated: String
        let source: String
        var isStatus = false

        if draftSource.isEmpty == false {
            source = draftSource
            translated = displayText(
                state.visibleDraftTranslatedText(
                    for: state.draftSourceText ?? "",
                    promotionID: state.draftPromotionID
                ) ?? ""
            )
        } else {
            source = displayText(state.sourceText)
            translated = displayText(state.translatedText)
            isStatus = isStatusText(state.translatedText)
        }

        guard translated.isEmpty == false || source.isEmpty == false else {
            return nil
        }

        if isStatus {
            return CaptionOverlayContent(primaryText: translated, secondaryText: source, isStatus: true)
        }

        // The engine hands the source text over as the translation when there is
        // nothing to translate; showing it twice would only add noise.
        let sourceRepeatsTranslation = source.compare(translated, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame

        switch (showsTranslated, showsOriginal) {
        case (true, true):
            return CaptionOverlayContent(
                primaryText: translated,
                secondaryText: sourceRepeatsTranslation ? "" : source,
                isStatus: false
            )
        case (true, false):
            return CaptionOverlayContent(
                primaryText: translated.isEmpty ? source : translated,
                secondaryText: "",
                isStatus: false
            )
        default:
            return CaptionOverlayContent(primaryText: source, secondaryText: "", isStatus: false)
        }
    }

    /// One line of running text: no line breaks from the engine, no doubled spaces,
    /// and a dash never left alone at the start of a wrapped line.
    static func displayText(_ text: String) -> String {
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed
            .replacingOccurrences(of: " – ", with: "\u{00A0}– ")
            .replacingOccurrences(of: " — ", with: "\u{00A0}— ")
            .replacingOccurrences(of: " - ", with: "\u{00A0}- ")
    }
}

/// Layout rules of the caption block. Pure, so they can be tested without a screen.
enum CaptionOverlayLayout {
    /// The block never takes more than this share of the screen's width.
    static let maximumScreenWidthRatio: CGFloat = 0.70
    static let maximumPrimaryLines = 2
    static let maximumSecondaryLines = 2
    static let horizontalPadding: CGFloat = 22
    static let verticalPadding: CGFloat = 12
    static let lineSpacing: CGFloat = 5
    static let cornerRadius: CGFloat = 14
    /// The block's width moves in steps of this share of its maximum, so it does not
    /// twitch with every word that arrives.
    static let widthStepRatio: CGFloat = 0.25

    static func maximumBlockWidth(availableWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {
        max(0, min(availableWidth, screenWidth * maximumScreenWidthRatio))
    }

    /// Width of the block for text that would be `textWidth` wide on one line.
    static func blockWidth(forTextWidth textWidth: CGFloat, maximumWidth: CGFloat) -> CGFloat {
        guard maximumWidth > 0 else { return 0 }
        let step = maximumWidth * widthStepRatio
        let wanted = textWidth + horizontalPadding * 2
        let stepped = (wanted / step).rounded(.up) * step
        return min(max(stepped, step), maximumWidth)
    }

    static func singleLineWidth(of text: String, fontSize: CGFloat, weight: NSFont.Weight) -> CGFloat {
        guard text.isEmpty == false else { return 0 }
        let font = NSFont.systemFont(ofSize: fontSize, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Opacity of the dark background. Always enough to read over video; the
    /// overlay's opacity setting moves it between solid and lighter.
    static func backgroundOpacity(styleOpacity: Double) -> Double {
        0.55 + 0.40 * min(max(styleOpacity, 0), 1)
    }
}

/// The caption itself: text on a dark rounded background, as wide as its text needs
/// and never wider than `maximumWidth`. Text wraps inside; nothing is clipped.
struct CaptionBlockView: View {
    let content: CaptionOverlayContent
    let style: OverlayStyle
    let maximumWidth: CGFloat

    var body: some View {
        VStack(spacing: CaptionOverlayLayout.lineSpacing) {
            if content.primaryText.isEmpty, content.secondaryText.isEmpty == false {
                // The original has arrived and its translation is a moment behind:
                // keep its line free so the block does not jump when it lands.
                Text(" ")
                    .font(.system(size: primaryFontSize, weight: primaryWeight))
                    .accessibilityHidden(true)
            }

            if content.primaryText.isEmpty == false {
                Text(content.primaryText)
                    .font(.system(size: primaryFontSize, weight: primaryWeight))
                    .foregroundStyle(textColor)
                    .lineLimit(CaptionOverlayLayout.maximumPrimaryLines)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if content.secondaryText.isEmpty == false {
                Text(content.secondaryText)
                    .font(.system(size: secondaryFontSize, weight: .regular))
                    .foregroundStyle(textColor.opacity(0.82))
                    .lineLimit(CaptionOverlayLayout.maximumSecondaryLines)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, CaptionOverlayLayout.horizontalPadding)
        .padding(.vertical, CaptionOverlayLayout.verticalPadding)
        .frame(width: blockWidth)
        .background(
            RoundedRectangle(cornerRadius: CaptionOverlayLayout.cornerRadius, style: .continuous)
                .fill(style.backgroundColor.color.opacity(
                    CaptionOverlayLayout.backgroundOpacity(styleOpacity: style.backgroundOpacity)
                ))
        )
        .accessibilityElement(children: .combine)
    }

    private var primaryFontSize: CGFloat {
        CGFloat(content.isStatus ? style.scaledSourceFontSize : style.scaledTranslatedFontSize)
    }

    private var primaryWeight: Font.Weight {
        content.isStatus ? .medium : .semibold
    }

    private var secondaryFontSize: CGFloat {
        CGFloat(content.isStatus ? style.scaledSourceFontSize * 0.85 : style.scaledSourceFontSize)
    }

    private var textColor: Color {
        style.subtitleColor.color
    }

    private var blockWidth: CGFloat {
        let primaryWidth = CaptionOverlayLayout.singleLineWidth(
            of: content.primaryText,
            fontSize: primaryFontSize,
            weight: content.isStatus ? .medium : .semibold
        )
        let secondaryWidth = CaptionOverlayLayout.singleLineWidth(
            of: content.secondaryText,
            fontSize: secondaryFontSize,
            weight: .regular
        )
        return CaptionOverlayLayout.blockWidth(
            forTextWidth: max(primaryWidth, secondaryWidth),
            maximumWidth: maximumWidth
        )
    }
}

/// Single-caption overlay: only the current caption, centered, like TV subtitles.
/// The catch-up view: the captions before the current one, for reading back after
/// looking away.
enum CaptionCatchUpLayout {
    static let gap: CGFloat = 8
    static let lineSpacing: CGFloat = 6
    static let verticalPadding: CGFloat = 10
    /// History is read, not followed, so it is set smaller than the live caption.
    static let fontScale: CGFloat = 0.72
    static let maximumLinesPerEntry = 2

    /// One line per sentence in the language being read, without the caption that is
    /// already on screen below.
    static func lines(entries: [TranscriptEntry], excluding current: String?, showsTranslated: Bool) -> [String] {
        let currentText = current.map(CaptionOverlayContent.displayText) ?? ""
        return entries.compactMap { entry in
            let translated = CaptionOverlayContent.displayText(entry.translatedText)
            let source = CaptionOverlayContent.displayText(entry.sourceText)
            let text = showsTranslated && translated.isEmpty == false ? translated : source
            guard text.isEmpty == false, text != currentText else { return nil }
            return text
        }
    }

    static func fontSize(style: OverlayStyle) -> CGFloat {
        (CGFloat(style.scaledTranslatedFontSize) * fontScale).rounded()
    }

    /// Room the panel needs on top of the current caption, allowing each entry to wrap.
    static func height(entryCount: Int, style: OverlayStyle) -> CGFloat {
        let rows = CGFloat(max(entryCount, 1) * maximumLinesPerEntry)
        let lineHeight = fontSize(style: style) * 1.25
        return rows * lineHeight
            + CGFloat(max(entryCount - 1, 0)) * lineSpacing
            + verticalPadding * 2
            + gap
    }
}

struct CaptionCatchUpView: View {
    let lines: [String]
    let emptyText: String
    let style: OverlayStyle
    let maximumWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: CaptionCatchUpLayout.lineSpacing) {
            if lines.isEmpty {
                Text(emptyText)
                    .foregroundStyle(.white.opacity(0.7))
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .lineLimit(CaptionCatchUpLayout.maximumLinesPerEntry)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: CaptionCatchUpLayout.fontSize(style: style), weight: .medium))
        .foregroundStyle(.white.opacity(0.88))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CaptionOverlayLayout.horizontalPadding)
        .padding(.vertical, CaptionCatchUpLayout.verticalPadding)
        .frame(width: maximumWidth)
        .background(
            Color.black.opacity(CaptionOverlayLayout.backgroundOpacity(styleOpacity: style.backgroundOpacity)),
            in: RoundedRectangle(cornerRadius: CaptionOverlayLayout.cornerRadius, style: .continuous)
        )
    }
}

struct CaptionOverlayView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var interactionState: OverlayInteractionState

    var body: some View {
        GeometryReader { proxy in
            let content = currentContent
            let maximumWidth = CaptionOverlayLayout.maximumBlockWidth(
                availableWidth: proxy.size.width,
                screenWidth: interactionState.screenWidth
            )
            VStack(spacing: CaptionCatchUpLayout.gap) {
                if model.isCatchUpVisible {
                    CaptionCatchUpView(
                        lines: CaptionCatchUpLayout.lines(
                            entries: model.catchUpEntries,
                            excluding: content?.primaryText,
                            showsTranslated: model.showsTranslatedSubtitle
                        ),
                        emptyText: model.localized(.catchUpEmpty),
                        style: model.overlayStyle,
                        maximumWidth: maximumWidth
                    )
                    .transition(.opacity)
                }
                if let content {
                    CaptionBlockView(
                        content: content,
                        style: model.overlayStyle,
                        maximumWidth: maximumWidth
                    )
                    // Words replace words in place. Only the whole block fades, and
                    // only when it appears or goes away.
                    .transaction { $0.animation = nil }
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(.easeOut(duration: 0.18), value: content == nil)
            .animation(.easeOut(duration: 0.18), value: model.isCatchUpVisible)
        }
        .padding(OverlayControlsLayout.outerPadding)
        .onAppear {
            model.updateOverlayHistoryVisibleCount(0)
        }
    }

    private var currentContent: CaptionOverlayContent? {
        guard let state = model.overlayState else {
            return nil
        }

        return CaptionOverlayContent.resolve(
            state: state,
            showsTranslated: model.showsTranslatedSubtitle,
            showsOriginal: model.showsOriginalSubtitle,
            isStatusText: model.isOverlayStatusText
        )
    }
}
