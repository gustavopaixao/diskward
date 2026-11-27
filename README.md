# Storage Helper

A native macOS app that scans your Mac for space you can safely reclaim and cleans it up.

| Area | What it finds |
|---|---|
| **System** | App caches (`~/Library/Caches`), logs, Trash, large or old files in Downloads |
| **Xcode** | DerivedData, Archives, Device Support, Simulators, Simulator Runtimes |
| **Containers & CI** | Docker images, stopped containers, unused volumes, build cache; Jenkins workspaces and old builds |
| **Package managers** | Homebrew, npm, Yarn, pnpm, Bun, pip, uv, Poetry, Gradle, Maven, CocoaPods, SwiftPM, Carthage, Go |
| **Projects** | `node_modules` folders in your project folders (configurable in Settings) |
| **Disk Explorer** | Drill-down of the biggest folders in your home folder, any folder, or the whole disk |

Sections for tools you don't have (for example Jenkins) are hidden automatically.

## Run it

You need Xcode (or its command-line tools) on macOS 14 or later.

```bash
scripts/build-app.sh                       # builds "build/Storage Helper.app"
open "build/Storage Helper.app"
cp -R "build/Storage Helper.app" /Applications/   # optional
```

Other ways to run it:

- **Development:** run `open Package.swift`, which opens the project in Xcode. Pick the `StorageHelper` scheme and press ⌘R.
- **Quick text report, no UI (never deletes anything):** run `swift run storage-report`.

### Full Disk Access

macOS hides the Trash and some caches from apps unless you grant Full Disk Access. Without it, the numbers will be too low. Grant it in **System Settings → Privacy & Security → Full Disk Access**: turn on Storage Helper, then click **Scan**. The app shows a banner with a button to open that settings pane.

Full Disk Access is tied to the app's code signature. The build script signs ad-hoc by default, and macOS may then forget the permission after each rebuild. To avoid that, sign with your own certificate:

```bash
security find-identity -v -p codesigning
SIGN_IDENTITY="Apple Development: …" scripts/build-app.sh
```

## How cleaning works (safety)

- **Pre-selection:** only items marked safe are pre-selected. *Caution* items (archives, simulators, Maven repo, Docker volumes) and *Review* items (Downloads) must be ticked by hand.
- **Confirmation:** nothing is deleted without a confirmation sheet. It lists every item, its size, and the exact command for tool-based cleanups.
- **Files go to the Trash,** so you can undo. Moved files still use space until the Trash is emptied. The sheet has an *"Empty the Trash afterwards"* option, and the result shows the real change in free space.
- **Tool cleanups** use the tool's own command, and those deletions are permanent:
  - Docker: `docker image rm`, `container prune`, `volume prune`, `builder prune`
  - Simulators: `xcrun simctl delete` / `simctl runtime delete`
  - Homebrew: `brew cleanup --prune=all`
  - pnpm: `pnpm store prune`
- **Safety guard:** every path is checked by `SafetyGuard` right before deletion. It must be inside your home folder and not a protected folder such as `~/Documents`, `~/Library` itself, `~/.ssh`, Keychains or iCloud Drive. Symlinks can't redirect a delete outside it.
- **Running apps:** you get a warning if a related app is running (Xcode, Simulator).
- **Log:** every action is written to `~/Library/Logs/StorageHelper/cleanup.log`.

## Project layout

```
Package.swift
Sources/
  StorageCore/          scanning and cleaning logic (no UI, unit-tested)
    Model/              CleanupItem, CleanupProvider protocol, categories
    Scanning/           SizeCalculator (fts, allocated size), ShellRunner, DiskInfo
    Providers/          one provider per source; ProviderRegistry lists them all
    Cleaning/           Cleaner, SafetyGuard, CleanupLog
  StorageHelper/        SwiftUI app (Overview, per-provider tables, Disk Explorer)
  storage-report/       read-only CLI report
Tests/StorageCoreTests/ unit tests plus JSON fixtures for simctl and docker output
scripts/build-app.sh    builds and signs the .app bundle
```

### Adding a new cleanup source

1. Create a type conforming to `CleanupProvider` in `Sources/StorageCore/Providers/`. For plain cache folders, add a `KnownPathsProvider` factory instead.
2. Register it in `ProviderRegistry.all()`.
3. Add a test in `Tests/StorageCoreTests`.

```bash
swift test
```

## Notes

- **Sizes** are bytes actually allocated on disk. APFS clones are counted in full, so a few totals can be slightly higher than what is freed.
- **Docker Desktop** stores everything in one disk image. Pruning frees space inside it right away, but macOS sees the image shrink later.
- **pnpm:** projects hard-link into the pnpm store, so `pnpm store prune` frees less than the store's total size.
