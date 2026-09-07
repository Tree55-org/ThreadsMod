# Indexed passive blocking

This document owns the passive-blocking mechanism.
It describes how the signed index is fetched and proven, how it is stored, how a listed profile is matched to a row that is actually on screen, and everything that must be true before the clone blocks anyone.
Release history — which artifact shipped which behaviour, and which builds are superseded — lives in [CHANGELOG.md](CHANGELOG.md).
The two configurable delay values that pace passive attempts are owned by [10 — Reporting and limits](10-REPORTING-AND-LIMITS.md).
The screens that display this state are described in [09 — Activity, Settings, and inline Block](09-ACTIVITY-SETTINGS-AND-INLINE-BLOCK.md).

## Passive blocking is always on

Passive blocking is not a stored preference, and it has no user-facing switch.
`AutoBlockSync.isEnabled(Context)` returns true for any non-null context and reads nothing; the only false answer it can produce is the fail-closed one a null context must still give.
`AutoBlockSync.disable(Context)` does not exist.
There is no opt-in, no consent dialog, and no in-app way to turn passive blocking off.

The Settings screen's **Passive blocking** card discloses the behaviour instead of gating it.
It is a static description — "Always on. Refreshes the signed index every 10 minutes in the foreground, then blocks only listed profiles whose post or reply action row becomes visible." — with no switch beside it.
The clone opens with no mod dialog at all, so nothing prompts you before passive work becomes eligible to run.
Before the first viewer-scoped status write, the status line's fallback is the single sentence `Enabled; waiting for a signed-in foreground session.`
The retired `enabled` preference key is still written by a manual sync so persisted state matches reality, but it has no reader and grants no authority anywhere.

Installing the APK, opening it, and signing in is enough to arm passive Block.
Because there is no stored flag, there is no state to reset: force-stopping the clone, clearing its data, or reinstalling it re-arms passive blocking on the next foreground resume with a signed-in session.

The blocks this produces are real, and they are not local.
Each one is a Threads account mutation performed through Threads' own signed-in native block path, from the account signed into the clone, against a real profile.
It is server-side account state that survives uninstalling the clone: removing the app unblocks nobody, and the mod carries no undo.

Three boundaries constrain the mechanism, and they are the whole of its safety story.

- **One target at a time.** Each scheduler drain selects at most one target and dispatches at most one native Block, behind a randomized delay drawn from the configured passive range.
- **Admission only for a currently-visible matching author.** A profile must be present in the verified signed index *and* be rendering a reviewed post or reply action row with attached, non-empty clipped bounds at the moment of admission. Refresh never enqueues Block work, and nothing enumerates the database to block in bulk.
- **No report is ever created passively.** Report authority is only the explicit positive tap in the one **Block and report** modal; see [10 — Reporting and limits](10-REPORTING-AND-LIMITS.md).

Every guarantee in this document is static proof over built bytes.
No published build has been installed or run on any device: every release run records `runtimeValidation: not-run`, so no live scrolling, admission, refresh, migration, chunk download, or Block has ever been exercised for published bytes.
The only device-adjacent evidence is an isolated emulator Activity probe of a work-local review candidate, which renders the mod screens with no account and no network.
Modifying and re-signing the APK also voids Meta's signature by definition; side-by-side installation, though, comes from the separate application ID `app.tree55.threads`, not from the new signature.

## Foreground refresh contract

A refresh is eligible only while the clone is foregrounded and the current process holds a canonical viewer from the live Threads session.

