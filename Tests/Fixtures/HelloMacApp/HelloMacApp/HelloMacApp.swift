import CoreGraphics
import SwiftUI

// A tiny macOS app minirun's CI builds, launches and drives to prove the Mac loop works.
@main
struct HelloMacApp: App {
    @StateObject private var model = CounterModel()

    init() {
        // Line-buffer stdout so each print reaches the captured log file right away.
        setvbuf(stdout, nil, _IOLBF, 0)
        print("HelloMacApp: launched")
        // minirun launches apps responsible for themselves, so this is the app's own Screen
        // Recording grant, not minirun's (the smoke test expects false).
        print("HelloMacApp: screen-capture-access=\(CGPreflightScreenCaptureAccess())")
    }

    var body: some Scene {
        WindowGroup("HelloMacApp") {
            ContentView(model: model)
        }
        .commands {
            CommandMenu("Counter") {
                Button("Reset Counter") { model.reset() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

@MainActor
final class CounterModel: ObservableObject {
    @Published var count = 0
    @Published var name = "" {
        didSet { print("HelloMacApp: name=\(name)") }
    }

    func increment() {
        count += 1
        print("HelloMacApp: count=\(count)")
    }

    func reset() {
        count = 0
        print("HelloMacApp: reset count=0")
    }
}

struct ContentView: View {
    @ObservedObject var model: CounterModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Count: \(model.count)")
                .font(.title)
                .accessibilityIdentifier("countLabel")
            Button("Increment") { model.increment() }
                .accessibilityIdentifier("incrementButton")
            TextField("Name", text: $model.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .accessibilityIdentifier("nameField")
            Text("Hello, \(model.name)")
                .accessibilityIdentifier("greetingLabel")
        }
        .padding(32)
        .frame(minWidth: 360, minHeight: 240)
    }
}
