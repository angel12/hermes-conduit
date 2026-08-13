# PR #46 Salvage Design

## Context

PR #46 was opened from an older `main` revision and bundled several stability
changes. Those changes are now already present on current `main`, including the
later stream-reconciliation hardening from PR #43 and the image-fallback and
dashboard lifecycle work from PR #45. The only behavior unique to PR #46 is
session-catalog cache invalidation.

The PR must be updated without rewriting its remote history because its head is
owned by the contributor fork.

## Scope

1. Merge the current `origin/main` into the PR branch.
2. Preserve the PR #46 cache invalidation behavior:
   - remove deleted or archived sessions from every profile catalog cache;
   - clear profile catalog caches and full-history markers on disconnect so a
     later sign-in performs an authoritative reload.
3. Do not reimplement or alter the already-merged stream, WebSocket, WebKit,
   rendering-cache, or image-fallback changes.
4. Add focused regression coverage only if the existing AppState test seams can
   verify the cache contract without exposing production-only test hooks.

## Integration and behavior

The merge should retain current `main` as the source of truth for files that
changed after PR #46 branched. The cache invalidation remains attached to the
existing successful delete/archive paths and the explicit disconnect path.

The resulting PR should have a small effective diff against `main`, making the
review target the cache behavior rather than stale historical commits.

## Verification

- Confirm the merge has no unresolved conflicts.
- Run the focused cache-related tests, if added.
- Run the full Xcode-generated iOS test suite on the available simulator.
- Push the non-rewritten PR head and wait for Build & Test, OpenCode, and
  CodeRabbit to evaluate the reduced diff.
