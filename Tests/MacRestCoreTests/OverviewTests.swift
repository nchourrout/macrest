import Foundation
import Testing
@testable import MacRestCore

/// Fixed clock: 2026-11-03 12:00:00 UTC.
let now = Date(timeIntervalSince1970: 1_793_707_200)

func op(_ id: Int, _ kind: String, _ status: String, hoursAgo: Double, flow: Int? = nil, message: String? = nil) -> String {
    let start = Int64((now.timeIntervalSince1970 - hoursAgo * 3600) * 1000)
    let msg = message.map { #","displayMessage":\#(String(decoding: try! JSONEncoder().encode($0), as: UTF8.self))"# } ?? ""
    return #"{"id":"\#(id)","flowId":"\#(flow ?? id)","status":"\#(status)","unixTimeStartMs":"\#(start)","unixTimeEndMs":"\#(start + 60000)"\#(msg),"\#(kind)":{}}"#
}

func overview(_ ops: [String]) throws -> Overview {
    let decoded = try Activity.decode(Data(#"{"operations":[\#(ops.joined(separator: ","))]}"#.utf8))
    let (flows, scheduled) = Activity.flows(decoded, now: now)
    return Overview.make(flows: flows, scheduled: scheduled, now: now, calendar: utc)
}

let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

@Suite struct OverviewTests {
    @Test func healthy() throws {
        let o = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 2),
                              op(2, "operationBackup", "STATUS_PENDING", hoursAgo: -2)])
        #expect(o.severity == .ok)
        #expect(o.title == "Backups healthy")
        #expect(o.subtitle == "last backup 1h ago · next 14:00")
        #expect(o.days.count == 14)
        #expect(o.days.last?.ok == 1)
    }

    @Test func staleLockShowsThroughAGoodBackup() throws {
        let o = try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 2),
                              op(2, "operationForget", "STATUS_ERROR", hoursAgo: 2, flow: 1, message: "locked")])
        #expect(o.severity == .warning)
        #expect(o.title == "Retention is failing")
        #expect(o.failingMaintenance == ["Retention"])
    }

    @Test func staleAndNeverAndChronic() throws {
        #expect(try overview([op(1, "operationBackup", "STATUS_SUCCESS", hoursAgo: 40)]).title == "Backups have stopped")
        #expect(try overview([]).severity == .unknown)
        let chronic = try overview((1...4).map { op($0, "operationBackup", $0 == 4 ? "STATUS_SUCCESS" : "STATUS_ERROR", hoursAgo: Double(10 - $0)) })
        #expect(chronic.severity == .error)
        #expect(chronic.title == "Backups failing often")
        #expect(chronic.failed == 3)
    }
}

@Suite struct SnapshotTests {
    @Test func decodesSnapshotsNewestFirst() throws {
        let json = #"{"snapshots":[{"id":"aaaa1111","unixTimeMs":"1000","paths":["/Users/nico"],"tags":["plan:home"],"summary":{"dataAdded":"42"}},{"id":"bbbb2222","unixTimeMs":"2000","paths":["/Users/nico"]}]}"#
        let s = try Snapshots.decode(Data(json.utf8))
        #expect(s.map(\.shortID) == ["bbbb2222", "aaaa1111"])
        #expect(s[1].dataAdded == 42)
    }

    @Test func decodesEntriesFoldersFirst() throws {
        let json = #"{"path":"/Users/nico","entries":[{"name":"nico","type":"dir","path":"/Users/nico","mtime":"2026-11-09T12:36:32.53385299+01:00"},{"name":"b.txt","type":"file","path":"/Users/nico/b.txt","size":"7","mtime":"2026-09-14T21:41:15.405851956+02:00"},{"name":"Zeta","type":"dir","path":"/Users/nico/Zeta"},{"name":"a.txt","type":"file","path":"/Users/nico/a.txt","size":"9","mtime":"2026-09-14T21:41:15Z"}]}"#
        let e = try Snapshots.decodeEntries(Data(json.utf8), folder: "/Users/nico")
        #expect(e.map(\.name) == ["Zeta", "a.txt", "b.txt"])
        #expect(e[2].size == 7)
        #expect(e[2].modified != nil)
        #expect(e[1].modified != nil)
    }

    @Test func restoreTargetNeverCollides() {
        let t = Snapshots.restoreTarget(for: "/Users/nico/dev/notes.md", snapshotTime: Date(timeIntervalSince1970: 0)) { _ in false }
        #expect(t.hasPrefix("/Users/nico/dev/notes.md (from 19"))
        var taken: Set<String> = [t]
        let second = Snapshots.restoreTarget(for: "/Users/nico/dev/notes.md", snapshotTime: Date(timeIntervalSince1970: 0)) { taken.contains($0) }
        #expect(second == t + " 2")
        taken.insert(second)
    }

    @Test func breadcrumb() {
        #expect(Snapshots.breadcrumb("/Users/nico/dev/x", root: "/Users/nico") == ["/Users/nico", "/Users/nico/dev", "/Users/nico/dev/x"])
        #expect(Snapshots.breadcrumb("/Users/nico", root: "/Users/nico") == ["/Users/nico"])
    }
}
