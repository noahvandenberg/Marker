import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var preferences: Preferences

    var body: some View {
        Form {
            Section("Typography") {
                Picker("Typeface", selection: $preferences.typeface) {
                    ForEach(TypefaceChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }

                LabeledContent("Text size") {
                    HStack {
                        Slider(value: $preferences.fontSize, in: 11...32, step: 1)
                        Text("\(Int(preferences.fontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }

                LabeledContent("Line height") {
                    HStack {
                        Slider(value: $preferences.lineHeight, in: 1.1...2.2, step: 0.05)
                        Text(String(format: "%.2f", preferences.lineHeight))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }

                LabeledContent("Measure") {
                    HStack {
                        Slider(value: $preferences.contentWidth, in: 420...1100, step: 20)
                        Text("\(Int(preferences.contentWidth)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $preferences.appearance) {
                    ForEach(AppearanceChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Rendering") {
                Toggle("Render LaTeX math and Mermaid diagrams",
                       isOn: $preferences.renderDiagrams)
                Toggle("Load images from the web", isOn: $preferences.loadRemoteImages)
                Toggle("Count tokens", isOn: $preferences.showTokenCount)
                Text("Token counts use OpenAI's o200k_base vocabulary — exact for "
                     + "GPT-4o and GPT-5, and close for other models. The vocabulary "
                     + "is about 3.6 MB and loads the first time a count runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Images on disk always load. Fetching remote images makes a "
                     + "network request that reveals when you open a document, so "
                     + "it stays off unless you want it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Editing") {
                Toggle("Keep the caret centered (typewriter mode)",
                       isOn: $preferences.typewriterMode)
                Toggle("Dim everything but the current paragraph",
                       isOn: $preferences.focusMode)
                Toggle("Wrap the selection when typing * _ ` [ (",
                       isOn: $preferences.autoPairMarkers)
                Toggle("Check spelling while typing", isOn: $preferences.spellChecking)
                Toggle("Smart quotes and dashes", isOn: $preferences.smartSubstitutions)
                Text("Smart substitutions change the characters saved to your file. "
                     + "Leave this off to keep Markdown source plain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                Toggle("Check GitHub for new versions", isOn: $preferences.checkForUpdates)
                Text("Once a day, Marker asks github.com whether a newer release "
                     + "exists. It is the only network request the app makes, and "
                     + "it sends nothing about your documents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") { preferences.resetToDefaults() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
