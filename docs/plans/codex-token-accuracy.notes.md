# Codex token accuracy implementation notes

This file records implementation evidence against the authoritative plan in
`codex-token-accuracy.md`.

**Final status:** implementation, review, signed packaging, real v4 migration,
both readonly production audits (exit 0), golden values, and restart acceptance
completed by the main agent on 2026-10-09. Earlier statements below about
production work remaining describe the implementation agent's handoff boundary.
The authoritative plan's production acceptance section records the backup path,
reports, unchanged historical buckets, and observed live additions.

## Current progress

- Existing SQLite readonly, read-transaction, backup, temporary-store injection,
  source-atomic-write, and exact-metadata-key deletion changes are present.
- `CodexIndex` and `CodexV4Engine` implement explicit fork fingerprinting,
  v4 migration staging, bounded newline scans, fallback-day ranges, and
  persistent per-file cursors.
- The scan loop skips unchanged file signatures. Changed files first verify the
  previously committed raw-byte SHA-256 prefix; matching prefixes continue the
  hasher while parsing only new complete lines, while mismatches trigger a
  complete file rescan and dependent-child recomputation.
- Open fork prefixes are now modeled so an empty child or child ending exactly
  at a copied prefix can extend that prefix across later append batches.
- Immediately before the source transaction, the staged scan identities and
  committed raw hashes are revalidated, every captured session path is checked,
  and direct parent reads are checked against persisted parent raw hashes. If
  an EOF was used to decide an open prefix and that parent changes in the same
  cycle, the whole stage is rejected for retry.
- Reconcile only blocks on missing parents referenced by children that still
  exist, so deleting a child and its parent together can clean both rows and
  cursor states atomically. If one same-ID recovery parent disappears while
  another remains, reconcile runs the normal fork reselection under the same
  source lock, reloads cursors, then removes the stale parent contribution and
  metadata; if no candidate remains, it preserves prior rows and marks the
  source incomplete.
- Refresh and reconcile also hold an owner-only `0600` lockfile beside the
  database with `flock(LOCK_EX)`, in addition to the process-local mutex. The
  lock covers staging, source commit, and rate-limit persistence; readonly audit
  never creates or acquires it.
- `validateForkGraph` rejects multiple recovery files for one session ID when
  their declared parent relationships differ, including `nil` versus a parent.
- The readonly audit is implemented as an early CLI path. It opens SQLite
  readonly, snapshots Codex rows/cursors/status in one read transaction, scans
  only committed log offsets, and independently recomputes day totals and
  fork prefixes without calling refresh or the shared store. Its JSON explicitly
  includes lean/full totals; malformed buckets, conflicting ancestry, and
  fork cycles become blockers (exit 2), and setup errors are also saved to a
  requested report path.
- The Detail view now explains the two token modes in Chinese and states that
  token counts are not fees or account quotas. Newly discovered same-ID
  recovery files force a child with an incremental tail scan back through a
  full prefix match in that refresh.
- The detail banner uses a short user-facing message for incomplete refreshes;
  raw internal errors remain in store diagnostics.
- Main-agent review fixes already incorporated: exact metadata key deletion for
  overlapping file paths; reject incremental parent tail as a raw prefix;
  clear old fork metadata when a full scan has no fork metadata; and skip stable
  files rather than rescanning them every poll.
- The first valid `session_meta` header in each file now owns both the file's
  session ID and its optional parent ID. Later headers are ignored because real
  copied histories can embed parent and grandparent headers inside a child log.
  The `sessionMetaSeen` bit is persisted in the file cursor so tail scans keep
  this rule after restart; a full rescan replaces it from the newly observed
  content, including clearing it when the header disappeared.
- Fork matching records a parent EOF dependency only when the matched prefix
  reaches the end of the available parent event sequence and that EOF is what
  leaves the child prefix open. A mismatch before parent EOF does not make the
  unrelated parent tail part of the staged decision.

## In progress / remaining

- The isolated suite now covers offline rewrite plus growth, empty/open fork
  prefixes extended in multiple batches, nested/multiple parents, incomplete
  lines, parent append without child scan, precommit rewrite detection,
  readonly audit JSON totals, invalid and copied-prefix buckets, conflicting
  ancestry/cycles, requested error-report files, same-cycle recovery-candidate
  recomputation, same-ID parent conflicts, surviving-parent re-selection after
  deletion, interprocess refresh serialization/no duplicate deltas, audit
  lockfile absence, reconcile cleanup, and backup/transaction failure recovery.
- `bash Tests/run.sh` passed all 34 checks on 2026-10-09, including copied
  parent/grandparent headers followed by an incremental append, full-rescan
  clearing of `sessionMetaSeen`, parent append after an already-diverged fork,
  and rejection when a matched parent EOF changes before commit.
- `git diff --check` passed, and `swift build -c release` completed on
  2026-10-09 without launching the app. README guidance, the audit CLI,
  user-facing status, and plan checkboxes are updated. Main-agent review and
  real migration/golden acceptance remain pending.
- Build is allowed after tests, but do not launch the application or run a
  refresh against the real store. Main agent owns real migration and golden
  acceptance.

## Operational boundaries

- Unchanged files are skipped by signature. When a signature changes, the old
  committed raw prefix is verified before any incremental tail parsing. The
  verifier streams bytes without JSON decoding; scan instrumentation records
  raw-prefix reads separately from event parsing.
- The persisted `prefixSHA256` is a chained SHA-256 over canonical token-event
  fingerprints. It can be extended with newly matched events without rereading
  the child history.
- Tests verify the startup-rewrite-plus-growth, open-prefix, parent append
  scan-count, and commit-time change cases against temporary files/DBs only.
- Real-log golden values from the plan are authoritative; no real database or
  application migration has been run by this implementation agent.

## Latest review follow-up

- Main-agent review confirmed the raw-prefix resume, open-fork extension, and
  parent-append behavior, then found that reconcile considered dependencies
  from deleted children and that precommit validation omitted unscanned files
  and direct parent reads. Both are fixed and covered by the isolated suite.
- A test-only precommit hook mutates a temporary parent file in place and
  appends bytes after staging; the engine detects the committed-prefix digest
  change and leaves previous rows/cursors/version intact.
- No blocker requiring a design decision remains. Real SQLite migration,
  production log audit, app restart, and the three-session golden totals remain
  deliberately for the main agent after independent review.
- A readonly inventory supplied by the main agent found 74 real files with
  session metadata; each first header ID matches its filename, 11 contain a
  later copied parent header, and one of those later headers carries a
  grandparent relationship. This confirms first-header ownership is needed for
  the actual corpus. No production migration or store write was performed here.
- The main agent observed scanning stalled in bytewise `Data.firstIndex(of:)`.
  The scanner now uses `memchr` and carries the next unsearched byte position
  across 64 KiB chunks; a multichunk line, complete event, partial tail,
  subsequent append, offsets, and complete-prefix digest are covered by the
  isolated suite. A readonly scan of the 388,788,238-byte real session file
  `rollout-2026-08-03T16-05-05-019fc6a7-af11-7102-9a74-2d2e3758a303.jsonl`
  processed 1,421 usage events and committed all 388,788,238 bytes in 591 ms.
  The scanner only opened/read that session file; it did not open a database or
  mutate any real data.
- After the final metadata and EOF fixes, `bash Tests/run.sh` passed all 34
  checks, `swift build -c release` completed successfully (with existing
  compiler/linker warnings), and `git diff --check` passed. The app was not
  launched and no real refresh/migration was run.
