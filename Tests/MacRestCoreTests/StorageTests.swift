import Foundation
import Testing
@testable import MacRestCore

@Suite struct StorageTests {
    @Test func disk() {
        var f = StorageForm(kind: .disk)
        #expect(f.missing != nil)
        f.folder = "/Volumes/Backup/MacRest"
        #expect(f.uri == "/Volumes/Backup/MacRest")
        #expect(f.env.isEmpty && f.flags.isEmpty && f.missing == nil)
    }

    @Test func sftp() {
        var f = StorageForm(kind: .sftp)
        f.host = "nas.local"
        f.remotePath = "/backups/mac"
        #expect(f.uri == "sftp:nas.local:/backups/mac")
        #expect(f.flags.isEmpty)
        f.user = "me"
        f.port = "2222"
        #expect(f.uri == "sftp:me@nas.local:/backups/mac")
        #expect(f.flags == ["--option=sftp.args='-oBatchMode=yes -p 2222'"])
        f.sshAuth = .dedicated
        #expect(f.missing == "Create the key for MacRest first.")
        f.identityFile = "/k/id_ed25519"
        f.knownHostsFile = "/k/known_hosts"
        #expect(f.flags == ["--option=sftp.args='-oBatchMode=yes -i /k/id_ed25519 -p 2222 -oUserKnownHostsFile=/k/known_hosts'"])
        #expect(f.copyKeyCommand == "ssh-copy-id -i '/k/id_ed25519.pub' -p 2222 me@nas.local")
    }

    @Test func s3KeepsCredentialsOutOfTheURI() {
        var f = StorageForm(kind: .s3)
        f.bucket = "my-bucket"
        f.prefix = "/mac/"
        f.accessKey = "AKIA"
        f.secretKey = "s3cr3t"
        #expect(f.uri == "s3:https://s3.amazonaws.com/my-bucket/mac")
        f.endpoint = "https://acct.r2.cloudflarestorage.com/"
        f.region = "auto"
        #expect(f.uri == "s3:https://acct.r2.cloudflarestorage.com/my-bucket/mac")
        #expect(f.env == ["AWS_ACCESS_KEY_ID=AKIA", "AWS_SECRET_ACCESS_KEY=s3cr3t", "AWS_DEFAULT_REGION=auto"])
        #expect(!f.uri.contains("s3cr3t"))
    }

    @Test func b2RestOther() {
        var b = StorageForm(kind: .b2)
        b.bucket = "bk"
        b.prefix = "mac"
        b.b2KeyID = "id"
        b.b2AppKey = "key"
        #expect(b.uri == "b2:bk:mac")
        #expect(b.env == ["B2_ACCOUNT_ID=id", "B2_ACCOUNT_KEY=key"])

        var r = StorageForm(kind: .rest)
        r.restURL = "backup.example.com:8000/mac"
        r.restUser = "me"
        r.restPassword = "pw"
        #expect(r.uri == "rest:https://backup.example.com:8000/mac")
        #expect(r.env == ["RESTIC_REST_USERNAME=me", "RESTIC_REST_PASSWORD=pw"])

        var o = StorageForm(kind: .other)
        o.rawURI = "azure:container:/mac"
        o.rawEnv = "AZURE_ACCOUNT_NAME=x\n\nAZURE_ACCOUNT_KEY=y\nnot a pair"
        #expect(o.env == ["AZURE_ACCOUNT_NAME=x", "AZURE_ACCOUNT_KEY=y"])
    }

    @Test func credentialLabels() {
        #expect(Credential.label("AWS_SECRET_ACCESS_KEY") == "Secret access key")
        #expect(Credential.isSecret("AWS_SECRET_ACCESS_KEY"))
        #expect(!Credential.isSecret("AWS_ACCESS_KEY_ID"))
        #expect(Credential.split("A=b=c") == (key: "A", value: "b=c"))
    }
}
