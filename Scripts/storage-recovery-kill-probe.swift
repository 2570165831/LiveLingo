// Standalone, synthetic-only crash probe. Compile with SensitiveFileIO.swift
// and -D DEBUG; it has no AppKit entry point and never loads an app runtime.
import CryptoKit
import Darwin
import Foundation

enum SessionArchiveCoding {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func isDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
enum ExitDeadline { static func storageDidProgress() {} }

@main
enum StorageRecoveryKillProbe {
    static func main() {
        do { try run() }
        catch { _exit(73) } // An unexpected error must never create a crash dialog.
    }

    private static func run() throws {
        if CommandLine.arguments.count == 2, CommandLine.arguments[1] == "signpost" {
            _ = readLine() // Let a PID-filtered collector attach first.
            SensitiveFileIO.timedIO(.entryStatus) { errno = ENOENT }
            Thread.sleep(forTimeInterval: 0.1)
            return
        }
        guard CommandLine.arguments.count == 3,
              ["after-unlink", "before-relock"].contains(CommandLine.arguments[1]) else { exit(64) }
        let destination = URL(fileURLWithPath: CommandLine.arguments[2])
        if CommandLine.arguments[1] == "after-unlink" {
            try SensitiveFileIO.$afterAliasUnlink.withValue({
                kill(getpid(), SIGKILL)
                _exit(70)
            }) { try SensitiveFileIO.recoverCommittedFileIfNeeded(at: destination) }
            exit(71) // The hook must be reached, not silently skipped.
        }
        try SensitiveFileIO.recoverCommittedFileIfNeeded(at: destination)
        // Recovery has closed its lease and synced the directory. No store
        // lock or transaction has been entered when the process is killed.
        kill(getpid(), SIGKILL)
        _exit(72)
    }
}
