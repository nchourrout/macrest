import Foundation
import Testing
@testable import MacRestCore

@Suite struct OverviewTests {
    @Test func cancelledAndFailedBackups() throws {
        let cancelled = try overview([op(1, "operationBackup", "STATUS_USER_CANCELLED", hoursAgo: 1)])
        #expect(cancelled.title == "Last backup was cancelled")
        #expect(cancelled.severity == .error)
        // A failing cleanup does not soften a failed backup.
        let failed = try overview([op(1, "operationBackup", "STATUS_ERROR", hoursAgo: 1),
                                   op(2, "operationForget", "STATUS_ERROR", hoursAgo: 1, flow: 1, message: "locked")])
        #expect(failed.severity == .error)
        #expect(failed.title == "Last backup failed")
    }

    @Test func warningsBecomeAnErrorAtHalfFailures() throws {
        // Since the last clean backup: one failure, two warnings. Under half.
        let mostlyWarned = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 5),
                                         op(2, "operationBackup", "STATUS_ERROR", hoursAgo: 4),
                                         op(3, "operationBackup", "STATUS_WARNING", hoursAgo: 3),
                                         op(4, "operationBackup", "STATUS_WARNING", hoursAgo: 2)])
        #expect(mostlyWarned.severity == .warning)
        // Exactly half: an error.
        let half = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 4),
                                 op(2, "operationBackup", "STATUS_ERROR", hoursAgo: 3),
                                 op(3, "operationBackup", "STATUS_WARNING", hoursAgo: 2)])
        #expect(half.severity == .error)
    }

    @Test func severalMaintenanceFailures() throws {
        let o = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 2),
                              op(2, "operationForget", "STATUS_ERROR", hoursAgo: 2, flow: 1, message: "locked"),
                              op(3, "operationCheck", "STATUS_ERROR", hoursAgo: 3, message: "locked")])
        #expect(o.severity == .warning)
        #expect(o.title == "Maintenance is failing")
        #expect(o.failingMaintenance == ["Cleanup", "Verification"])
        // An unlock clears verification's failure too, not only cleanup's.
        #expect(try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 2),
                              op(3, "operationCheck", "STATUS_ERROR", hoursAgo: 3, message: "locked")],
                             unlockedAt: now.addingTimeInterval(-600)).severity == .ok)
    }

    @Test func runningAndNext() throws {
        let first = try overview([op(1, "operationBackup", "STATUS_INPROGRESS", hoursAgo: 0.1)])
        #expect(first.title == "First backup running")
        #expect(first.running)
        let again = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 2),
                                  op(2, "operationBackup", "STATUS_INPROGRESS", hoursAgo: 0.1)])
        #expect(again.title == "Backing up")
        // Next run on another day names the day.
        let tomorrow = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 2),
                                     op(2, "operationBackup", "STATUS_PENDING", hoursAgo: -26)])
        #expect(tomorrow.subtitle.hasSuffix("next Wed 14:00"))
        // Nothing older than the window counts as a run.
        #expect(try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 24 * 20)]).days.allSatisfy { $0.total == 0 })
    }

    @Test func healthy() throws {
        let o = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 2),
                              op(2, "operationBackup", "STATUS_PENDING", hoursAgo: -2)])
        #expect(o.severity == .ok)
        #expect(o.title == "Backups healthy")
        #expect(o.subtitle == "Last backup 1h ago · next 14:00")
        #expect(o.days.count == 14)
        #expect(o.days.last?.ok == 1)
    }

    @Test func staleLockShowsThroughAGoodBackup() throws {
        let o = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 2),
                              op(2, "operationForget", "STATUS_ERROR", hoursAgo: 2, flow: 1, message: "locked")])
        #expect(o.severity == .warning)
        #expect(o.title == "Cleanup is failing")
        #expect(o.failingMaintenance == ["Cleanup"])

        // After an unlock, that failure no longer counts.
        let after = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 2),
                                  op(2, "operationForget", "STATUS_ERROR", hoursAgo: 2, flow: 1, message: "locked")],
                                 unlockedAt: now.addingTimeInterval(-600))
        #expect(after.severity == .ok)
        #expect(after.failingMaintenance.isEmpty)
    }

    @Test func staleAndNeverAndChronic() throws {
        #expect(try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 40)]).title == "Backups have stopped")
        #expect(try overview([]).severity == .unknown)
        // Failures a clean backup made up for stay in the tally, not in the verdict.
        let recovered = try overview((1...4).map { op($0, "operationBackup", $0 == 4 ? "STATUS_SUCCESS" : "STATUS_ERROR", hoursAgo: Double(10 - $0)) })
        #expect(recovered.severity == .ok)
        #expect(recovered.title == "Backups healthy")
        #expect(recovered.failed == 3)
        // Warnings with mostly failures since the last clean backup are an error.
        let chronic = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 9),
                                    op(2, "operationBackup", "STATUS_ERROR", hoursAgo: 8),
                                    op(3, "operationBackup", "STATUS_ERROR", hoursAgo: 7),
                                    op(4, "operationBackup", "STATUS_WARNING", hoursAgo: 6)])
        #expect(chronic.severity == .error)
        #expect(chronic.title == "Last backup had warnings")
    }

    @Test func unreachableStorageIsMissedNotFailed() throws {
        let sftp = "failed\nOutput:\nssh: connect to host h port 22: Operation timed out\nFatal: unable to open repository at sftp:h:/r: unable to start the sftp session"
        let o = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 6),
                              op(2, "operationBackup", "STATUS_ERROR", hoursAgo: 3, message: sftp),
                              op(3, "operationBackup", "STATUS_ERROR", hoursAgo: 1, message: sftp)])
        #expect(o.severity == .ok)
        #expect(o.title == "Backups healthy")
        #expect(o.subtitle.hasPrefix("Last backup 5h ago · storage unreachable"))
        #expect(o.failed == 0)
        #expect(o.missed == 2)
        #expect(o.summary == "1 ok · 0 failed · 2 missed")
        // Past the staleness limit, misses are backups that stopped.
        let stale = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 40),
                                  op(2, "operationBackup", "STATUS_ERROR", hoursAgo: 1, message: sftp)])
        #expect(stale.title == "Backups have stopped")
        #expect(stale.severity == .error)
        // Never reached at all.
        #expect(try overview([op(1, "operationBackup", "STATUS_ERROR", hoursAgo: 1, message: sftp)]).title == "Storage unreachable")
        // A long outage that pushed the last good backup out of the log.
        let gone = try overview([op(1, "operationBackup", "STATUS_ERROR", hoursAgo: 50, message: sftp),
                                 op(2, "operationBackup", "STATUS_ERROR", hoursAgo: 1, message: sftp)])
        #expect(gone.title == "Backups have stopped")
        #expect(gone.subtitle.hasPrefix("Last try "))
        // Any other failure stays a failure.
        let broken = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 6),
                                   op(2, "operationBackup", "STATUS_ERROR", hoursAgo: 1, message: "Fatal: wrong password or no key found")])
        #expect(broken.title == "Last backup failed")
    }
}

