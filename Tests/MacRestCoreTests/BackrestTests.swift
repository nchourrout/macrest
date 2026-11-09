import Foundation
import Testing
@testable import MacRestCore

/// The shape GetConfig returns here, password and all, with fields the app
/// does not model (hooks, sync, auth, guid) that a save must keep.
let configJSON = """
{"modno":4,"version":6,"instance":"macbook","auth":{"disabled":true},
 "repos":[{"id":"nas","uri":"sftp:nas:/backups/mac","guid":"0cea","password":"hunter2",
   "prunePolicy":{"schedule":{"maxFrequencyDays":7,"clock":"CLOCK_LAST_RUN_TIME"},"maxUnusedPercent":10},
   "checkPolicy":{"schedule":{"maxFrequencyDays":30,"clock":"CLOCK_LAST_RUN_TIME"},"structureOnly":true}}],
 "plans":[{"id":"home","repo":"nas","paths":["/Users/alex"],"excludes":["/Users/alex/.Trash","**/node_modules"],
   "schedule":{"maxFrequencyHours":4,"clock":"CLOCK_LAST_RUN_TIME"},
   "retention":{"policyTimeBucketed":{"daily":7,"weekly":4,"monthly":3}},
   "hooks":[{"conditions":["CONDITION_FORGET_ERROR"],"actionCommand":{"command":"osascript"}}],
   "backup_flags":["--exclude-caches"]}],
 "sync":{"identity":{"keyId":"ed25519.T7D"}}}
"""

func config() throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(configJSON.utf8)) }

func roundTrip(_ v: JSONValue) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(v))
}

@Suite struct BackrestConfigTests {
    @Test func jsonRoundTripKeepsEverything() throws {
        let c = try config()
        #expect(try roundTrip(c) == c)
        // Whole numbers stay integers: Backrest's int32 fields reject "7.0".
        let encoded = String(decoding: try JSONEncoder().encode(c["modno"]), as: UTF8.self)
        #expect(encoded == "4")
        // Bools and numbers stay apart.
        let mixed = try JSONDecoder().decode(JSONValue.self, from: Data("[1, true, 0, false, 2.5]".utf8))
        #expect(mixed == .array([.number(1), .bool(true), .number(0), .bool(false), .number(2.5)]))
    }

    @Test func readsPlanAndRepo() throws {
        let (plan, repo) = try #require(BackrestConfig.read(try config()))
        #expect(plan.id == "home")
        #expect(plan.paths == ["/Users/alex"])
        #expect(plan.excludes.count == 2)
        #expect(plan.schedule == .everyHours(4))
        #expect(plan.retention == .buckets(TimeBuckets(daily: 7, weekly: 4, monthly: 3)))
        #expect(repo.checkSchedule == .everyDays(30))
        #expect(repo.checkMode == .structureOnly)
        #expect(repo.pruneSchedule == .everyDays(7))
        #expect(repo.pruneMaxUnusedPercent == 10)
    }

    @Test func unchangedSettingsChangeNothing() throws {
        let c = try config()
        let (plan, repo) = try #require(BackrestConfig.read(c))
        #expect(try roundTrip(BackrestConfig.applied(plan, repo, to: c)) == c)
    }

    @Test func editsKeepUnmodelledFields() throws {
        let c = try config()
        var (plan, repo) = try #require(BackrestConfig.read(c))
        plan.schedule = .everyHours(1)
        plan.retention = .buckets(TimeBuckets(hourly: 24, daily: 30, weekly: 52, monthly: 24))
        plan.excludes.append("**/.venv")
        repo.checkMode = .readData(percent: 10)
        repo.autoUnlock = true
        let out = try roundTrip(BackrestConfig.applied(plan, repo, to: c))

        let p = try #require(out["plans"]?.array?.first)
        #expect(p["schedule"] == .object(["maxFrequencyHours": .number(1), "clock": .string("CLOCK_LAST_RUN_TIME")]))
        #expect(p["retention"]?["policyTimeBucketed"]?["hourly"]?.int == 24)
        #expect(p["excludes"]?.strings.last == "**/.venv")
        #expect(p["hooks"] == c["plans"]?.array?.first?["hooks"])
        #expect(p["backup_flags"]?.strings == ["--exclude-caches"])

        let r = try #require(out["repos"]?.array?.first)
        #expect(r["password"]?.string == "hunter2")
        #expect(r["guid"]?.string == "0cea")
        #expect(r["checkPolicy"]?["structureOnly"] == nil)
        #expect(r["checkPolicy"]?["readDataSubsetPercent"]?.number == 10)
        #expect(r["autoUnlock"]?.bool == true)
        #expect(out["sync"] == c["sync"])
        #expect(out["auth"] == c["auth"])
        #expect(out["modno"] == c["modno"])
    }

