# MacRest

A native SwiftUI front end and installer for [Backrest](https://github.com/garethgeorge/backrest), the restic scheduler. Install MacRest and it downloads and runs Backrest itself, then sets up a backup in one screen. It gives you an optional menu bar icon with the backup verdict, Back Up Now and Restore, and a window for activity, browsing and restoring snapshots, and the plan's settings. Backrest stays the engine; MacRest talks to its local API, so the web UI never needs opening.

Built from source with the Command Line Tools, no Xcode. Installed by [mac-config](https://github.com/nchourrout/mac-config). See `CLAUDE.md` for the design.
