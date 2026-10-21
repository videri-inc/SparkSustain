import AppIntents
import SwiftUI
import WidgetKit

// Control Center control for SparkSustain. The control itself stays tiny:
// it reads/writes small JSON files in the shared app-group container, and
// the menu bar app (which owns credentials and the API client) watches for
// requests and sends the actual device commands.

// Shared app-group container — the sandboxed extension and the app both
// resolve to ~/Library/Group Containers/group.com.videri.sparksustain
let sparkStateDir = FileManager.default
    .containerURL(forSecurityApplicationGroupIdentifier: "group.com.videri.sparksustain")
    ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.videri.sparksustain")

func sparkStateIsOn() -> Bool {
    let url = sparkStateDir.appendingPathComponent("control-state.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let on = json["on"] as? Bool else { return true }
    return on
}

struct ToggleSparksIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn Sparks On or Off"

    @Parameter(title: "Sparks On")
    var value: Bool

    func perform() async throws -> some IntentResult {
        try? FileManager.default.createDirectory(at: sparkStateDir, withIntermediateDirectories: true)
        let request: [String: Any] = ["on": value, "requested_at": Date().timeIntervalSince1970]
        try JSONSerialization.data(withJSONObject: request)
            .write(to: sparkStateDir.appendingPathComponent("control-request.json"))
        // Optimistic state so the control flips immediately; the app corrects
        // it if the command fails.
        try? JSONSerialization.data(withJSONObject: ["on": value])
            .write(to: sparkStateDir.appendingPathComponent("control-state.json"))
        return .result()
    }
}

struct SparkSustainControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.videri.sparksustain.toggle",
                                   provider: Provider()) { isOn in
            ControlWidgetToggle("Spark Screens", isOn: isOn, action: ToggleSparksIntent()) { on in
                Label(on ? "Sparks On" : "Sparks Off",
                      systemImage: on ? "sun.max.fill" : "moon.fill")
            }
            .tint(.orange)
        }
        .displayName("Spark Screens")
        .description("Turn your office Sparks on or off.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { true }
        func currentValue() async throws -> Bool { sparkStateIsOn() }
    }
}

@main
struct SparkSustainControlBundle: WidgetBundle {
    var body: some Widget {
        SparkSustainControl()
    }
}