@Suite struct SnapshotTests {
    @Test func decodesSnapshotsNewestFirst() throws {
        let json = #"{"snapshots":[{"id":"aaaa1111","unixTimeMs":"1000","paths":["/Users/alex"],"tags":["plan:home"],"summary":{"dataAdded":"42"}},{"id":"bbbb2222","unixTimeMs":"2000","paths":["/Users/alex"]}]}"#
        let s = try Snapshots.decode(Data(json.utf8))
        #expect(s.map(\.shortID) == ["bbbb2222", "aaaa1111"])
        #expect(s[1].dataAdded == 42)
    }

    @Test func decodesEntriesFoldersFirst() throws {
        let json = #"{"path":"/Users/alex","entries":[{"name":"alex","type":"dir","path":"/Users/alex","mtime":"2026-11-09T12:36:32.53385299+01:00"},{"name":"b.txt","type":"file","path":"/Users/alex/b.txt","size":"7","mtime":"2026-09-14T21:41:15.405851956+02:00"},{"name":"Zeta","type":"dir","path":"/Users/alex/Zeta"},{"name":"a.txt","type":"file","path":"/Users/alex/a.txt","size":"9","mtime":"2026-09-14T21:41:15Z"}]}"#
        let e = try Snapshots.decodeEntries(Data(json.utf8), folder: "/Users/alex")
        #expect(e.map(\.name) == ["Zeta", "a.txt", "b.txt"])
        #expect(e[2].size == 7)
        // Nanoseconds and a zone offset, read to the instant.
        #expect(abs((e[2].modified?.timeIntervalSince1970 ?? 0) - 1_789_414_875.405_852) < 0.001)
        #expect(e[1].modified == ISO8601DateFormatter().date(from: "2026-09-14T21:41:15Z"))
    }

    @Test func restoreTargetNeverCollides() {
        let t = Snapshots.restoreTarget(for: "/Users/alex/dev/notes.md", snapshotTime: Date(timeIntervalSince1970: 0)) { _ in false }
        #expect(t.hasPrefix("/Users/alex/dev/notes.md (from 19"))
        var taken: Set<String> = [t]
        let second = Snapshots.restoreTarget(for: "/Users/alex/dev/notes.md", snapshotTime: Date(timeIntervalSince1970: 0)) { taken.contains($0) }
        #expect(second == t + " 2")
        taken.insert(second)
        #expect(Snapshots.restoreTarget(for: "/Users/alex/dev/notes.md", snapshotTime: Date(timeIntervalSince1970: 0)) { taken.contains($0) } == t + " 3")
    }

