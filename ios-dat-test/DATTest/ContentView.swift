import SwiftUI

struct ContentView: View {
    @EnvironmentObject var tester: DATTester

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Circle()
                    .fill(tester.connected ? Color.green : Color.secondary)
                    .frame(width: 12, height: 12)
                Text(tester.connected ? "Connected" : "Not connected")
                    .font(.headline)
                Spacer()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(tester.lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .background(Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: tester.lines.count) { _ in
                    withAnimation { proxy.scrollTo(tester.lines.count - 1, anchor: .bottom) }
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await tester.connect() }
                } label: {
                    Text(tester.busy ? "Connecting…" : "Connect")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent)
                .disabled(tester.busy)

                Button { tester.clear() } label: {
                    Text("Clear").frame(minWidth: 70, minHeight: 48)
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Button { Task { await tester.capture() } } label: {
                    Label("Capture photo", systemImage: "camera").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!tester.connected)

                Button(role: .destructive) { tester.disconnect() } label: {
                    Text("Disconnect").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!tester.connected)
            }
        }
        .padding()
    }
}
