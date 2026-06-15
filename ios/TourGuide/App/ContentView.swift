import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if model.sessionActive {
                    SessionView()
                } else {
                    StartView(showSettings: $showSettings)
                }
            }
            .navigationTitle(model.sessionActive ? "Touring" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.sessionActive {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) { model.endSession() } label: {
                            Text("End")
                        }
                    }
                } else {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(model)
            }
        }
    }
}
