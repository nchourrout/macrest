import Foundation
import Testing
@testable import MacRestCore

@Suite struct FormatTests {
    @Test func sizes() {
        #expect(Format.size(-5) == "0 B")
        #expect(Format.size(1023) == "1023 B")
        #expect(Format.size(1024) == "1K")
        #expect(Format.size(1_572_864) == "1.5M")
        #expect(Format.size(15 * 1_048_576) == "15M")
        #expect(Format.size(3 * 1_073_741_824) == "3.0G")
    }

    @Test func agesAndDurations() {
        #expect(Format.ago(59) == "just now")
        #expect(Format.ago(60) == "1m ago")
        #expect(Format.ago(3599) == "59m ago")
        #expect(Format.ago(3600) == "1h ago")
        #expect(Format.ago(86_400) == "1d ago")
        #expect(Format.duration(-1) == "0s")
        #expect(Format.duration(59) == "59s")
        #expect(Format.duration(3661) == "1h 1m")
        #expect(Format.duration(90_000) == "1d 1h")
    }

    @Test func countsAndWords() {
        #expect(Format.count(1036) == "1,036")
        #expect(Format.plural(1, "backup") == "1 backup")
        #expect(Format.plural(0, "backup") == "0 backups")
        #expect(Format.date(now, "d MMM yyyy HH:mm", timeZone: TimeZone(identifier: "UTC")!) == "3 Nov 2026 12:00")
    }

    @Test func latestStatsSkipsFailuresAndGaps() throws {
        let ops = try decodeOps([
            op(1, "operationStats", "STATUS_SUCCESS", hoursAgo: 30, payload: #"{"stats":{"totalSize":"100","snapshotCount":"3"}}"#),
            op(2, "operationStats", "STATUS_ERROR", hoursAgo: 20, payload: #"{"stats":{"totalSize":"999"}}"#),
            op(3, "operationStats", "STATUS_SUCCESS", hoursAgo: 10, payload: #"{"stats":{}}"#),
        ])
        let latest = try #require(Activity.latestStats(ops))
        #expect(latest.0.totalSize == 100)
        #expect(latest.1 == ops[0].finishedAt)
    }

    @Test func sizeCheckEndsOnTheRunAfterTheClick() throws {
        let asked = now.addingTimeInterval(-3600)
        let ops = try decodeOps([
            op(1, "operationStats", "STATUS_SUCCESS", hoursAgo: 5),
            op(2, "operationStats", "STATUS_INPROGRESS", hoursAgo: 0.5),
        ])
        #expect(Activity.sizeCheck(after: asked, in: ops) == nil)
        let failed = try decodeOps([op(2, "operationStats", "STATUS_ERROR", hoursAgo: 0.5, message: "Fatal: unable to open repository")])
        #expect(Activity.sizeCheck(after: asked, in: failed)?.outcome == .failed)
        #expect(Activity.sizeCheck(after: asked, in: failed)?.reason?.contains("unable to open repository") == true)
    }

    @Test func anyMaintenanceKindCanBeBlocked() throws {
        let flows = Activity.flows(try decodeOps([
            op(1, "operationForget", "STATUS_SUCCESS", hoursAgo: 2),
            op(2, "operationPrune", "STATUS_ERROR", hoursAgo: 1, message: "Fatal: repository is already locked by PID 7"),
        ]), now: now).flows
        // Cleanup is fine, space recovery hit the lock.
        #expect(Activity.staleLock(in: flows, unlockedAt: nil) == nil)
        #expect(Activity.blockedByLock(flows, unlockedAt: nil))
        #expect(!Activity.blockedByLock(flows, unlockedAt: now))
    }

    @Test func outcomes() {
        #expect(BackrestOperation.Outcome("STATUS_PENDING").isUnderway)
        #expect(BackrestOperation.Outcome("STATUS_INPROGRESS").isUnderway)
        #expect(!BackrestOperation.Outcome("STATUS_WARNING").isUnderway)
        #expect(BackrestOperation.Outcome("STATUS_SYSTEM_CANCELLED") == .cancelled)
        #expect(BackrestOperation.Outcome("STATUS_SOMETHING_NEW") == .unknown)
        #expect(Severity.ok < .warning && Severity.warning < .unknown && Severity.unknown < .error)
    }
}
