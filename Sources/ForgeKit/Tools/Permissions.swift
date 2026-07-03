import Foundation

/// Bash command classification used by the approval layer.
///
/// `isDangerous` forces an approval dialog even when auto-approve is on;
/// `isReadOnly` lets obviously harmless commands through without a dialog.
enum BashSafety {

    static func isDangerous(_ command: String) -> Bool {
        let c = command.lowercased()
        let needles = [
            "rm -rf", "rm -fr", "sudo ", "git push", "> /dev/", "mkfs",
            ":(){", "| sh", "|sh", "| bash", "|bash", "| zsh", "|zsh",
            "shutdown", "reboot", "diskutil erase", "launchctl unload",
        ]
        if needles.contains(where: { c.contains($0) }) { return true }
        // Piping downloads into anything is always dialog-worthy.
        if (c.contains("curl ") || c.contains("wget ")) && c.contains("| ") { return true }
        // Any write-ish touch of ~/.ssh.
        if c.contains(".ssh") && (c.contains(">") || c.contains("cp ") || c.contains("mv ")
            || c.contains("rm ") || c.contains("chmod ")) { return true }
        return false
    }

    static func isReadOnly(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // Redirection, chaining, piping or substitution disqualifies.
        for meta in [">", "&&", ";", "|", "`", "$("] where trimmed.contains(meta) {
            return false
        }
        let tokens = trimmed.split(separator: " ").map(String.init)
        guard let first = tokens.first else { return false }
        let readOnly: Set<String> = [
            "ls", "cat", "head", "tail", "pwd", "which", "echo", "wc",
            "file", "stat", "du", "df", "uname", "sw_vers",
        ]
        if readOnly.contains(first) { return true }
        if first == "git", tokens.count >= 2 {
            return ["status", "diff", "log", "show", "branch", "remote"].contains(tokens[1])
        }
        return false
    }
}