- The foreground cadence is exactly 600,000 ms — ten minutes — between eligible refresh wakes that follow a successful attempt. A failed attempt is followed by the next step of the fixed 15 s, 30 s, 60 s, 120 s, 300 s ladder, at most five steps per foreground session, then 600,000 ms again.
- Every attempt durably advances `list_refresh_not_before` by the full 600,000 ms interval before work begins. The worker re-installs the deadline from completion time — exactly 600,000 ms after success, or one ladder step after failure — through a three-argument `advanceListRefreshDeadline` overload whose interval can never exceed `FETCH_INTERVAL_MS`. Nothing else may shorten a persisted deadline.
- The ladder index is process-local. It advances only on a completed failed attempt, and resets on success and on each background-to-foreground transition. The ladder array is built element by element in a helper because the raw-DEX bridge proof refuses a `fill-array-data` payload in a static initializer.
- Raw deadline reads are exception-safe and require the stored value to be an exact Android `Long`. A read exception, a wrong type, an overflow, or a value more than `FETCH_INTERVAL_MS + 120,000 ms` in the future pauses ordinary refresh fail closed rather than being read as zero.
- If worker start is rejected, the deadline is re-advanced from rejection time before the lane is released. Ordinary pause, resume, and process recreation honour the remaining delay and cannot spin once per second.
- Every scheduler-critical wake checks Android's Boolean enqueue result.
- If the clone is backgrounded, no refresh runs and none is queued to run later: the mod schedules no Android background work at all, so nothing wakes the lane until the next foreground resume.
- An overdue refresh catches up on the next foreground resume with a valid viewer. While no valid verified index exists, the first ordinary request of a foreground session starts one attempt ahead of a pending deadline — once per foreground session, and no sooner than 15 s after the last admitted start — instead of waiting out a stale deadline. It still installs the new 600,000 ms deadline before work starts.
- **Sync now** starts the list refresh directly when its lane is idle; behind an active refresh it records only a bounded viewer-scoped force intent. This forced path and the once-per-session missing-index start are the only two deadline bypasses, and neither can erase, shorten, or transfer the durable ordinary deadline.

**Sync now** verifies and indexes the list.
It does not queue a single listed profile.

## Three mirrors and one signed root

Reads consult the signed root under every allowlisted base in this fixed order, pinned in [`CloneBlockerEndpoints.java`](../patchlets/assets/autoblock/java/threadsmod/autoblock/CloneBlockerEndpoints.java):

| # | Base | Signed root |
|---|---|---|
| 1 | GitHub raw | `https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/blocklist/v3/manifest.json` |
| 2 | jsDelivr | `https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/blocklist/v3/manifest.json` |
| 3 | AWS relay | `https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/blocklist/v3/manifest.json` |

Every root is fetched and verified independently, and no mirror is skipped because an earlier one answered.
Only a strictly newer signed `updatedAt` may replace the committed generation; an equal timestamp keeps the earlier mirror and advances fetch metadata only, so a reachable but stale mirror can neither churn the index nor clear the passive pause latch.
A conditional `If-None-Match` is sent only to the exact mirror that produced the retained generation, and only while that generation is still usable, so a 304 cannot hide a newer root elsewhere.
Each URL is rebuilt and re-checked against its exact scheme, host, path, and external form before use; a port, user-info, query, or fragment fails closed.
The ISP-blocked legacy origin is deliberately absent and there is no origin fallback: `tree55.com` is forbidden and appears in no compiled read path.

A root becomes lookup authority only after every one of these passes.

- The envelope declares `alg` `ed25519` and carries a `sig` of 40 to 160 characters, and the extracted payload verifies under the Ed25519 public key compiled into the APK.
- `updatedAt` parses to a positive epoch millisecond value; more than 24 hours in the future is `clock`, older than 30 days is `stale`, and older than the retained generation is `rollback`.
- The payload is read type-strictly, because `org.json` coerces on `optInt`: `v` must be the integer 3, `hash` must be the string `sha256-hi32`, and `maxChunkRows` and `maxChunkBytes` must be integers of at least 1 that do not exceed the compiled maxima.
- `platforms.threads` must be an object carrying integer `k` (bucket bits), integer `g` (group bits), integer `total`, and a `groups` array of exactly `1 << g` 64-lowercase-hex names, with `g` no greater than `k`.
- `k` above 16, `g` above 8, or `total` above 2,000,000 rows is rejected as `target_cap`.

Only the `threads` partition is fetched.

## Objects are named by their own hash and proven before parse

Group tables and chunks are fetched only as `<base>blocklist/v3/objects/<name>` under those same three bases, the winning root's mirror first.
A name is exactly 64 lowercase hex digits plus one closed suffix: `.json` for a group table, `.ndjson.gz` for a chunk.
`CloneBlockerEndpoints.objectUrl` validates that grammar and throws before any URL text exists, so an unvalidated name never reaches a URL, a connection, or a log.
Every refresh that reaches the network first runs `validateConfiguration`, which re-derives all three roots and, per mirror, proves that a zero-stem name of each suffix is accepted while an uppercase-hex name, a short name, a `..`-prefixed name, and a null name are all rejected.

