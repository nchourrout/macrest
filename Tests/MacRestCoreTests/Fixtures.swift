import Foundation
@testable import MacRestCore

// Shared fixtures: a fixed clock, a UTC calendar, oplog entries and a config.

/// Fixed clock: 2026-11-03 12:00:00 UTC.
let now = Date(timeIntervalSince1970: 1_793_707_200)

let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// One oplog entry as Backrest returns it; `payload` is the kind's object.
func op(_ id: Int, _ kind: String, _ status: String, hoursAgo: Double, flow: Int? = nil, message: String? = nil,
        payload: String = "{}") -> String {
    let start = Int64((now.timeIntervalSince1970 - hoursAgo * 3600) * 1000)
    let msg = message.map { #","displayMessage":\#(String(decoding: try! JSONEncoder().encode($0), as: UTF8.self))"# } ?? ""
    return #"{"id":"\#(id)","flowId":"\#(flow ?? id)","status":"\#(status)","unixTimeStartMs":"\#(start)","unixTimeEndMs":"\#(start + 60000)"\#(msg),"\#(kind)":\#(payload)}"#
}

/// Raw entries, wrapped and decoded the way `GetOperations` comes back.
func decodeOps(_ ops: [String]) throws -> [BackrestOperation] {
    try Activity.decode(Data(#"{"operations":[\#(ops.joined(separator: ","))]}"#.utf8))
}

func overview(_ ops: [String], unlockedAt: Date? = nil) throws -> Overview {
    let (flows, scheduled) = Activity.flows(try decodeOps(ops), now: now)
    return Overview.make(flows: flows, scheduled: scheduled, now: now, unlockedAt: unlockedAt, calendar: utc)
}

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

