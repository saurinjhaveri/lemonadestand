import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                statusCard

                if isConnected {
                    pushToTalkButton
                    HStack(spacing: 12) {
                        lookAtThisButton
                        stopButton
                    }
                    if model.isThinking {
                        HStack(spacing: 8) { ProgressView(); Text("Thinking…") }
                            .foregroundStyle(.secondary)
                    }
                    transcriptView
                } else {
                    settingsCard
                    Button("Connect glasses & voice") {
                        Task { await model.startSession() }
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Tour Guide")
            .toolbar {
                if isConnected {
                    Button("End") { model.endSession() }
                }
            }
        }
    }

    private var isConnected: Bool {
        model.glassesState == .connected
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mode", selection: $model.voiceMode) {
                ForEach(VoiceMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Brain", selection: $model.backendChoice) {
                ForEach(BackendChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Picker("Voice", selection: $model.ttsEngine) {
                ForEach(TTSEngine.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            if model.ttsEngine == .natural {
                Picker("Natural voice", selection: $model.naturalVoice) {
                    ForEach(AppModel.naturalVoices, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .pickerStyle(.menu)
            }

            Text(blurb)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var blurb: String {
        let brain = model.backendChoice == .gemini ? "Gemini (free tier)" : "ChatGPT"
        let voice = model.ttsEngine == .natural
            ? "Natural voice (OpenAI, small cost)."
            : "Device voice — for a less robotic sound, install an Enhanced/Premium voice in Settings → Accessibility → Spoken Content → Voices."
        switch model.voiceMode {
        case .lite:
            return "Lite: on-device speech-to-text + \(brain). Cheap/free, turn-based. \(voice)"
        case .realtime:
            return "Realtime: OpenAI speech-to-speech (premium). \(brain) powers ‘Look at this’. (Voice setting applies to Lite/Look-at-this.)"
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusRow("Glasses", model.glassesState)
            statusRow("Voice", model.voiceState)
            HStack {
                Text("Location").bold()
                Spacer()
                Text(model.location.location.map {
                    String(format: "%.4f, %.4f", $0.coordinate.latitude, $0.coordinate.longitude)
                } ?? "—")
                .foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Text("Last turn").bold()
                Spacer()
                Text(model.lastTurn).foregroundStyle(.secondary)
            }
            HStack {
                Text("Cost (session)").bold()
                Spacer()
                Text(String(format: "~$%.4f", model.sessionTotalUSD)).foregroundStyle(.secondary)
            }
            HStack {
                Text("Cost (lifetime)").bold()
                Spacer()
                Text(String(format: "~$%.3f", model.lifetimeCostUSD)).foregroundStyle(.secondary)
            }
            if model.canShowBilling {
                HStack {
                    Button("Billed spend") { Task { await model.refreshBilling() } }
                        .font(.caption)
                    Spacer()
                    Text(model.billedMonthText).foregroundStyle(.secondary)
                }
            }
            Text("Estimates. True remaining balance isn't in OpenAI's API — see openai.com.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusRow(_ label: String, _ state: ConnectionState) -> some View {
        HStack {
            Text(label).bold()
            Spacer()
            Text(describe(state)).foregroundStyle(color(for: state))
        }
    }

    private var pushToTalkButton: some View {
        Text(model.isListening ? "Listening… release to ask" : "Hold to talk")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(model.isListening ? Color.red : Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !model.isListening { model.beginTalking() } }
                    .onEnded { _ in model.endTalking() }
            )
    }

    private var lookAtThisButton: some View {
        Button {
            Task { await model.lookAtThis() }
        } label: {
            Label("Look at this", systemImage: "camera.viewfinder")
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
    }

    private var stopButton: some View {
        Button(role: .destructive) {
            model.stopSpeaking()
        } label: {
            Label("Stop", systemImage: "stop.fill")
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    private var transcriptView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !model.transcript.isEmpty {
                    Text("You / Guide").font(.caption).foregroundStyle(.secondary)
                    Text(model.transcript)
                }
                if !model.lastNarration.isEmpty {
                    Text("Last capture").font(.caption).foregroundStyle(.secondary)
                    Text(model.lastNarration)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func describe(_ state: ConnectionState) -> String {
        switch state {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    private func color(for state: ConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }
}