    @Test func breadcrumb() {
        #expect(Snapshots.breadcrumb("/Users/alex/dev/x", root: "/Users/alex") == ["/Users/alex", "/Users/alex/dev", "/Users/alex/dev/x"])
        #expect(Snapshots.breadcrumb("/Users/alex", root: "/Users/alex") == ["/Users/alex"])
        // A sibling that merely starts with the root's name is not under it.
        #expect(Snapshots.breadcrumb("/Users/alexander/x", root: "/Users/alex") == ["/Users/alex"])
        #expect(Snapshots.breadcrumb("/Users/alex/x", root: "/") == ["/", "/Users", "/Users/alex", "/Users/alex/x"])
    }
}

@Suite struct UnreachableTests {
    /// restic's and ssh's own output, with real line breaks.
    @Test func classifiesTheWholeOutput() {
        let offline = "failed to get snapshots\nOutput:\nsubprocess ssh: ssh: connect to host 100.75.2.128 port 22: Operation timed out\n{\"message_type\":\"exit_error\",\"code\":1,\"message\":\"Fatal: unable to open repository at sftp:h:/r: unable to start the sftp session, error: unexpected EOF\"}"
        let unplugged = "failed\nOutput:\nFatal: unable to open config file: stat /Volumes/X/config: no such file or directory\nIs there a repository at the following location?\n/Volumes/X"
        let revoked = "failed\nOutput:\nsubprocess ssh: nico@h: Permission denied (publickey).\n{\"message_type\":\"exit_error\",\"code\":1,\"message\":\"Fatal: unable to open repository at sftp:h:/r: unable to start the sftp session, error: unexpected EOF\"}"
        let locked = "Fatal: unable to create lock in backend: repository is already locked"
        #expect(BackrestOperation.isUnreachable(offline))
        #expect(BackrestOperation.isUnreachable(unplugged))
        #expect(BackrestOperation.isUnreachable("Fatal: unable to start the sftp session, error: error receiving version packet from server: error reading packet length: 0 of 4: read |0: file already closed"))
        #expect(!BackrestOperation.isUnreachable(revoked))
        #expect(!BackrestOperation.isUnreachable(locked))
    }
}

@Suite struct DayProblemTests {
    @Test func failuresAndWarningsExplainTheirDay() throws {
        let sftp = "failed to get snapshots\nOutput:\nssh: connect to host h port 22: Operation timed out\nFatal: unable to open repository at sftp:h:/r: unable to start the sftp session"
        let start = Int64((now.timeIntervalSince1970 - 3600) * 1000)
        let warned = #"{"id":"3","status":"STATUS_WARNING","unixTimeStartMs":"\#(start)","unixTimeEndMs":"\#(start + 1000)","displayMessage":"Partial backup","operationBackup":{"errors":[{"item":"/a","message":"open /a: operation not permitted"},{"item":"/b","message":"open /b: operation not permitted"}]}}"#
        let mixed = #"{"id":"4","status":"STATUS_WARNING","unixTimeStartMs":"\#(start - 7_200_000)","unixTimeEndMs":"\#(start - 7_199_000)","operationBackup":{"errors":[{"item":"/c","message":"open /c: operation not permitted"},{"item":"/d","message":"read /d: input/output error"}]}}"#
        let skipped = try Activity.decode(Data(#"{"operations":[\#(mixed)]}"#.utf8)).first?.problem
        #expect(skipped == "1 private folder and 1 unreadable file skipped, no Full Disk Access")
        let o = try overview([op(1, "operationBackup", "STATUS_ERROR", hoursAgo: 3, message: sftp),
                              op(2, "operationBackup", "STATUS_ERROR", hoursAgo: 2, message: sftp),
                              warned])
        #expect(o.days.last?.problems == ["2× Storage unreachable", "2 private folders skipped, no Full Disk Access"])
        #expect(o.days.last?.missed == 2)
        #expect(o.privateFoldersSkipped == 2)
        #expect(o.days.last?.summary == "1 warned, 2 missed · 2× Storage unreachable · 2 private folders skipped, no Full Disk Access")
        #expect(o.days.first?.summary == "no backup")
        #expect(o.title == "Last backup had warnings")
    }
}

@Suite struct WordingTests {
    @Test func failingMaintenanceReadsAsASentence() {
        #expect(Format.failing([]) == "")
        #expect(Format.failing(["Cleanup"]) == "Cleanup failed on its last run.")
        #expect(Format.failing(["Cleanup", "Verification"]) == "Cleanup and verification failed on their last runs.")
        #expect(Format.failing(["Cleanup", "Space recovery", "Verification"])
            == "Cleanup, space recovery and verification failed on their last runs.")
    }
}