Each object is fetched with one unconditional GET, no redirects, no caches, a 10 s connect and 15 s read timeout, and a mandatory `Accept-Encoding: identity`.
The identity header is not cosmetic: without it the platform client adds gzip and transparently inflates a Content-Encoding hop, which would break the hash of the received bytes and hide Content-Length.
The fetch is refused outright while a process-wide `CookieHandler` is installed, checked both before the URL is formed and again before connect.
Only HTTP 200 is accepted, and the response Content-Type is never interpreted, because CDNs vary.
Bytes are bound by the caller's cap and, for a chunk, by the exact signed byte count on both the declared Content-Length and the bytes actually read.

Then, before any parse, `SHA-256(bytes)` must equal the 64-hex stem of the name the signed root transitively gave.
A mismatch is a `signature` failure, not a parse failure.
This is the hinge of the whole design: an object that has not been proven against a signed name can never become a block list.

Every bound is compiled, and a signed root that declares caps above them is rejected rather than trusted.

| Bound | Value | Constant |
|---|---|---|
| Root response bytes, on Content-Length and streamed bytes | 4,194,304 | `MAX_RESPONSE_BYTES` |
| Root characters after decoding | 524,288 | `MAX_ROOT_BYTES` |
| Group table bytes | 65,536 | `MAX_GROUP_BYTES` |
| Chunk gzip bytes | 262,144 | `MAX_CHUNK_GZ_BYTES` |
| Chunk inflated bytes | 4,194,304 | `MAX_CHUNK_INFLATED_BYTES` |
| Rows per chunk | 8,192 | `MAX_CHUNK_ROWS` |
| Threads rows per index | 2,000,000 | `MAX_INDEX_ROWS` |
| Bucket bits `k` | 16 | `MAX_BUCKET_BITS` |
| Group bits `g` | 8 | `MAX_GROUP_BITS` |

## Only changed chunks are downloaded

A row's bucket is the high `k` bits of `h32`, the first four bytes of the SHA-256 of its signed key — `threads:<id>` for an id row, `threads:@<handle>` for a handle-only row.
The signed root names content-addressed group tables; each group table names one gzip NDJSON chunk per bucket, with its signed row count and byte count.

A group table whose sha already matches the committed table is reused without a fetch.
A bucket's chunk is downloaded only when its signed name differs from the committed generation, or when the bucket bits change, or when no valid generation exists — in which case every chunk is fetched.
This is why the index no longer has to fit inside one response bound: it is fetched incrementally, and a steady-state refresh usually downloads nothing at all.

Each replaced chunk is staged one at a time, inflated through a capped `GZIPInputStream` and parsed line by line with a strict `JsonReader` into the content-addressed `blocklist_staging` table, so memory stays bounded to one capped compressed buffer plus one row list.
Lenient JSON parsing is forbidden in this class, as are exception-message accessors, so nothing a mirror sends can reach a status string or a log.

A chunk is rejected **whole**, and the entire install with it, for any of these seven row conditions:

- `chunk row is not a JSON object`
- `chunk row has malformed numeric id`
- `chunk threads id row has malformed username metadata`
- `chunk rows contain a duplicate numeric id`
- `chunk rows have conflicting normalized usernames`
- `chunk row belongs to a different bucket`
- `chunk row count differs from the signed group entry`

A chunk that is not valid gzip NDJSON, that exceeds the inflated byte cap, that carries a line which is not one compact JSON object, or whose byte count differs from the signed group entry is rejected the same way, as is a group table that is not the v3 threads group the root named, or a root whose declared total differs from the sum of its group tables.
There is no partial acceptance and no row-level skip: a malformed chunk fails the install and preserves the previous verified generation.

A handle-only row — `u` present, `i` absent — is a canonical non-target row.
It is bucket-checked and counted toward the signed row total, but never indexed, because this client keys passive membership by numeric id alone.
That is why the Activity's `Records:` line reports installed threads id rows rather than the signed total.

