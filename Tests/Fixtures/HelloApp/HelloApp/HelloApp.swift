import SwiftUI

// A tiny app minirun's CI builds, launches and taps to prove the whole loop works.
@main
struct HelloApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var count = 0
    @State private var name = ""

    var body: some View {
        VStack(spacing: 24) {
            Text("Taps: \(count)")
                .font(.largeTitle)
                .accessibilityIdentifier("countLabel")
            Button("Tap me") { count += 1 }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tapButton")
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("nameField")
                .padding(.horizontal, 40)
            Text(name.isEmpty ? "Hello!" : "Hello, \(name)!")
                .accessibilityIdentifier("greeting")
        }
    }
}
