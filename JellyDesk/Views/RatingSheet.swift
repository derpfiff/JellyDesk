import SwiftUI

/// Sprache des Sheets: Systemsprache, Deutsch als Vorgabe, sonst Englisch.
/// Der Rest der App ist auf Deutsch; nur das Bewertungs-Sheet folgt der Systemsprache.
enum RatingL10n {
    static var isGerman: Bool {
        let first = Bundle.main.preferredLocalizations.first
            ?? Locale.current.language.languageCode?.identifier
            ?? "en"
        return first.lowercased().hasPrefix("de")
    }

    static func t(_ de: String, _ en: String) -> String { isGerman ? de : en }
}

/// Bewertung eines gerade gesehenen Films – an den Letterboxd-Dialog „I watched …“ angelehnt,
/// im Glas-Stil der restlichen App. Erscheint als Sheet über dem Player.
struct RatingSheet: View {
    let context: RatingContext
    let letterboxdAvailable: Bool
    let onSave: (RatingDraft) -> Void
    let onLater: () -> Void
    let onDisableForever: () -> Void
    let onDismiss: () -> Void

    @State private var draft = RatingDraft()
    @State private var includeDate: Bool = true

    private var l: (String, String) -> String { RatingL10n.t }

    /// Datum nicht in der Zukunft, nicht weiter zurück als zehn Jahre.
    private var dateRange: ClosedRange<Date> {
        let now = Date()
        let tenYearsAgo = Calendar.current.date(byAdding: .year, value: -10, to: now) ?? now
        return tenYearsAgo...now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            StarsRow(stars: $draft.stars)

            HStack(spacing: 14) {
                HeartButton(liked: $draft.liked)
                Text(l("Herz", "Like"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text2)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $includeDate) {
                    Text(l("Gesehen am", "Watched on"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                .toggleStyle(.checkbox)
                if includeDate {
                    DatePicker("",
                               selection: Binding(
                                get: { draft.watchedDate ?? Date() },
                                set: { draft.watchedDate = min($0, Date()) }
                               ),
                               in: dateRange,
                               displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.compact)
                }
            }

            Toggle(isOn: $draft.rewatch) {
                Text(l("Schon mal gesehen", "I’ve watched this film before"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 6) {
                Text(l("Kommentar", "Comment"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                CommentEditor(text: $draft.comment)
                    .frame(minHeight: 96, maxHeight: 180)
                HStack {
                    Toggle(isOn: $draft.containsSpoilers) {
                        Text(l("Enthält Spoiler", "Contains spoilers"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.text2)
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Text("\(draft.comment.count) / 10 000")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text3)
                        .monospacedDigit()
                }
            }

            if !letterboxdAvailable || context.tmdbId == nil {
                Text(hintText)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(l("Nicht mehr fragen", "Don’t ask again")) { onDisableForever() }
                    .buttonStyle(GlassPillButtonStyle())
                Spacer()
                Button(l("Später", "Later")) { onLater() }
                    .buttonStyle(GlassPillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(l("Speichern", "Save")) {
                    commit()
                    onSave(draft)
                }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(28)
        .frame(width: 520)
        .background(Theme.surface)
        .onChange(of: draft.comment) { _, value in
            if value.count > 10_000 { draft.comment = String(value.prefix(10_000)) }
        }
        .onDisappear { onDismiss() }
    }

    private func commit() {
        if !includeDate { draft.watchedDate = nil }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(l("Ich habe gesehen …", "I watched …").uppercased())
                .font(.system(size: 11, weight: .bold))
                .kerning(0.8)
                .foregroundStyle(Theme.text3)
            Text(context.title)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
            if let year = context.year {
                Text(String(year))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text2)
            }
        }
    }

    private var hintText: String {
        if context.tmdbId == nil {
            return l(
                "Ohne TMDb-Kennung dieses Titels geht nur die Bewertung an Jellyfin.",
                "Without a TMDb id, only the Jellyfin rating is sent."
            )
        }
        return l(
            "Letterboxd ist auf dem Server nicht eingerichtet – es wird nur die Bewertung an Jellyfin gesendet.",
            "Letterboxd isn’t configured on the server – only the Jellyfin rating is sent."
        )
    }
}

/// Reihe aus fünf Sternen, jeder mit zwei halben Flächen. Tippen einer schon gesetzten
/// Hälfte nimmt die Bewertung zurück.
private struct StarsRow: View {
    @Binding var stars: Double?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { index in
                star(index: Double(index))
            }
            if let stars {
                Text(String(format: "%.1f", stars).replacingOccurrences(of: ".", with: RatingL10n.isGerman ? "," : "."))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text2)
                    .padding(.leading, 6)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func star(index: Double) -> some View {
        let half = index - 0.5
        let fullValue = index
        let current = stars ?? 0
        let filledFull = current >= fullValue
        let filledHalf = current >= half

        ZStack(alignment: .leading) {
            Image(systemName: "star")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Theme.text3)
            Image(systemName: "star.fill")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(Color.yellow)
                .mask(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle().frame(width: filledHalf ? 14 : 0)
                        Rectangle().frame(width: filledFull ? 14 : 0)
                    }
                }
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: 14, height: 30)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        stars = (stars == half) ? nil : half
                    }
                Color.clear
                    .frame(width: 14, height: 30)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        stars = (stars == fullValue) ? nil : fullValue
                    }
            }
        }
        .frame(width: 28, height: 30)
        .accessibilityElement()
        .accessibilityLabel("\(Int(fullValue)) \(RatingL10n.t("Sterne", "stars"))")
        .accessibilityAddTraits(filledFull ? .isSelected : [])
    }
}

/// Herz rechts neben den Sternen.
private struct HeartButton: View {
    @Binding var liked: Bool
    var body: some View {
        Button {
            liked.toggle()
        } label: {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(liked ? Theme.red : Theme.text3)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(RatingL10n.t("Herz", "Like"))
        .accessibilityAddTraits(liked ? .isSelected : [])
    }
}

/// Mehrzeiliges Textfeld mit dezentem Hintergrund.
private struct CommentEditor: View {
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, lineWidth: 1))
            if text.isEmpty {
                Text(RatingL10n.t("Was hast du gedacht?", "What did you think?"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text3)
                    .padding(10)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .scrollContentBackground(.hidden)
                .padding(6)
        }
    }
}
