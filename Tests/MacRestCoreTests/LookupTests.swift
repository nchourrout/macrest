import Foundation
import Testing
@testable import MacRestCore

/// The log of a `RunCommand` find as Backrest 1.14.1 writes it (trimmed
/// fields): its command line, then restic's array, one entry per backup.
let findLog = """
command: "/Users/alex/.local/share/backrest/restic find --json --ignore-case *draft* -o sftp.args=-oBatchMode=yes"
[{"matches":[{"path":"/Users/alex/Documents/Report draft.txt","type":"file","mtime":"2026-11-24T17:04:42.453286835+01:00","size":9}],"hits":1,"snapshot":"cc"},\
{"matches":[{"path":"/Users/alex/Documents/Report draft.txt","type":"file","mtime":"2026-11-24T17:04:38.575623457+01:00","size":17},\
{"path":"/Users/alex/Drafts [old]","type":"dir","mtime":"2026-01-02T10:00:00+01:00"}],"hits":2,"snapshot":"bb"},\
{"matches":[{"path":"/Users/alex/Documents/Report draft.txt","type":"file","mtime":"2026-11-24T17:04:38.575623457+01:00","size":17}],"hits":1,"snapshot":"aa"}]
"""

let times: [String: Date] = ["aa": Date(timeIntervalSince1970: 100), "bb": Date(timeIntervalSince1970: 200),
                             "cc": Date(timeIntervalSince1970: 300)]

@Suite struct FileSearchTests {
    @Test func groupsVersionsByPathNewestFirst() {
        let r = FileSearch.parse(findLog, snapshotTimes: times)
        #expect(!r.truncated)
        #expect(r.items.map(\.name) == ["Report draft.txt", "Drafts [old]"])
        let report = r.items[0]
        #expect(report.folder == "/Users/alex/Documents")
        // Two versions: 9 bytes in the newest backup, 17 bytes in the two before.
        #expect(report.versions.map(\.size) == [9, 17])
        #expect(report.versions[1].snapshots == ["bb", "aa"])
        #expect(report.versions[1].lastSeen == times["bb"])
        #expect(r.items[1].isDirectory)
        #expect(r.items[1].versions.first?.size == nil)
    }

    @Test func keepsWhatPrecedesACut() {
        // Backrest stops writing at 2 MB, mid-object.
        let cut = String(findLog.prefix(upTo: findLog.range(of: "{\"path\":\"/Users/alex/Drafts")!.lowerBound))
        let r = FileSearch.parse(cut, snapshotTimes: times)
        #expect(r.truncated)
        #expect(r.items.map(\.name) == ["Report draft.txt"])
        #expect(r.items[0].versions.map(\.snapshots) == [["cc"]])
    }

    @Test func noMatchesAndNoOutput() {
        #expect(FileSearch.parse("command: \"restic find [x]\"\n[]\n", snapshotTimes: [:]).items.isEmpty)
        #expect(!FileSearch.parse("command: \"restic find [x]\"\n[]\n", snapshotTimes: [:]).truncated)
        #expect(FileSearch.parse("", snapshotTimes: [:]).truncated)
    }

    @Test func commandQuotesThePattern() {
        #expect(FileSearch.pattern("  report ") == "*report*")
        #expect(FileSearch.pattern("*.pdf") == "*.pdf")
        // Brackets are part of names, not character classes.
        #expect(FileSearch.pattern("Drafts [old]") == "*Drafts [[]old]*")
        #expect(FileSearch.command(query: "my \"q\\", snapshots: ["aa", "bb"])
            == #"find --json --ignore-case --snapshot aa --snapshot bb "*my \"q\\*""#)
    }