A signed reference root and its objects, captured on 2026-09-06, are checked in at [`patchlets/assets/tests/fixtures/blocklist-v3-2026-09-06/manifest.json`](../patchlets/assets/tests/fixtures/blocklist-v3-2026-09-06/manifest.json) and drive the host [`PassiveBlocklistFixtureHarness`](../patchlets/assets/tests/PassiveBlocklistFixtureHarness.java), which proves the hash chain, bucket membership, and row grammar and prints `PASS passive-fixture-v3 k=4 chunks=16 idRows=1607 handleRows=26 unique=1607`.

## SQLite schema v3

A verified root atomically replaces one generation in `threadsmod_blocklist.db`, whose `DATABASE_VERSION` is 3.

| Table | Holds |
|---|---|
| `blocklist_targets` | `target_id` TEXT PRIMARY KEY, `username`, `username_key`, `h32`; UNIQUE index `blocklist_targets_username_idx` on `username_key`, index `blocklist_targets_h32_idx` on `h32` |
| `blocklist_metadata` | single row: generation, `verified_updated_at` text and its millisecond field, `fetched_at_ms`, `target_count`, `new_target_count`, `bucket_bits` |
| `blocklist_chunks` | one row per bucket: `sha256`, `row_count`, `id_count` |
| `blocklist_groups` | one row per group index: `sha256` |
| `blocklist_staging` | content-addressed staged rows, keyed by (`sha256`, `target_id`) |

Every column carries a SQL `CHECK`: a target id is 4 to 24 digits with no leading zero, a username is 1 to 64 characters from `A-Za-z0-9._`, `username_key` must equal `lower(username)`, and `h32` must be an unsigned 32-bit value.

One transaction performs the replacement.
It measures each replaced bucket's exact new-id set difference against the still-complete previous generation with a `NOT EXISTS` query **before** any delete, deletes each replaced bucket's `h32` range, copies that bucket's staged rows in with `INSERT ... SELECT`, records the chunk and group names, and commits generation + 1 with `bucket_bits` and a `target_count` equal to the sum of installed id rows.
Unaffected buckets are never touched.

Numeric ID is the only mutation authority.
Import rejects a duplicate normalized username within a chunk, the UNIQUE index fails a cross-chunk duplicate closed at commit, stored rows must retain exactly one normalized username per target, and a visible row whose normalized username disagrees with the stored exact-ID result is rejected.
Username never becomes substitute mutation identity.

The signed `updatedAt` text is parsed to epoch milliseconds before replacement, and stored metadata reparses that text and requires it to equal the stored millisecond field.
Staged chunks are never authoritative until the transaction commits.
Any fetch, signature, object-hash, parse, schema, clock, timestamp-rebinding, transaction, or invariant failure preserves the previous verified generation.
An HTTP 304, or a reachable mirror still serving the timestamp already indexed, advances only source and fetch metadata.

### The v2 to v3 migration

An install carrying a v2 store migrates on first open through a reviewed path.
It renames `blocklist_targets` and `blocklist_metadata` to `blocklist_targets_v2` and `blocklist_metadata_v2`, creates the v3 schema, copies every retained row with its recomputed `h32`, and moves the metadata row with `bucket_bits` 0.
It then requires the generation, both timestamps, and both counts to be preserved, and re-checks the installed row count against the migrated `target_count`; any disagreement fails the migration closed.
The two renamed v2 tables are emptied and left behind empty, because a DROP-TABLE literal is forbidden in this class.
A v1 store chains through the existing v1-to-v2 stage first.

Because the clone's package (`app.tree55.threads`) and version code (`511407878`) do not change between these builds, an update installs in place and the retained store migrates on first open.
No migration has been run on a device.

### What is gone

The whole-file `blocklist.json` model is retired, not deprecated.
No `blocklist.json` URL, no `MAX_TARGETS` cap, and none of that file's flat `targets`, `ids` or `idNames` arrays is compiled into this build, and the client cannot fall back to one.
The former SharedPreferences list blob is deletion-only: it is not a fallback lookup source and cannot seed a queue.

## Failure classes reach the status line closed

