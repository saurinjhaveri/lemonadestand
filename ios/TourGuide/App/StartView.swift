import SwiftUI

/// Pre-session landing screen: hero, a quick summary of the current setup, and
/// the big "Start touring" action. Detailed settings live in the gear sheet.
struct StartView: View {
    @EnvironmentObject var model: AppModel
    @Binding var showSettings: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                setupSummary
                startButton
                if model.glassesState.isFailure {
                    failureNote
                }
                footnote
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "binoculars.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 96, height: 96)
                .background(Theme.heroGradient, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                .shadow(color: Theme.accent.opacity(0.4), radius: 16, y: 8)
            Text("Tour Guide")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("Your hands-free local guide. Point, ask, and hear the story behind what you're looking at.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
        .padding(.horizontal)
    }

    private var setupSummary: some View {
        VStack(spacing: 0) {
            summaryRow(icon: "waveform", title: "Mode", value: model.voiceMode.label)
            Divider().padding(.leading, 44)
            summaryRow(icon: "brain.head.profile", title: "Brain", value: model.backendChoice.label)
            Divider().padding(.leading, 44)
            summaryRow(icon: "speaker.wave.2.fill", title: "Voice",
                       value: model.ttsEngine == .natural ? "Natural" : "Device")
            Divider().padding(.leading, 44)
            Button { showSettings = true } label: {
                HStack {
                    Image(systemName: "slider.horizontal.3").frame(width: 28)
                    Text("Customize").fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .foregroundStyle(Theme.accent)
                .padding(.vertical, 12)
            }
        }
        .padding(.horizontal, 16)
        .background(Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }

    private func summaryRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 0) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 28)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    private var startButton: some View {
        Button {
            Task { await model.startSession() }
        } label: {
            Label("Start touring", systemImage: "play.fill")
        }
        .buttonStyle(BigButtonStyle())
        .padding(.top, 4)
    }

    private var failureNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(model.glassesState.failureMessage ?? "Glasses unavailable.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .card(12)
    }

    private var footnote: some View {
        Text(String(format: "Lifetime estimated spend: ~$%.3f", model.lifetimeCostUSD))
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

extension ConnectionState {
    var isFailure: Bool { if case .failed = self { return true }; return false }
    var failureMessage: String? { if case .failed(let m) = self { return m }; return nil }
}
