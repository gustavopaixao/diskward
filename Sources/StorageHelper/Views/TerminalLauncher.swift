import AppKit
import StorageCore

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Opens Terminal.app and runs commands there, so you can watch them or adjust them.
///
/// Writes a temporary `.command` script and opens it: Terminal runs `.command` files natively,
/// so no Automation (AppleScript) permission is needed.
enum TerminalLauncher {
    static func run(_ commands: [ShellCommand]) {
        guard !commands.isEmpty else { return }
        let path = ShellRunner.searchPaths.joined(separator: ":")
        var lines = [
            "#!/bin/zsh",
            "export PATH=\"\(path):$PATH\"",
            "clear",
            "echo 'Storage Helper: running \(commands.count) command\(commands.count == 1 ? "" : "s")'",
            "echo",
        ]
        for command in commands {
            let line = command.shellLine
            lines.append("echo \(ShellCommandQuote.quote("$ " + line))")
            lines.append(line)
            lines.append("echo")
        }
        lines += [
            "echo 'Done. Rescan in Storage Helper (⌘R) to update the numbers.'",
            "rm -f \"$0\"", // remove this temporary script
            "exec zsh -l",  // keep the window open as a normal shell
        ]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("storage-helper-\(UUID().uuidString.prefix(8)).command")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            NSSound.beep()
        }
    }
}

/// Same quoting rules as `ShellCommand.shellLine`, for arbitrary strings.
enum ShellCommandQuote {
    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
