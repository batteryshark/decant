// Finder front end for the decant CLI in Contents/Helpers: opening a file runs it
// in the Default bottle; the "Run in Bottle…" service asks for a bottle first.
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let cli = Bundle.main.bundleURL.appending(path: "Contents/Helpers/decant")
    var running = 0

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.quitIfIdle() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { decant([url.path]) }
    }

    @objc func runInBottle(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        running += 1
        // Return to the caller before the modal chooser, or Finder waits on it.
        DispatchQueue.main.async {
            if let bottle = self.chooseBottle() {
                for url in urls { self.decant(["--bottle", bottle, url.path]) }
            }
            self.running -= 1
            self.quitIfIdle()
        }
    }

    func chooseBottle() -> String? {
        let names = (try? output(["bottles", "list"]))?.split(separator: "\n").compactMap { $0.split(separator: "\t").first.map(String.init) } ?? []
        let box = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        box.addItems(withObjectValues: names)
        box.stringValue = names.first ?? "Default"
        let alert = NSAlert()
        alert.messageText = "Run in bottle"
        alert.informativeText = "Pick a bottle or type a new name."
        alert.accessoryView = box
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = box
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? box.stringValue : nil
    }

    func output(_ args: [String]) throws -> String {
        let proc = Process()
        let out = Pipe()
        proc.executableURL = cli
        proc.arguments = args
        proc.standardOutput = out
        try proc.run()
        proc.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// Runs the CLI and shows its stderr if it fails. stderr goes to a file, not a
    /// pipe: Wine processes it starts may inherit the descriptor and outlive it.
    func decant(_ args: [String]) {
        running += 1
        let errURL = FileManager.default.temporaryDirectory.appending(path: "decant-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let proc = Process()
        proc.executableURL = cli
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = try? FileHandle(forWritingTo: errURL)
        proc.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                let message = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: errURL)
                self.finished(args, status: status, message: message)
            }
        }
        do { try proc.run() } catch { finished(args, status: -1, message: "\(error)") }
    }

    func finished(_ args: [String], status: Int32, message: String) {
        if status != 0 {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Couldn't run \(URL(filePath: args.last ?? "").lastPathComponent)"
            alert.informativeText = message.isEmpty ? "decant exited with status \(status)" : message
            NSApp.activate()
            alert.runModal()
        }
        running -= 1
        quitIfIdle()
    }

    func quitIfIdle() {
        if running == 0 { NSApp.terminate(nil) }
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
