## What does this change?

<!-- A short description, and the issue it fixes (e.g. "Fixes #12"). -->

## Checklist

- [ ] `swift test` passes
- [ ] Tested in the app (`scripts/build-app.sh`, then open `build/Diskward.app`)
- [ ] Anything that deletes files goes through `SafetyGuard` and the confirmation sheet
- [ ] New or changed cleanup sources have tests in `Tests/StorageCoreTests`
- [ ] Screenshots for UI changes