    @Test func problems() throws {
        var (plan, _) = try #require(BackrestConfig.read(try config()))
        #expect(plan.problems.isEmpty)
        plan.paths = [" "]
        plan.retention = .buckets(TimeBuckets())
        plan.schedule = .cron("0 *")
        #expect(plan.problems.count == 3)
    }

    @Test func retentionSummary() {
        #expect(RetentionSetting.buckets(TimeBuckets(daily: 7, weekly: 4, monthly: 3)).summary == "Keeps about 3 months of history")
        #expect(RetentionSetting.buckets(TimeBuckets(hourly: 24, monthly: 24)).summary == "Keeps about 2 years of history")
        #expect(RetentionSetting.lastN(1).summary == "Keeps the last 1 snapshot")
    }
}

/// Trimmed from a live GetOperations reply: one backup flow whose forget hit
/// a stale lock, a pending future check, and a running backup.
let operationsJSON = """
{"operations":[
 {"id":"8356","flowId":"8356","repoId":"nas","planId":"home","snapshotId":"360d","status":"STATUS_SUCCESS",
  "unixTimeStartMs":"1793700000000","unixTimeEndMs":"1793700071000","logref":"t-45ff",
  "operationBackup":{"lastStatus":{"summary":{"filesNew":"77","filesChanged":"525","dataAdded":"558739545",
   "totalBytesProcessed":"86128146380","totalDuration":71.36,"snapshotId":"360d"}}}},
 {"id":"8359","flowId":"8356","repoId":"nas","planId":"home","status":"STATUS_ERROR",
  "unixTimeStartMs":"1793700072000","unixTimeEndMs":"1793700073000",
  "displayMessage":"forget: forget for repo nas: command \\"restic forget\\" failed: exit status 11\\nOutput:\\n{\\"message_type\\":\\"exit_error\\",\\"code\\":11,\\"message\\":\\"unable to create lock in backend: repository is already locked by PID 81540\\\\nlock was created at 2026-09-19\\"}\\n",
  "operationForget":{"policy":{}}},
 {"id":"8361","flowId":"8356","repoId":"nas","planId":"home","status":"STATUS_SUCCESS",
  "unixTimeStartMs":"1793700071500","operationIndexSnapshot":{}},
 {"id":"8362","flowId":"8356","repoId":"nas","planId":"home","status":"STATUS_SUCCESS",
  "unixTimeStartMs":"1793700073000","operationRunHook":{"parentOp":"8359","condition":"CONDITION_FORGET_ERROR"}},
 {"id":"8287","flowId":"8287","repoId":"nas","planId":"_system_","status":"STATUS_PENDING",
  "unixTimeStartMs":"1796468137839","operationCheck":{}},
 {"id":"8400","flowId":"8400","repoId":"nas","planId":"home","status":"STATUS_INPROGRESS",
  "unixTimeStartMs":"1793707000000","operationBackup":{"lastStatus":{"status":{"percentDone":0.42,
   "totalBytes":"1000","bytesDone":"420","currentFile":["/Users/alex/a.txt"]}}}},
 {"id":"8401","flowId":"8401","status":"STATUS_SUCCESS","unixTimeStartMs":"1793707100000","operationSomethingNew":{}},
 {"id":"8500","flowId":"8500","status":"STATUS_SUCCESS","unixTimeStartMs":"1793707150000","operationIndexSnapshot":{}},
 {"flowId":"9"}
]}
"""

