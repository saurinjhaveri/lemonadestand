import SwiftUI

/// Lightweight design system: colors, gradients, card styling, and a few
/// reusable components so the whole app looks consistent.
enum Theme {
    // Primary brand (indigo→blue) and a warm "pop" for the main call-to-action.
    static let accent = Color(red: 0.30, green: 0.46, blue: 0.95)
    static let indigo = Color(red: 0.36, green: 0.30, blue: 0.86)
    static let pop = Color(red: 0.98, green: 0.52, blue: 0.22)

    static let heroGradient = LinearGradient(
        colors: [indigo, accent],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let popGradient = LinearGradient(
        colors: [Color(red: 0.98, green: 0.44, blue: 0.24),
                 Color(red: 0.99, green: 0.62, blue: 0.23)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let corner: CGFloat = 18
}

extension View {
    /// Standard card surface (adapts to light/dark).
    func card(_ padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

/// Full-width gradient capsule button (primary actions).
struct BigButtonStyle: ButtonStyle {
    var gradient: LinearGradient = Theme.heroGradient
    var minHeight: CGFloat = 56
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(gradient, in: Capsule())
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Bordered "chip" button (secondary actions).
struct ChipButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 50)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A small colored status pill (Glasses / Voice / Location).
struct StatusPill: View {
    let icon: String
    let label: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption2)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(detail).font(.system(size: 12, weight: .semibold))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(color.opacity(0.14), in: Capsule())
        .foregroundStyle(color)
    }
}

extension ConnectionState {
    var pillColor: Color {
        switch self {
        case .connected: return .green
        case .connecting: return .orange
        case .failed: return .red
        case .disconnected: return .secondary
        }
    }
    var short: String {
        switch self {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .failed: return "Failed"
        case .disconnected: return "Off"
        }
    }
}
