import Foundation
import Testing
@testable import MacRestCore

@Suite struct EngineTests {
    @Test func releaseIsPinnedWithChecksums() {
        #expect(BackrestRelease.url(arch: "arm64").absoluteString
                == "https://github.com/garethgeorge/backrest/releases/download/v1.14.1/backrest_Darwin_arm64.tar.gz")
        #expect(BackrestRelease.checksum(arch: "arm64")?.count == 64)
        #expect(BackrestRelease.checksum(arch: "x86_64")?.count == 64)
    }

    @Test func agentKeepsHomebrewsFolders() throws {
        let paths = EngineAgent.Paths(home: "/Users/x", support: "/Users/x/Library/Application Support/MacRest")
        #expect(paths.config == "/Users/x/.config/backrest/config.json")
        #expect(paths.data == "/Users/x/.local/share/backrest")
        let data = try EngineAgent.plistData(paths)
        let back = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(back["Label"] as? String == "com.nchourrout.macrest.backrest")
        #expect((back["EnvironmentVariables"] as? [String: String])?["BACKREST_PORT"] == "127.0.0.1:9898")
        #expect((back["AssociatedBundleIdentifiers"] as? [String]) == ["com.nchourrout.macrest"])
        let env = try #require(back["EnvironmentVariables"] as? [String: String])
        #expect(env["BACKREST_RESTIC_COMMAND"] == "/Users/x/.local/share/backrest/restic")
        #expect(env["PATH"]?.contains("homebrew") == false)
        #expect(back["ProcessType"] as? String == "Standard")
    }

    @Test func setupDefaults() {
        let ex = SetupDefaults.excludes(home: "/Users/x")
        #expect(ex.contains("/Users/x/Library/Caches"))
        #expect(ex.contains("**/node_modules"))
        #expect(SetupDefaults.instanceID(from: "Alex's MacBook Pro") == "alex-s-macbook-pro")
        #expect(SetupDefaults.instanceID(from: "--") == "mac")
        // Accents fold to ASCII: the id goes into tags and file names.
        #expect(SetupDefaults.instanceID(from: "Hélène’s MacBook") == "helene-s-macbook")
        #expect(SetupDefaults.instanceID(from: "Mac de José") == "mac-de-jose")
        #expect(SetupDefaults.instanceID(from: "Bjørn’s MacBook") == "bjorn-s-macbook")
        #expect(SetupDefaults.instanceID(from: "Łukasz Mac") == "lukasz-mac")
        let japanese = SetupDefaults.instanceID(from: "山田のMac")
        #expect(japanese.allSatisfy(\.isASCII) && japanese != "mac" && japanese.hasSuffix("mac"))
    }

    @Test func startNeedsAPasswordAndAName() {
        #expect(SetupDefaults.startBlocker(password: "", existing: false, instance: "mac") == "Enter the password.")
        #expect(SetupDefaults.startBlocker(password: "short", existing: false, instance: "mac") == "The password needs at least 8 characters.")
        // An existing storage's password is whatever it is.
        #expect(SetupDefaults.startBlocker(password: "short", existing: true, instance: "mac") == nil)
        #expect(SetupDefaults.startBlocker(password: "long enough", existing: false, instance: "") == "Enter a name for this Mac.")
        #expect(SetupDefaults.startBlocker(password: "long enough", existing: false, instance: nil) == nil)
    }

    @Test func setupJSON() throws {
        let repo = SetupDefaults.repo(id: "main", uri: "sftp:nas:/r", password: "pw", autoUnlock: true)
        #expect(repo["autoUnlock"]?.bool == true)
        #expect(repo["checkPolicy"]?["readDataSubsetPercent"]?.number == 5)
        let plan = SetupDefaults.plan(id: "home", repo: "main", paths: ["/Users/x"], excludes: ["a"], everyHours: 1)
        let config = JSONValue.object(["repos": .array([repo]), "plans": .array([plan]), "instance": .string("mac")])
        #expect(!SetupDefaults.needsSetup(config))
        #expect(SetupDefaults.needsSetup(.object(["repos": .array([])])))
        // Read back by the settings editor without loss.
        let (p, r) = try #require(BackrestConfig.read(config))
        #expect(p.retention == .buckets(.timeMachine))
        #expect(r.checkMode == .readData(percent: 5))
    }

    /// The exact JSON a setup sends, byte for byte: AddRepo rejects
    /// `autoInitialize`, and the schedules and retention are the defaults
    /// the README promises.
    @Test func setupJSONIsPinned() throws {
        let repo = SetupDefaults.repo(id: "main", uri: "s3:h/b", password: "pw", env: ["AWS_ACCESS_KEY_ID=k"],
                                      flags: ["-o", "x"], autoUnlock: false)
        #expect(repo["autoInitialize"] == nil)
        let repoText = String(decoding: try sortedJSON(repo), as: UTF8.self)
        #expect(repoText == #"{"autoUnlock":false,"checkPolicy":{"readDataSubsetPercent":5,"schedule":{"clock":"CLOCK_LAST_RUN_TIME","maxFrequencyDays":30}},"env":["AWS_ACCESS_KEY_ID=k"],"flags":["-o","x"],"id":"main","password":"pw","prunePolicy":{"maxUnusedPercent":10,"schedule":{"clock":"CLOCK_LAST_RUN_TIME","maxFrequencyDays":7}},"uri":"s3:h\/b"}"#)
        let plan = SetupDefaults.plan(id: "home", repo: "main", paths: ["/Users/x"], excludes: ["a"], everyHours: 2)
        let planText = String(decoding: try sortedJSON(plan), as: UTF8.self)
        #expect(planText == #"{"backup_flags":["--exclude-caches"],"excludes":["a"],"id":"home","paths":["\/Users\/x"],"repo":"main","retention":{"policyTimeBucketed":{"daily":30,"hourly":24,"monthly":24,"weekly":52}},"schedule":{"clock":"CLOCK_LAST_RUN_TIME","maxFrequencyHours":2}}"#)
    }

    @Test func passwordAvoidsLookAlikes() {
        // Every character of many passwords, so one look-alike slipping back
        // in is caught rather than sampled.
        let used = Set((0..<200).flatMap { _ in SetupDefaults.password() })
        #expect(used.isSubset(of: Set("abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")))
        #expect(SetupDefaults.password().count == 32)
    }
}

func sortedJSON(_ v: JSONValue) throws -> Data {
    let e = JSONEncoder()
    e.outputFormatting = .sortedKeys
    return try e.encode(v)
}
