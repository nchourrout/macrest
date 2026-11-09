# MacRest

Native SwiftUI front end for Backrest (restic). Replaces Backrest's web UI; Backrest keeps running as the engine (scheduling, retention, prune and check cadence, hooks), and MacRest is a client of the same local Connect API on `localhost:9898` that the web UI calls (`BackrestClient.swift`). Split out of MacStatus on purpose: MacStatus keeps its backup health card and badge, and a click on that card launches MacRest.

## Working on it

```bash
swift build && swift test
# a bare .build binary is not an app bundle; run a built bundle:
./build-app.sh /tmp/MacRest.app && /tmp/MacRest.app/Contents/MacOS/MacRest --window browse
/tmp/MacRest.app/Contents/MacOS/MacRest --render /tmp/render   # the menu bar panel to PNGs, light and dark
```

`--window [activity|browse|schedule|folders|repository]` opens the window on that pane at launch. Deploying is mac-config's job (`ansible-playbook playbook.yml --tags macrest -e ansible_become_password=`): it clones this repo once to `~/dev/macrest`, never pulls, and builds the local tree with `build-app.sh` into `~/Applications/MacRest.app`. The script stamps a hash of its sources into the bundle and prints `unchanged` when nothing changed.

**Command Line Tools only, no Xcode**: `@State` is a macro on the macOS 27 SDK whose plugin ships only with Xcode, so views use `@ViewState` (a typealias, in `Theme.swift`) and there is no `#Preview`. `swift test` sometimes fails its first compile with "plugin for module 'TestingMacros' not found" and passes when run again on the same `.build`.

`MacRestCore` holds the decoding, the config editing and the verdict, with no AppKit and no I/O, all under `swift test`. `MacRest` holds the client, the model and the UI.

## Design

**The menu bar icon is optional** (`showsMenuBarItem` in defaults, the toggle in the window's `…` menu). With it, MacRest is a menu bar app (`LSUIElement`), takes a Dock icon only while its window is open, and a login launch stays silent. Without it, MacRest is an ordinary Dock app: the window opens at launch and closing it quits, since nothing else would be left to reach it by and it sends no notifications (MacStatus does that). `AppDelegate.updateActivationPolicy` is the one place that decides.

**One `AppModel` for the app's lifetime**, because the icon needs the verdict whether or not the window is open. It polls Backrest's oplog every 60 s with only the icon, every 15 s while the window is open, every 2 s while something runs or was just started. `Overview` is the verdict: the last backup, staleness past 36 h, the failure and warning share over 14 days (one column per day), and maintenance. **Retention, prune and check failing raise it to a warning on their own** even while every backup succeeds: a stale lock fails all three (they need an exclusive lock, backups a shared one), and that went unnoticed for weeks behind a green backup status. The Activity pane and the panel both carry an Unlock for it (`DoRepoTask TASK_UNLOCK` = `restic unlock`, which removes only locks restic judges stale).

**The config is edited as raw JSON** (`JSONValue`), never round-tripped through typed structs: `SetConfig` replaces the whole document, so a typed round trip would drop the repo password, guid, hooks, auth and sync identity, and Backrest would save the loss. `BackrestConfig.applied` touches only the keys it edits and keeps `modno`, so a save against a config that changed meanwhile is rejected rather than overwriting it; the model then reloads the baseline and keeps the edits. A no-op save was checked against the live Backrest to leave `config.json` identical apart from `modno`. Note that mac-config deploys Backrest's config once (`force: false`) and Backrest owns it afterwards, so settings saved here are the live ones and the template is only a fresh machine's starting point.

**Activity** groups the oplog into flows (a backup with the index, forget and hooks that ran with it); a row is coloured by its own outcome, and a step that failed alongside it (retention after a good backup) is a tag, not a red row. **Browse** keeps the folder when the snapshot changes, so stepping through the timeline shows the same place at other moments, as Time Machine does; listings are cached per snapshot and folder, since each one is a restic call over SFTP (~3 s cold). **Restore** goes through Backrest's `Restore`, which runs `restic restore <snap>:<dir> --include /<name> --target <target>` and refuses a target that exists. The default target is a new folder beside the original, `<name> (from <date>)`, so nothing is ever overwritten; "Choose Location…" puts that folder elsewhere. The restore shows in Activity like any operation, and the Browse footer follows it to a Show in Finder.

`GetLogs` is a Connect server stream, framed per `ConnectStream`. Backrest's API has no auth here (`auth.disabled` in the mac-config template), and `GetConfig` returns the repo password in clear: any local process can read it, with or without MacRest.

Not built yet: a per-file version history (one listing per snapshot is too slow with hundreds of snapshots; it would need a local index from `restic diff`), Quick Look previews (`restic dump`), a Finder right-click entry, and backing up from an APFS snapshot for consistency.
