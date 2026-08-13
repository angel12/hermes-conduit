# PR #46 Session-Cache Salvage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Update PR #46 onto current `main` while retaining only its session-catalog cache invalidation behavior.

**Architecture:** Use a non-rewriting merge of current `origin/main` into the contributor-owned PR branch. Current `main` remains authoritative for the already-merged stream, WebSocket, WebKit, rendering-cache, and image-fallback code; PR #46 contributes only its AppState cache purge logic. The existing AppState caches are private and have no suitable integration seam, so verification will rely on the effective diff plus the full iOS test suite rather than adding test-only production hooks.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, XcodeGen, Xcode 26.5, iOS Simulator.

## Global Constraints

- Do not rewrite or force-push the contributor-owned PR branch.
- Preserve current `main` implementations for all behavior already merged through PR #45.
- Keep the session cache purge attached to successful delete/archive paths and explicit disconnect.
- Do not add a production-only test hook solely to expose private AppState caches.
- Run the generated-project full test suite before publishing the branch.

---

### Task 1: Merge current main into the PR branch

**Files:**
- Modify: Git history on `codex/pr46-session-cache-invalidation`.
- Preserve: `Conduit/Services/AppState.swift` cache invalidation from commit `313a26d`.

**Interfaces:**
- Consumes: `origin/main` at the current PR #45 merge commit.
- Produces: A merge commit whose first parent is current `origin/main` and whose effective PR diff contains the cache invalidation plus the approved design/plan documents.

- [ ] **Step 1: Confirm the worktree is clean and the source refs are current**

Run:

```bash
git status --short --branch
git rev-parse origin/main
git rev-parse HEAD
```

Expected: only committed salvage documentation is present; `origin/main` is
`725610341c75bab7acf84e2de7f4dcc9549aa24d` or a newer fetched `main` commit.

- [ ] **Step 2: Merge current main without rewriting history**

Run:

```bash
git merge origin/main --no-edit
```

If a conflict occurs, keep current `origin/main` for the already-merged
stability code and reapply only these PR #46 behaviors in `AppState.swift`:

```swift
cronSessions = []
profileSessionCache.removeAll()
loadedFullSessionHistory.removeAll()
```

and the cache-row removal in `removeSessionFromLiveCatalog`:

```swift
for key in profileSessionCache.keys {
    profileSessionCache[key]?.removeAll { sessionMatches($0, session) }
}
```

- [ ] **Step 3: Confirm the effective diff is reduced to the intended scope**

Run:

```bash
git diff --name-status origin/main...HEAD
git diff origin/main...HEAD -- Conduit/Services/AppState.swift
```

Expected: no stale PR #46 replacements of the current deduplication, bridge,
WebSocket, cache, or image-fallback implementations; only the cache purge and
the committed salvage documentation remain different from `main`.

- [ ] **Step 4: Commit any conflict resolution**

Run:

```bash
git status --short
git commit -m "Merge current main into PR46 salvage"
```

Skip the commit command when `git merge` already created the merge commit.

### Task 2: Verify the cache behavior without adding test-only hooks

**Files:**
- Inspect: `Conduit/Services/AppState.swift` around `disconnect()` and `removeSessionFromLiveCatalog()`.
- Inspect: `ConduitTests/` existing AppState and session-catalog tests.

**Interfaces:**
- Consumes: The reduced effective diff from Task 1.
- Produces: A verified decision that the private cache behavior is covered by existing integration paths, or a narrowly scoped test only if an existing seam can exercise it without exposing private state.

- [ ] **Step 1: Check existing test seams before adding coverage**

Run:

```bash
rg -n -C 8 "profileSessionCache|loadedFullSessionHistory|removeSessionFromLiveCatalog|disconnect\(" ConduitTests Conduit/Services/AppState.swift
```

Expected: do not change production visibility merely to inspect private cache
storage. If no existing seam can observe cache reuse after delete/archive or
disconnect/re-sign-in, record that no focused test is added and rely on the
full suite for regression protection.

- [ ] **Step 2: Check the reduced diff for accidental behavior changes**

Run:

```bash
git diff --check
git diff --stat origin/main...HEAD
```

Expected: no whitespace errors and no files outside the approved AppState and
salvage-document scope.

### Task 3: Run full verification

**Files:**
- Generate: ignored `Conduit.xcodeproj` from `project.yml`.
- Test: all targets in the `Conduit` scheme.

**Interfaces:**
- Consumes: The merged, reduced PR branch.
- Produces: A result bundle showing zero failed or skipped tests.

- [ ] **Step 1: Generate the Xcode project and run the full suite**

Run:

```bash
xcodegen generate
xcodebuild test \
  -project Conduit.xcodeproj \
  -scheme Conduit \
  -destination "platform=iOS Simulator,id=6930ECCE-D36C-4E11-8AB5-EDEC4DEA8355" \
  -configuration Debug \
  -resultBundlePath /tmp/conduit-pr46-salvage.xcresult \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER=""
```

- [ ] **Step 2: Read the result summary**

Run:

```bash
xcrun xcresulttool get test-results summary --path /tmp/conduit-pr46-salvage.xcresult
```

Expected: `result` is `Passed`, `failedTests` is `0`, and `skippedTests` is
`0`.

### Task 4: Publish and wait for fresh PR validation

**Files:**
- Push: contributor fork branch `angel12/hermes-conduit:fix/session-cache-invalidation`.
- Review: GitHub PR #46.

**Interfaces:**
- Consumes: Verified merge commit and clean worktree.
- Produces: Fresh Build & Test, OpenCode review, and CodeRabbit results against
  the reduced PR diff.

- [ ] **Step 1: Confirm the branch and worktree state**

Run:

```bash
git status --short --branch
git log --oneline --decorate -4
```

Expected: clean worktree, branch `codex/pr46-session-cache-invalidation`, and
the salvage merge commit at `HEAD`.

- [ ] **Step 2: Push without force**

Run:

```bash
git push https://github.com/angel12/hermes-conduit.git HEAD:fix/session-cache-invalidation
```

- [ ] **Step 3: Wait for the fresh checks and inspect new review threads**

Run:

```bash
gh pr checks 46 --repo kaishi00/hermes-conduit --watch --interval 30
gh pr view 46 --repo kaishi00/hermes-conduit --json state,headRefOid,statusCheckRollup,reviews
```

Expected: the checks complete successfully and any new comments are evaluated
against the reduced cache-only diff, not the historical bundled commits.
