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
        let pw = SetupDefaults.password()
        #expect(pw.count == 32)
        #expect(!pw.contains("l") && !pw.contains("0") && !pw.contains("O"))
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
        #expect(p.retention == .buckets(TimeBuckets(hourly: 24, daily: 30, weekly: 52, monthly: 24)))
        #expect(r.checkMode == .readData(percent: 5))
    }
}