    @Test func searchesTheLastThirtyDaysOrTheNewest() throws {
        func snap(_ id: String, daysAgo: Double) throws -> ResticSnapshot {
            let ms = Int((now.timeIntervalSince1970 - daysAgo * 86_400) * 1000)
            return try JSONDecoder().decode(ResticSnapshot.self, from: Data(#"{"id":"\#(id)","unixTimeMs":"\#(ms)"}"#.utf8))
        }
        let all = [try snap("new", daysAgo: 1), try snap("sameDay", daysAgo: 1.01), try snap("edge", daysAgo: 29.9),
                   try snap("old", daysAgo: 45)]
        // One per day, the last of it: hourly backups would be 720 walks.
        #expect(FileSearch.snapshotsToSearch(all, now: now, calendar: utc).map(\.id) == ["new", "edge"])
        #expect(FileSearch.snapshotsToSearch([try snap("old", daysAgo: 45), try snap("older", daysAgo: 90)], now: now).map(\.id) == ["old"])
        #expect(FileSearch.scopeText(FileSearch.snapshotsToSearch(all, now: now, calendar: utc), now: now) == "2 backups from the last 30 days")
        #expect(FileSearch.scopeText([try snap("old", daysAgo: 45)], now: now)?.hasPrefix("the last backup, from ") == true)
        #expect(FileSearch.scopeText([], now: now) == nil)
    }

    @Test func ownLookupsStayOutOfActivity() throws {
        let ops = try Activity.decode(Data("""
        {"operations":[
          {"id":"1","flowId":"1","status":"STATUS_SUCCESS","operationRunCommand":{"command":"find --json --ignore-case \\"*x*\\"","outputLogref":"c-1"}},
          {"id":"2","flowId":"2","status":"STATUS_SUCCESS","operationRunCommand":{"command":"snapshots"}},
          {"id":"3","flowId":"3","status":"STATUS_SUCCESS","operationRestore":{"target":"/Users/alex/Library/Caches/m/Quick Look/1"}},
          {"id":"4","flowId":"4","status":"STATUS_SUCCESS","operationRestore":{"target":"/Users/alex/Documents (from 2026)"}}]}
        """.utf8))
        #expect(ops[0].outputLogref == "c-1")
        let kept = ops.filter { !Lookups.isLookup($0, previewRoot: "/Users/alex/Library/Caches/m/Quick Look") }
        #expect(kept.map(\.id) == [2, 4])
        #expect(Activity.restore(into: "/Users/alex/Documents (from 2026)", in: ops)?.id == 4)
        #expect(Activity.restore(into: "/elsewhere", in: ops) == nil)
    }
}

@Suite struct RecoveryKitTests {
    @Test func carriesEverythingToReachTheStorage() throws {
        var c = try config()
        c["repos"] = .array([.object([
            "id": .string("b2"), "uri": .string("b2:bucket:mac"), "password": .string("hunter2"),
            "env": .array([.string("B2_ACCOUNT_ID=k1"), .string("B2_ACCOUNT_KEY=s3cret=x")]),
            "flags": .array([.string("-o"), .string("sftp.args=-i /Users/alex/.config/backrest/id_ed25519")]),
        ])])
        let kit = try #require(RecoveryKit.make(config: c, repoID: "b2"))
        #expect(kit.machine == "macbook")
        #expect(kit.fields.map(\.label) == ["Mac name", "Storage", "Password", "Key ID", "Application key", "Options"])
        // A value with "=" in it stays whole.
        #expect(kit.credentials[1].value == "s3cret=x")
        let text = kit.text(printed: now)
        #expect(text.contains("Password         hunter2"))
        #expect(text.contains("restic -r b2:bucket:mac snapshots"))
        #expect(text.contains("ssh key"))
        #expect(RecoveryKit.make(config: c, repoID: "nas") == nil)
        // A rotated key makes a different kit to keep.
        var rotated = kit
        rotated.credentials[1].value = "n3w"
        #expect(rotated.fingerprint != kit.fingerprint)
        #expect(kit.fingerprint == (try #require(RecoveryKit.make(config: c, repoID: "b2"))).fingerprint)
    }

    @Test func plainRepoHasNoCredentialRows() throws {
        let kit = try #require(RecoveryKit.make(config: try config(), repoID: "nas"))
        #expect(kit.fields.map(\.label) == ["Mac name", "Storage", "Password"])
        #expect(!kit.steps.contains { $0.contains("ssh key") })
    }
}

@Suite struct SentRequestsTests {
    func ops(_ json: String) throws -> [BackrestOperation] { try Activity.decode(Data(#"{"operations":[\#(json)]}"#.utf8)) }

    @Test func eachKindWaitsOnItsOwn() throws {
        var sent = SentRequests()
        sent.send(.check, at: now)
        #expect(sent.isBusy(.check, flows: [], now: now))
        #expect(!sent.isBusy(.prune, flows: [], now: now))
        #expect(!sent.isBusy(.backup, flows: [], now: now))
        sent.send(.prune, at: now)
        #expect(sent.isBusy(.check, flows: [], now: now))
        #expect(!sent.isSending(.check, now: now.addingTimeInterval(SentRequests.grace)))
    }

    @Test func settlesOnceTheOplogShowsTheRun() throws {
        var sent = SentRequests()
        sent.send(.check, at: now)
        sent.send(.prune, at: now)
        let ms = Int(now.timeIntervalSince1970 * 1000)
        // The check already finished by this poll; an older prune does not count.
        let log = try ops("""
        {"id":"1","flowId":"1","status":"STATUS_SUCCESS","unixTimeStartMs":"\(ms + 300)","operationCheck":{}},
        {"id":"2","flowId":"2","status":"STATUS_SUCCESS","unixTimeStartMs":"\(ms - 60_000)","operationPrune":{}}
        """)
        sent.settle(log, now: now.addingTimeInterval(1))
        #expect(!sent.isSending(.check, now: now.addingTimeInterval(1)))
        #expect(sent.isSending(.prune, now: now.addingTimeInterval(1)))
        sent.settle(log, now: now.addingTimeInterval(25))
        #expect(!sent.any(now: now.addingTimeInterval(25)))
    }

    @Test func aRunningOrQueuedRunIsBusy() throws {
        let flows = Activity.flows(try ops("""
        {"id":"1","flowId":"1","status":"STATUS_INPROGRESS","unixTimeStartMs":"1","operationCheck":{}}
        """), now: now).flows
        #expect(SentRequests().isBusy(.check, flows: flows, now: now))
        #expect(!SentRequests().isBusy(.prune, flows: flows, now: now))
    }
}