@Suite struct BackrestActivityTests {
    @Test func flows() throws {
        let ops = try Activity.decode(Data(operationsJSON.utf8))
        // The id-less entry drops itself; the unknown kind is kept.
        #expect(ops.count == 8)
        let (flows, scheduled) = Activity.flows(ops, now: now)
        #expect(scheduled.map(\.id) == [8287])
        #expect(flows.map(\.id) == [8401, 8400, 8356])

        let backup = try #require(flows.last)
        #expect(backup.primary.kind == .backup)
        #expect(backup.steps.count == 4)
        #expect(backup.severity == .error)
        #expect(backup.failedSteps.map(\.kind) == [.forget])
        #expect(backup.primary.backup?.dataAdded == 558_739_545)
        #expect(backup.primary.backup?.filesChanged == 525)
        #expect(backup.failedSteps.first?.reason == "unable to create lock in backend: repository is already locked by PID 81540")

        let running = flows[1]
        #expect(running.isActive)
        #expect(running.primary.backup?.percentDone == 0.42)
        #expect(running.primary.backup?.currentFile == "/Users/alex/a.txt")
        #expect(flows[0].primary.kind == .unknown)
    }

    @Test func fatalReason() {
        #expect(Activity.reason(from: "restic failed\nFatal: unable to open repo\"}") == "unable to open repo")
        #expect(Activity.reason(from: "\n... 20 bytes truncated ...\nsomething broke") == "something broke")
        let check = """
        check: check repo nas: command "restic check" failed: exit status 11
        Output:
        using temporary cache in /var/folders/x
        create exclusive lock for repository
        unable to create lock in backend: repository is already locked by PID 83835
        the `unlock` command can be used to remove stale locks
        """
        #expect(Activity.reason(from: check) == "unable to create lock in backend: repository is already locked by PID 83835")
    }

    @Test func connectFrames() throws {
        let chunk = Data("hello ".utf8).base64EncodedString()
        let chunk2 = Data("world".utf8).base64EncodedString()
        var data = ConnectStream.envelope(Data(#"{"value":"\#(chunk)"}"#.utf8))
        data.append(ConnectStream.envelope(Data(#"{"value":"\#(chunk2)"}"#.utf8)))
        var end = ConnectStream.envelope(Data("{}".utf8))
        end[0] = 0x02
        data.append(end)
        let log = ConnectStream.logText(data)
        #expect(log.text == "hello world")
        #expect(log.error == nil)

        var failed = ConnectStream.envelope(Data(#"{"error":{"code":"not_found","message":"no such log"}}"#.utf8))
        failed[0] = 0x02
        #expect(ConnectStream.decode(failed).error == "no such log")
        #expect(ConnectStream.decode(Data([0, 0, 0, 0, 9, 1])).error != nil)
    }
}

@Suite struct BackrestWindowExtrasTests {
    @Test func coverageSkipsShadowedBuckets() {
        let c = TimeBuckets(hourly: 24, daily: 30, weekly: 52, monthly: 24).coverage
        #expect(c.map(\.label) == ["24 hourly", "30 daily", "52 weekly", "24 monthly"])
        #expect(c[0].from == 0 && c[0].to == 86400)
        #expect(c[1].from == 86400)
        // 48 hourly reaches 2 days; 1 daily reaches only 1, so it adds nothing.
        #expect(TimeBuckets(hourly: 48, daily: 1).coverage.map(\.label) == ["48 hourly"])
        #expect(TimeBuckets().coverage.isEmpty)
    }

    @Test func daysAndLastRuns() throws {
        let ops = try Activity.decode(Data(operationsJSON.utf8))
        let flows = Activity.flows(ops, now: now).flows
        let days = Activity.byDay(flows)
        #expect(days.flatMap(\.flows).count == flows.count)
        #expect(days == days.sorted { $0.day > $1.day })
        #expect(Activity.lastFinished(.forget, in: flows)?.id == 8359)
        #expect(Activity.lastFinished(.check, in: flows) == nil)
        #expect(days.first?.title(now: days.first!.day) == "Today")
    }
}
