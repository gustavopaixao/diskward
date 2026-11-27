# Diskward

*Your disk, under control.*

A native macOS app that scans your Mac for space you can safely reclaim and cleans it up.

| Area | What it finds |
|---|---|
| **System** | App caches, logs, Trash, large or old Downloads, iPhone/iPad backups, local Time Machine snapshots, Mail and Messages attachments (instructions only) |
| **Xcode** | DerivedData, Archives, Device Support, Simulators, Simulator Runtimes, SwiftUI Previews, simulator caches, other Xcode installs (instructions only) |
| **Containers & CI** | Docker (tabs for containers, images, volumes and build cache, each split into unused and in use), Jenkins workspaces and old builds |
| **Package managers** | Homebrew, npm, Yarn, pnpm, Bun, pip, uv, Poetry, Gradle, Maven, CocoaPods, SwiftPM, Carthage, Go |
| **Developer tools** | Android emulators and system images; Playwright browser versions; AI models (Ollama, Hugging Face, LM Studio); VS Code, Cursor and Windsurf caches and old extension versions; JetBrains caches per IDE version |
| **Projects** | `node_modules` folders in your project folders (configurable in Settings) |

The app also includes:

- **Overview:** shows where your disk space is (reclaimable, other used, free) and what changed since the last scan.
- **What Changed:** every full scan is saved, so you can see which sources and items grew since the previous scan, or since 1 day, 1 week or 1 month ago. A chart shows free space over time.
- **Cleanup Rules:** saved rules such as "DerivedData older than 14 days", "stopped Docker containers" or "keep the newest 3 archives per app". Click **Apply Rules** to review everything they match, then clean.
- **Menu bar:** shows free space, warns you when it drops below a limit (30 GB by default), runs a scan once a day, and can open at login.
- **Disk Explorer:** drill down into the biggest folders in your home folder, any folder, or the whole disk.

Sections for tools you don't have (for example Jenkins) are hidden automatically.

## Run it

You need Xcode (or its command-line tools) on macOS 14 or later.

```bash
scripts/build-app.sh                       # builds "build/Diskward.app"
open "build/Diskward.app"
cp -R "build/Diskward.app" /Applications/   # optional
```

Other ways to run it:

- **Development:** run `open Package.swift`, which opens the project in Xcode. Pick the `StorageHelper` scheme and press ⌘R.
- **Quick text report, no UI (never deletes anything):** run `swift run storage-report`.

### Full Disk Access

macOS hides the Trash and some caches from apps unless you grant Full Disk Access. Without it, the numbers will be too low. Grant it in **System Settings → Privacy & Security → Full Disk Access**: turn on Diskward, then click **Scan**. The app shows a banner with a button to open that settings pane.

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
- **Manual items:** items the app should not delete itself (Mail, Messages, other Xcode installs) are listed with instructions. They can't be selected.
- **Log:** every action is written to `~/Library/Logs/StorageHelper/cleanup.log`.
- **Scan history:** stored in `~/Library/Application Support/StorageHelper/history.json`.

## Project layout

```
Package.swift
Sources/
  StorageCore/          scanning and cleaning logic (no UI, unit-tested)
    Model/              CleanupItem, CleanupProvider protocol, categories
    Scanning/           SizeCalculator (fts, allocated size), ShellRunner, DiskInfo
    Providers/          one provider per source; ProviderRegistry lists them all
    Cleaning/           Cleaner, SafetyGuard, CleanupLog
    History/            ScanHistory (snapshots and growth)
    Rules/              CleanupRule and RuleEngine
  StorageHelper/        SwiftUI app (Overview, What Changed, Rules, provider tables, Disk Explorer, menu bar)
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

## Branding

- **Source assets:** the approved originals are in `materials/` and are never edited. `Resources/Assets.xcassets` holds byte-identical copies of `AppIcon.appiconset` and `DiskwardMenuBar.imageset`, plus an `AccentColor` set.
- **How they get into the app:** `scripts/build-app.sh` compiles the catalog with `actool` into `Assets.car` and `AppIcon.icns`. Info.plist points to them through `CFBundleIconName`, `CFBundleIconFile` and `NSAccentColorName`.
- **Menu bar glyph:** loaded with `Brand.menuBarImage` as a template image, so macOS handles light mode, dark mode and the highlighted state.
- **Colors:** tokens live in `Sources/StorageHelper/Design/Brand.swift`. Views use the semantic names, not raw hex values:

| Token | Use | Light | Dark |
|---|---|---|---|
| `DS.tint` | Buttons, toggles, progress (matches AccentColor) | `#0B6E7A` | `#0D7F8C` |
| `DS.reclaimable` | Reclaimable bars and large numbers | `#059669` | `#34D399` |
| `DS.reclaimableText` | Reclaimable small text | `#047857` | `#34D399` |
| `DS.review` | Caution, Review, warnings, growth | `#B45309` | `#FBBF24` |
| `DS.critical` | Failures, irreversible deletes, disk almost full | system red | system red |
| `DS.otherUsed` | Used space that isn't reclaimable | `#0F2D4A` | `#8FA3B8` |

  The dark-mode variants were chosen to meet contrast targets against standard macOS backgrounds: at least 4.5:1 for text and at least 3:1 for shapes. Everything else uses native macOS colors.
- **Typography:** SF Pro (system font), SF Mono (`Font.technical`) for paths and commands, and monospaced digits for sizes.

## Notes

- **Sizes** are bytes actually allocated on disk. APFS clones are counted in full, so a few totals can be slightly higher than what is freed.
- **Docker Desktop** stores everything in one disk image. Pruning frees space inside it right away, but macOS sees the image shrink later.
- **pnpm:** projects hard-link into the pnpm store, so `pnpm store prune` frees less than the store's total size.