Within one attempt a mirror is retried once, immediately — exactly once per root and once per object — and only after an `IOException`: a timeout, a DNS or connect failure, a TLS failure, or a stream broken mid-body.
It is never retried after an HTTP, oversized, cookie, signature, schema, clock, stale, rollback, or target-cap result.
An object failure moves to the next allowlisted mirror, and the install fails closed only when every mirror has failed.

The retained-failure status names one closed failure class per mirror in declared order, for example `mirror 1 too_large`.
The whole closed set is `too_large`, `http_<status>` or `http_other`, `timeout`, `unreachable`, `tls`, `io`, `signature`, `schema`, `clock`, `stale`, `rollback`, `target_cap`, `cookie_refused`, and `internal`.
Each token is chosen by exception type or by the typed `ListFetchFailure.failureClass` field, never from a message, URL, header, or body, and the status never includes exception text, a URL, a header, or a body.
An object-phase failure is attributed to the mirror that served or refused the object; a hash mismatch is `signature`, a malformed group table or chunk is `schema`, and `target_cap` covers the row and bucket caps.

## Lookup, generation faults, and the store pause

Exact-ID lookup has three outcomes: a valid match, a valid non-match, and an invalid, unavailable, or corrupt store.
Every invalid result carries the generation actually observed.

An unknown-generation fault, or a fault observed against the current committed generation, latches passive processing paused; it can never be consumed as "this profile is not listed."
Suppression is allowed only for a known observed generation strictly older than the latest committed verified generation.
Only a strictly newer committed verified generation than the latched observed generation may clear the pause.
A 304, a retained old generation, a resume, an ordinary non-match, an equal or older replacement, and an unproven generation are all *not* authority to clear it.
Latching also clears the in-memory lookup queue and every pending match generation.

Most importantly, list refresh never creates Block work.
There is no loop anywhere that turns database rows into a batch of targets.

## Visibility coverage

One remembered visibility callback attaches to the sole Block control's existing immutable row request.
It reports visible only when layout coordinates are attached and the clipped root bounds are non-empty, and the stable Java registration store deduplicates unchanged false/true transitions.

Authority-granting registration, a `visible=true` update, manual enqueue, and automatic-run ownership accept only the main looper.
Off-main pause, visibility-update, and unregister paths may only *revoke* authority, and must serialize through `PASSIVE_ADMISSION_LOCK`; they cannot register, mark visible, enqueue, or begin a run.
An invisible row immediately loses pending-match authority, while its remembered token may remain for the next geometry callback; forgotten or abandoned callbacks remove the registration completely.
Registrations are bounded to 256 rows and the pending lookup queue to 256 entries.

The callback performs no SQLite, network, scheduler, reporting, or bridge work.
It calls only the bounded in-memory registration API, and a background worker performs the indexed lookup.
Every geometry callback first re-establishes the same immutable token, which lets a remembered row recover after an account-context reset without transferring its old viewer identity.

Coverage is deliberately narrow:

- posts and replies that render the reviewed UFI action row;
- those same action rows when they appear in profile post lists.

It does **not** cover profile headers, search results, follower or following lists, generic profile cards, or any surface that does not render the reviewed post/reply action row.
Supporting one of those surfaces requires a new exact-SHA seam, ownership, AI resolver evidence, human review, and release gates.

## Match and admission flow

Each scheduler drain copies at most one eligible current visible registration under the memory lock and performs one indexed lookup.
It does not build a temporary page-sized list of visible IDs.
A stale valid non-match is discarded and a bounded 250 ms delayed fresh drain may independently select again; invalid store state pauses the passive lane instead of synchronously inspecting another row.

A drain skips:

- a valid non-match — while an invalid, unavailable, or corrupt store pauses the passive lane instead;
- a missing or noncanonical target, and the active viewer itself;
- a target already completed or already recorded blocked locally;
- queued, running, or completion-review-quarantined work;
- a row that is no longer visible;
- a stale viewer, session, foreground generation, or database generation.

Only a current numeric-ID match whose stored and visible normalized usernames agree may be persisted as passive work.

