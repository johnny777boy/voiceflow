# VoiceFlow — Merge Instructions (owner-run)

Per the specification, the branch is **never merged or pushed automatically**.
These are the exact steps for you to run **after** internal verification passes
(done — see `VERIFICATION.md`) and Codex external verification passes.

**Branch:** `feature/system-dictation-daily-use`
**Base:** `main`
**Repo root (main worktree):** `/Users/yoni/Documents/projects/VoiceFlow`
**Feature worktree:** `/Users/yoni/Documents/projects/VoiceFlow/.worktrees/feature-system-dictation-daily-use`

---

## 0. Pre-merge gate

- [x] Internal verification passes (`swift build` clean, `swift run VoiceFlowTests` → 78/78).
- [ ] Codex external verification passes (hand it `docs/CODEX_VERIFICATION_PACKAGE.md`; fix any findings in the worktree; re-run verification until clean).
- [ ] You approve.

## 1. Final smoke test (from the feature worktree)

```bash
cd /Users/yoni/Documents/projects/VoiceFlow/.worktrees/feature-system-dictation-daily-use
swift build && swift run VoiceFlowTests
```

Expect `Build complete!` (0 warnings) and `✓ All 78 tests passed.`

Optionally build and launch the app once:

```bash
./Scripts/build_app.sh release
open dist/VoiceFlow.app   # grant Mic / Speech / Accessibility when prompted
```

## 2. Merge into main

Run from the **main worktree** (the repo root), not the feature worktree:

```bash
cd /Users/yoni/Documents/projects/VoiceFlow
git checkout main                     # ensure you're on main
git merge --no-ff feature/system-dictation-daily-use \
  -m "Merge feature/system-dictation-daily-use: VoiceFlow dictation app"
```

`--no-ff` keeps the feature history as a visible merge commit. There should be
**no conflicts** (main only has the baseline README/.gitignore; the branch adds
new files and updates the README).

## 3. Post-merge verification on main

```bash
cd /Users/yoni/Documents/projects/VoiceFlow
swift build && swift run VoiceFlowTests
```

Same expected output as step 1.

## 4. Push

This repo currently has **no configured remote** (it was `git init`-ed locally).
Add one first, then push:

```bash
# If/when you have a remote (example — replace with your URL):
git remote add origin <your-remote-url>
git push -u origin main
```

If you don't intend to push anywhere, you can stop after step 3 — the merge is
complete locally.

## 5. Clean up the worktree (optional)

Once merged, the feature worktree can be removed:

```bash
cd /Users/yoni/Documents/projects/VoiceFlow
git worktree remove .worktrees/feature-system-dictation-daily-use
git branch -d feature/system-dictation-daily-use
```

> Note: `.worktrees/` is gitignored, so the worktree directory is never itself
> committed to `main`.

---

### Summary of what merges into `main`

- Swift package: `VoiceFlowCore`, `VoiceFlowApp`, `VoiceFlowTests`, `VoiceFlowTestKit`.
- Full domain logic + macOS platform layer + SwiftUI menu-bar UI.
- `bundle/` (Info.plist, entitlements) and `Scripts/build_app.sh`.
- `docs/` (architecture, verification, Codex package, these instructions).
- 78 passing tests; 0 build warnings under Swift 6 strict concurrency.
