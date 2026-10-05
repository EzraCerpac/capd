import argparse
from pathlib import Path
import subprocess
import tempfile


HARNESS = r'''
import Foundation

struct CaptureReference: Equatable { let captureID: UUID }
enum CaptureAction: Equatable {
    case find(String), open(CaptureReference), stageText(String)
}
enum SystemIntegrationError: Error, LocalizedError {
    case missingCapture
    var errorDescription: String? { "Missing synthetic capture" }
}
final class Bridge {
    var pendingAction: CaptureAction?
    var consumptionCount = 0
    func consumeAction() -> CaptureAction? {
        guard let action = pendingAction else { return nil }
        pendingAction = nil
        consumptionCount += 1
        return action
    }
}
final class Model {
    var query = ""
    var error: String?
    var reloadCount = 0
    var captureIDs: Set<UUID> = []
    func reload() { reloadCount += 1 }
    func capture(id: UUID) -> UUID? { captureIDs.contains(id) ? id : nil }
}
struct Draft: Equatable {
    var id: UUID
    var source: String
    var title: String
    var note: String
}
struct Routing {
    let systemBridge = Bridge()
    let model = Model()
    var capturing = false
    var showingSyncSettings = false
    var asking = false
    var navigationPath: [UUID] = []
    var stagedText = ""
    var draftID = UUID()
    __ACTUAL_ROUTING_METHOD__
}

var failures = 0
var checks = 0
@MainActor
func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL: " + message) }
}

for dismissal in ["save", "cancel"] {
    var routing = Routing()
    routing.capturing = true
    routing.stagedText = "Original initial source"
    let edited = Draft(
        id: routing.draftID, source: "User edited source", title: "User title", note: "User note")
    var composer = edited
    let incoming = CaptureAction.stageText("Incoming synthetic draft")
    routing.systemBridge.pendingAction = incoming
    routing.consumeSystemAction()
    if routing.draftID != composer.id {
        composer = Draft(id: routing.draftID, source: routing.stagedText, title: "", note: "")
    }
    expect(composer == edited, dismissal + ": source/title/note and composer identity retained")
    expect(routing.stagedText == "Original initial source", dismissal + ": initial source retained")
    expect(routing.systemBridge.pendingAction == incoming, dismissal + ": incoming action pending")
    expect(routing.systemBridge.consumptionCount == 0, dismissal + ": no action consumed while editing")
    routing.capturing = false
    routing.consumeSystemAction()
    expect(routing.capturing, dismissal + ": deferred draft presented after dismissal")
    expect(routing.stagedText == "Incoming synthetic draft", dismissal + ": deferred text staged")
    expect(routing.draftID != edited.id, dismissal + ": new draft identity after dismissal")
    expect(routing.systemBridge.pendingAction == nil, dismissal + ": pending action consumed")
    expect(routing.systemBridge.consumptionCount == 1, dismissal + ": action consumed exactly once")
    routing.consumeSystemAction()
    expect(routing.systemBridge.consumptionCount == 1, dismissal + ": no duplicate replay")
}

let captureID = UUID()
for sheet in ["capture", "ask", "sync"] {
    for action in [CaptureAction.find("Hiking"), .open(CaptureReference(captureID: captureID))] {
        var routing = Routing()
        routing.capturing = sheet == "capture"
        routing.asking = sheet == "ask"
        routing.showingSyncSettings = sheet == "sync"
        routing.model.captureIDs = [captureID]
        routing.systemBridge.pendingAction = action
        routing.consumeSystemAction()
        expect(routing.systemBridge.pendingAction == action, sheet + ": navigation deferred")
        expect(routing.model.reloadCount == 0, sheet + ": library unchanged while sheet open")
        routing.capturing = false
        routing.asking = false
        routing.showingSyncSettings = false
        routing.consumeSystemAction()
        expect(routing.systemBridge.pendingAction == nil, sheet + ": navigation replayed")
        switch action {
        case .find: expect(routing.model.query == "Hiking", sheet + ": search applied")
        case .open: expect(routing.navigationPath == [captureID], sheet + ": capture opened")
        default: break
        }
    }
}

for sheet in ["none", "ask", "sync"] {
    var routing = Routing()
    routing.asking = sheet == "ask"
    routing.showingSyncSettings = sheet == "sync"
    let oldID = routing.draftID
    routing.systemBridge.pendingAction = .stageText("New synthetic text")
    routing.consumeSystemAction()
    expect(routing.capturing && routing.stagedText == "New synthetic text", sheet + ": stage policy retained")
    expect(routing.draftID != oldID, sheet + ": fresh composer identity")
    expect(routing.systemBridge.consumptionCount == 1, sheet + ": staged exactly once")
}

print("\(checks) checks; \(failures) failures")
if failures != 0 { exit(1) }
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--module-cache", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    source = (root / "iOS/App/LibraryView.swift").read_text()
    assert ".sheet(isPresented: $capturing, onDismiss: consumeSystemAction)" in source
    assert "CaptureForm(model: model, initialText: stagedText).id(draftID)" in source
    start = source.index("    private func consumeSystemAction() {")
    end = source.index("\n}\n\nstruct CaptureForm", start)
    method = source[start:end].replace("private func", "mutating func", 1)
    with tempfile.TemporaryDirectory(prefix="capd-draft-routing-") as directory:
        directory = Path(directory)
        swift = directory / "main.swift"
        binary = directory / "draft-routing-tests"
        swift.write_text(HARNESS.replace("__ACTUAL_ROUTING_METHOD__", method))
        subprocess.run(
            ["xcrun", "swiftc", "-swift-version", "6", "-module-cache-path", str(args.module_cache),
             str(swift), "-o", str(binary)],
            check=True,
        )
        subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    main()