Under the same monitor that atomic generation replacement uses, a callback-free `passivePreflight` resolves the reviewed cache-first direct-ID model, verifies its immutable numeric ID, and reads Threads' native blocked predicate — without dispatching a mutation.
It runs before any durable persistence or delay reservation, so a profile Threads already reports blocked consumes no configured delay.
A native already-blocked result is saved into the viewer-scoped completed set and releases the owner without mutation; if that local completion save is uncertain, the target enters completion-review quarantine instead.
A fixed preflight failure creates a closed diagnostic and bounded backoff without reserving an attempt.

Because preflight touches private host state, every mutable authority is revalidated after it returns and before its result is even interpreted: foreground state, manual queue priority, store validity, the exact database generation, and ID/username membership.
The complete authority set — main-thread run owner, live Activity and viewer, foreground state, manual priority, row visibility, database generation, ID and username membership, store validity, quarantine, duplicates, pacing, completed-state integrity, and the stored delay pair — is then checked again immediately before each of the three irreversible steps: the durable passive-running save, the attempt reservation, and the bridge dispatch.
A generation, viewer, visibility, manual-queue, store, or limit change cannot silently carry authority into native dispatch.

If reservation fails after the running state was saved, that running state is cleared; if clearing it fails, the target is quarantined for completion review rather than left ambiguous.
The completed-ID preference is inspected by raw type, bounded to 5,000 canonical IDs, and treated as a blocking review condition when malformed or oversized; the completion-review set is bounded to 200 targets and pauses passive work when full.

Manual work always has priority before another passive target is selected.
The passive run owns one immutable numeric target, commits passive-running state and its pacing reservation, and only then calls the native bridge.
It has no target list, no index, no iteration loop, and no same-owner continuation.
After confirmed success it releases with the current pacing deadline, and a new manual-first drain with a new owner token must select the next still-visible match.
It never hands a page or a database generation to a batch runner.

## Pacing

Passive attempts are paced by exactly two user-configurable values, both in whole-second steps: `passiveMinDelayMs` (2000–60000 ms, default 4000) and `passiveMaxDelayMs` (3000–60000 ms, default 10000), with the maximum never below the minimum.
Each reserved passive attempt draws one uniformly random delay from that inclusive range and persists `now + delay` as the viewer-scoped pace deadline in the same commit that records the attempt; the next passive attempt is refused until that deadline passes.
There are no per-hour, per-day, per-run, or target-budget caps: every capacity-style limit was removed and its preference key is deletion-only, so neither history nor a stale value can regain admission authority.
Manual inline Block is deliberately unpaced and uncapped, though it remains serialized by the same single-flight scheduler.
Invalid or corrupt stored limits do not grant capacity — they pause passive work for review.
The full contract, including validation, all-or-nothing persistence, and the retired keys, is owned by [10 — Reporting and limits](10-REPORTING-AND-LIMITS.md).

## Completion and failure behaviour

Every passive attempt uses the same pacing, backoff, watchdog, closed diagnostics, completion-review quarantine, cache-first direct-ID bridge, canonical model-ID equality guard, and native callback truthfulness as confirmed inline Block.
A 45 s watchdog bounds each dispatch.
A process-interrupted passive identity, or an uncertain post-dispatch mutation, enters abandoned or review quarantine without automatic retry.
Native success is recorded only after the native callback fires; if the completion save is uncertain, the viewer and target are quarantined before the scheduler is released.

Passive visibility and passive blocking never create a Clone Blocker report.

## Patchlet ownership

