import SwiftUI
import UIKit

/// The active touring screen: status, the guide's latest answer, and the
/// capture / talk / stop controls.
struct SessionView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var showPicker = false
    @State private var pickerSource: UIImagePickerController.SourceType = .photoLibrary

    var body: some View {
        VStack(spacing: 14) {
            statusBar
            if model.voiceState.isFailure {
                micErrorBanner
            }
            if model.glassesState.isFailure {
                glassesErrorBanner
            }
            conversation
            controls
        }
        .padding()
        .background(Color(.systemGroupedBackground))
        .confirmationDialog("Add a photo to identify",
                            isPresented: $model.isPickingImage, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { pickerSource = .camera; showPicker = true }
            }
            Button("Choose from Library") { pickerSource = .photoLibrary; showPicker = true }
            Button("Cancel", role: .cancel) { }
        }
        .sheet(isPresented: $showPicker) {
            ImagePicker(sourceType: pickerSource) { data in
                showPicker = false
                model.usePickedImage(data)
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Status

    private var statusBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                StatusPill(icon: "eyeglasses", label: "GLASSES",
                           detail: model.glassesState == .connected ? "Live" : model.glassesState.short,
                           color: model.glassesState.pillColor)
                StatusPill(icon: "photo.on.rectangle.angled", label: "PHOTOS",
                           detail: model.autoNarratePhotos ? "Watching" : "Off",
                           color: model.autoNarratePhotos ? .green : .secondary)
                StatusPill(icon: "waveform", label: "VOICE",
                           detail: model.voiceState.short, color: model.voiceState.pillColor)
                StatusPill(icon: "location.fill", label: "GPS",
                           detail: model.location.location == nil ? "—" : "On",
                           color: model.location.location == nil ? .secondary : .green)
                Spacer()
            }
            if !model.photoWatchStatus.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "photo.on.rectangle.angled").font(.caption2)
                    Text(model.photoWatchStatus).font(.caption2)
                    Spacer()
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var glassesErrorBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text((model.glassesState.failureMessage ?? "Live glasses connection failed.")
                     + " Photos still work via the Camera Roll bridge.")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { Task { await model.retryGlasses() } } label: {
                Label("Retry live connection", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ChipButtonStyle())
        }
        .card(12)
    }

    private var micErrorBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text((model.voiceState.failureMessage ?? "Microphone unavailable.")
                 + " Enable Microphone & Speech Recognition in Settings.")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(12)
    }

    // MARK: - Conversation

    private var conversation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !model.transcript.isEmpty {
                    bubble(text: model.transcript, role: "You", icon: "person.fill",
                           tint: Theme.accent, trailing: true)
                }
                if model.isThinking {
                    thinkingRow
                }
                if !model.lastNarration.isEmpty {
                    bubble(text: model.lastNarration, role: "Your guide", icon: "binoculars.fill",
                           tint: Theme.indigo, trailing: false)
                } else if !model.isThinking && model.transcript.isEmpty {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func bubble(text: String, role: String, icon: String, tint: Color, trailing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.caption2)
                Text(role).font(.caption.weight(.semibold))
            }
            .foregroundStyle(tint)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var thinkingRow: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Thinking…").foregroundStyle(.secondary)
            Spacer()
        }
        .card(12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "viewfinder")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
            Text("Point at something and tap **Look at this**, or hold **Talk** to ask about where you are.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            if model.readModeActive {
                readingChips
            } else if !model.lastNarration.isEmpty && !model.isThinking {
                followUps
            }
            askField
            talkButton
            HStack(spacing: 10) {
                Button { Task { await model.lookAtThis() } } label: {
                    Label("Look at this", systemImage: "camera.viewfinder")
                }
                .buttonStyle(ChipButtonStyle())

                Button { Task { await model.startReading() } } label: {
                    Label("Read", systemImage: "book")
                }
                .buttonStyle(ChipButtonStyle())

                Button(role: .destructive) { model.stopSpeaking() } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(ChipButtonStyle(tint: .red))
            }
        }
    }

    /// Read-mode page flow: also voice-driven ("next page" / "stop reading").
    private var readingChips: some View {
        HStack(spacing: 8) {
            followChip("Next page", "arrow.right.circle") { Task { await model.captureAndReadPage() } }
            followChip("Done reading", "checkmark") { model.stopReading() }
        }
    }

    /// Tap-instead-of-speak follow-ups, shown once there's an answer.
    private var followUps: some View {
        HStack(spacing: 8) {
            followChip("Tell me more", "text.bubble") { model.tellMore() }
            followChip("Where next?", "figure.walk") { model.whereNext() }
            followChip("That's it", "checkmark") { model.thatsIt() }
        }
    }

    private func followChip(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 38)
        }
        .buttonStyle(ChipButtonStyle())
    }

    private var talkButton: some View {
        Label(model.isListening ? "Listening… release to ask" : "Hold to talk",
              systemImage: model.isListening ? "mic.fill" : "mic")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(model.isListening ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.heroGradient),
                        in: Capsule())
            .foregroundStyle(.white)
            .scaleEffect(model.isListening ? 1.02 : 1)
            .animation(.easeOut(duration: 0.15), value: model.isListening)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !model.isListening { model.beginTalking() } }
                    .onEnded { _ in model.endTalking() }
            )
    }

    private var askField: some View {
        HStack(spacing: 8) {
            TextField("Type where you are / what you see", text: $query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(Color(.secondarySystemBackground), in: Capsule())
                .onSubmit(submitQuery)
            Button(action: submitQuery) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(query.trimmingCharacters(in: .whitespaces).isEmpty ? .gray : Theme.accent)
            }
            .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submitQuery() {
        let q = query
        query = ""
        model.ask(q)
    }
}
