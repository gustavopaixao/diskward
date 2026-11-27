# Contributing to Diskward

Thanks for helping! Bug reports, ideas for new cleanup sources and pull requests are all welcome. Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Setup

You need macOS 14 or later and Xcode (the project builds with Xcode 27 / Swift 6.4).

```bash
git clone https://github.com/gustavopaixao/diskward.git
cd diskward
swift test                  # unit tests
scripts/build-app.sh        # builds build/Diskward.app
open build/Diskward.app
```

You can also run `open Package.swift` to work in Xcode, or `swift run storage-report` for a text-only scan that never deletes anything.

## Project layout

- `Sources/StorageCore`: all scanning and cleaning logic, with no UI. Most changes go here.
- `Sources/StorageHelper`: the SwiftUI app. The internal name predates the Diskward brand.
- `Tests/StorageCoreTests`: unit tests and JSON/text fixtures for tool output.

## Adding a cleanup source

1. Create a type conforming to `CleanupProvider` in `Sources/StorageCore/Providers/`. For plain cache folders, a `KnownPathsProvider` factory is usually enough.
2. Register it in `ProviderRegistry.all()`.
3. Add tests that use a temporary home folder (see `TempHome` in the tests). Never touch real user files in tests.

## Safety rules (please read)

Diskward deletes files, so these rules apply to every change:

- **`SafetyGuard`:** every path passes through it right before deletion. Never bypass it.
- **Confirmation sheet:** nothing is deleted without it.
- **Trash first:** prefer moving to the Trash. Use a tool's own command (`docker`, `simctl`, `brew`…) when files shouldn't be removed directly.
- **Pre-selection:** only items that are regenerated automatically may be `.safe` (pre-selected). Anything with history or user data is `.caution` or `.review`.
- **Manual items:** if deleting something directly would break another app (Mail, Messages), make it a `.manual` item with instructions.

## Pull requests

`main` is protected: every change goes through a pull request, CI ("Build & test") must pass, and the branch is squash-merged. For a first-time contributor, a maintainer approves the CI run before it starts.

- Keep each pull request focused on one change.
- Run `swift test` before pushing. CI runs it too.
- Include screenshots for UI changes.
- Describe how you tested it.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