- `020-autoblock-runtime` owns the schema-v3 database, the three fixed v3 bases with object-name validation before any URL is formed, `ObjectFetcher` and `ChunkInstaller`, the hash proof of every object before parse, download of only changed chunks, whole-chunk rejection with handle-only rows counted but not indexed, per-bucket atomic replacement with the exact per-bucket new-id set difference, the reviewed v2-to-v3 migration, refresh metadata and cadence, the exception-safe typed durable `list_refresh_not_before` including rejection-time re-advance, the observed-generation tri-state store pause, timestamp and username invariants, main-thread authority grants with lock-serialized off-main revocation, one-target-per-drain lookup and admission, the repeated final authority checks, passive durable state, scheduler integration, and failure policy.
- `030-native-block-bridge` owns the callback-free exact-SHA passive preflight and its narrow cache, model, and already-blocked seams.
- `050-mod-settings-ui` owns truthful Settings and Activity wording and presentation only.
- `060-inline-block-controls` owns the one exact post/reply visibility hook and its Compose lifecycle binding.
- `090-release-gates` owns the canonical, host, generated, and signed-Dex gates, the exact Threads 444 split-source proof, signed review, targeted JADX, and signed-wrapper parity for the whole contract. It binds the v3 fixture tree, pins the three `blocklist/v3/manifest.json` URLs and the three `objects/` bases, and proves object-name validation before URL formation, the ordered signed-root and chunk-row chains, the seven whole-chunk rejection literals, the `ObjectFetcher` and `ChunkInstaller` targeted-JADX contracts, and the schema-v3 store pins — `DATABASE_VERSION = 3`, the UNIQUE username index, the `h32` column and index, the chunk, group, and staging DDL, the `NOT EXISTS` set-difference query measured before each bucket's range delete, and the chained v1-to-v2-to-v3 migration.
- [`RESOLVE-PASSIVE-BLOCKING.md`](../patchlets/ai/tasks/RESOLVE-PASSIVE-BLOCKING.md) bounds future lifecycle and visibility resolution; [`RESOLVE-INLINE-ACTION-ROW.md`](../patchlets/ai/tasks/RESOLVE-INLINE-ACTION-ROW.md) owns the shared action-row selection.

The canonical sources behind this document are [`AutoBlockSync.java`](../patchlets/assets/autoblock/java/threadsmod/autoblock/AutoBlockSync.java), [`ObjectFetcher.java`](../patchlets/assets/autoblock/java/threadsmod/autoblock/ObjectFetcher.java), [`ChunkInstaller.java`](../patchlets/assets/autoblock/java/threadsmod/autoblock/ChunkInstaller.java), [`BlocklistStore.java`](../patchlets/assets/autoblock/java/threadsmod/autoblock/BlocklistStore.java), and [`CloneBlockerEndpoints.java`](../patchlets/assets/autoblock/java/threadsmod/autoblock/CloneBlockerEndpoints.java), with the gates pinned in the [Threads 444 resolution](../patchlets/resolutions/444.0.0.45.85/resolution.json).

A future Threads APK must start from its pristine exact SHA-256 input.
It must fail closed if the row modifier, the lifecycle, clipped-bounds semantics, the register plan, or the one-observer topology drifts.
AI may select only pre-enumerated candidates and evidence; it cannot add a generic profile observer, write a patch, relax a gate, or publish an APK.

## What static proof cannot establish

The release gates prove the ordered signed-root chain, object-name validation before URL formation, SHA-256 proof of every group table and chunk before parse, download of only changed chunks, streamed row-by-row parsing with bounded memory, the whole-chunk rejection literals, the UNIQUE username index, set-difference-before-delete replacement, the chained migration, the single in-attempt transport retry, and the closed per-mirror status.
They also prove the 600,000 ms cadence, the fixed failure ladder installed only at completion time, the non-clearing forced and missing-index bypasses, the absence of any fetch-to-queue edge, the one memory-only clipped-viewport observer with complete lifecycle cleanup, main-thread-only authority grants with lock-serialized off-main revocation, native already-blocked preflight before any durable persistence or delay reservation, complete authority immediately before running persistence, reservation, and dispatch, one copied target per drain with fresh owner selection after success, the exact post/reply scope with no profile-header claim, and the absence of passive report creation.

None of that is a device test.
Static proof cannot establish row visibility on a phone, a live v3 root or object fetch, chunk staging, per-bucket replacement, or the v2-to-v3 migration on real data.
It cannot establish exact foreground timing under an OEM scheduler, failed-deadline persistence and rejection-time re-advance through real process recreation or executor refusal, tri-state pause and recovery under storage faults, username or timestamp conflict behaviour against a device database, main-thread grant rejection and off-main revocation under live context changes, login, model construction, Meta's acceptance of the mutation, or the absence of duplicate actions during live scrolling and account changes.
Those require an exact-candidate device test with a disposable account and controlled signed-list targets.
Until that test exists, treat every published artifact as unexercised.
