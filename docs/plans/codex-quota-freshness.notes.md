# Codex quota freshness implementation notes

Authority: `codex-quota-freshness.md`.

## Implemented

- `CodexQuota.mergeRateSnapshot` now compares the short and long windows using
  each window's own `observed_ts`. A newer observation wins even when its
  `resets_at` moved backwards; equal timestamps choose the incoming raw window
  so an equal-time snapshot can repair stale cached values. Older snapshots
  cannot replace newer ones.
- Each retained window keeps its own timestamp. If an old slot has no
  `observed_ts`, the merger stamps it from the pre-merge record-level timestamp,
  including when the incoming snapshot omits that window. The record-level
  timestamp remains the maximum observation for compatibility.
- `CodexQuota.decode` uses a window's own timestamp when deciding whether its
  reset is stale, falling back to the legacy record timestamp only for old
  payloads. Raw `primary`/`secondary` windows are classified by duration even
  if the raw record already has a top-level `observed_ts`.
- `CodexSource.refresh` records whether a legacy window cache needs tail repair
  before it processes or persists newly scanned snapshots. That pre-merge flag
  ensures a short-only incoming update cannot normalize old slot metadata and
  inadvertently suppress startup repair of the long window.
- Legacy repair reuses the local newest-session tail reader. When a temporary
  sessions directory is explicitly supplied (as in isolated tests), priming
  reads only that directory; normal refresh retains the existing home-session
  lookup and throttle. The repair changes quota metadata only; tests assert
  stable cursors and contribution rows remain unchanged.

## Validation

- `bash Tests/run.sh` passed 41 checks, including seven quota freshness cases:
  189-second reset regression, equal-observation repair, delayed older data,
  per-window timestamp retention, swapped raw positions, legacy cache repair
  without contribution/cursor changes, and a short-only incremental snapshot
  that must not suppress repair from the latest local tail.
- `swift build -c release` and `git diff --check` are pending final verification.
- Tests use temporary SQLite databases and session files. No real store was
  opened for writing and the application was not started.
