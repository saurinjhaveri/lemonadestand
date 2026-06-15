import SwiftUI

/// All configuration in one tidy sheet, grouped by topic.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Conversation") {
                    Picker("Mode", selection: $model.voiceMode) {
                        ForEach(VoiceMode.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Brain", selection: $model.backendChoice) {
                        ForEach(BackendChoice.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Answer length", selection: $model.guideLength) {
                        ForEach(GuideLength.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section("Voice") {
                    Picker("Engine", selection: $model.ttsEngine) {
                        ForEach(TTSEngine.allCases) { Text($0.label).tag($0) }
                    }
                    if model.ttsEngine == .device {
                        Picker("Device voice", selection: $model.deviceVoiceID) {
                            ForEach(DeviceSpeaker.availableVoices(), id: \.identifier) { v in
                                Text("\(v.name) (\(v.qualityLabel))").tag(v.identifier)
                            }
                        }
                    } else {
                        Picker("Natural voice", selection: $model.naturalVoice) {
                            ForEach(AppModel.naturalVoices, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                    }
                }

                Section("Photos") {
                    Toggle("Auto-narrate new photos", isOn: $model.autoNarratePhotos)
                    Text("Glasses photos sync to your Camera Roll via the Meta AI app; the guide narrates each new one automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Custom instructions") {
                    TextField("e.g. be brief, focus on food & stories, skip dates",
                              text: $model.customInstructions, axis: .vertical)
                        .lineLimit(2...5)
                }

                Section("Spend") {
                    LabeledContent("This session", value: String(format: "~$%.4f", model.sessionTotalUSD))
                    LabeledContent("Lifetime", value: String(format: "~$%.3f", model.lifetimeCostUSD))
                    if model.canShowBilling {
                        Button("Refresh billed spend") { Task { await model.refreshBilling() } }
                        if !model.billedMonthText.isEmpty {
                            LabeledContent("Billed", value: model.billedMonthText)
                        }
                    }
                    Text("Estimates. True balance isn't exposed by the OpenAI API — see openai.com.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
