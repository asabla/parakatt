import SwiftUI
import ParakattCore

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }

            DictionarySettingsView()
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
        }
        .frame(width: 520, height: 480)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            Section("Hotkey") {
                Text("Option (⌥) + Space — hold to record, release to transcribe")
                    .foregroundStyle(.secondary)
            }

            Section("Active Mode") {
                Picker("Mode", selection: $appState.activeMode) {
                    Text("Dictation — raw transcription").tag("dictation")
                    Text("Clean — fix grammar").tag("clean")
                    Text("Email — format as email").tag("email")
                    Text("Code — code-aware").tag("code")
                }
                .pickerStyle(.radioGroup)
            }
        }
        .padding()
    }
}

// MARK: - Dictionary

struct DictionarySettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var domainWords: [String] = []
    @State private var replacements: [Replacement] = []
    @State private var newDomainWord = ""
    @State private var newPattern = ""
    @State private var newReplacement = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: Domain words
                VStack(alignment: .leading, spacing: 8) {
                    Text("Domain Words")
                        .font(.headline)
                    Text("Words the transcriber should know about. Helps distinguish similar-sounding words (e.g. \"eval\" not \"evil\", \"kubectl\" not \"cube control\").")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(domainWords, id: \.self) { word in
                            HStack(spacing: 4) {
                                Text(word)
                                    .font(.body.monospaced())
                                Button {
                                    domainWords.removeAll { $0 == word }
                                    save()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    HStack {
                        TextField("Add word (e.g. eval, kubectl, Parakatt)", text: $newDomainWord)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addDomainWord() }
                        Button("Add") { addDomainWord() }
                            .disabled(newDomainWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }

                Divider()

                // MARK: Replacements
                VStack(alignment: .leading, spacing: 8) {
                    Text("Replacements")
                        .font(.headline)
                    Text("Always replace one word/phrase with another after transcription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !replacements.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(replacements) { r in
                                HStack {
                                    Text(r.pattern)
                                        .font(.body.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.right")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                    Text(r.replacement)
                                        .font(.body.monospaced())
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button {
                                        replacements.removeAll { $0.id == r.id }
                                        save()
                                    } label: {
                                        Image(systemName: "trash")
                                            .foregroundStyle(.red)
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Pattern", text: $newPattern)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                        TextField("Replacement", text: $newReplacement)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") { addReplacement() }
                            .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty ||
                                      newReplacement.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .padding()
        }
        .onAppear { load() }
    }

    // MARK: - Actions

    private func addDomainWord() {
        let word = newDomainWord.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !domainWords.contains(word) else { return }
        domainWords.append(word)
        newDomainWord = ""
        save()
    }

    private func addReplacement() {
        let p = newPattern.trimmingCharacters(in: .whitespaces)
        let r = newReplacement.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !r.isEmpty else { return }
        replacements.append(Replacement(pattern: p, replacement: r))
        newPattern = ""
        newReplacement = ""
        save()
    }

    // MARK: - Persistence (via Rust engine)

    private func load() {
        let rules = appState.getDictionaryRules()
        domainWords = []
        replacements = []
        for rule in rules {
            if rule.pattern == rule.replacement {
                // Domain word: pattern == replacement means "keep this word as-is"
                domainWords.append(rule.pattern)
            } else {
                replacements.append(Replacement(pattern: rule.pattern, replacement: rule.replacement))
            }
        }
    }

    private func save() {
        var rules: [ParakattCore.ReplacementRule] = []

        // Domain words stored as identity replacements (pattern == replacement)
        for word in domainWords {
            rules.append(ParakattCore.ReplacementRule(
                pattern: word,
                replacement: word,
                contextType: "always",
                contextValue: nil,
                enabled: true
            ))
        }

        // Explicit replacements
        for r in replacements {
            rules.append(ParakattCore.ReplacementRule(
                pattern: r.pattern,
                replacement: r.replacement,
                contextType: "always",
                contextValue: nil,
                enabled: true
            ))
        }

        appState.setDictionaryRules(rules)
    }
}

struct Replacement: Identifiable {
    let id = UUID()
    let pattern: String
    let replacement: String
}

// MARK: - Flow Layout (tag cloud)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            maxX = max(maxX, x)
        }

        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
