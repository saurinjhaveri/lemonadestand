import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                statusCard

                if isConnected {
                    pushToTalkButton
                    lookAtThisButton
                    transcriptView
                } else {
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
