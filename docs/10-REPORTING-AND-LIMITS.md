# Reporting and passive-delay limits

Clone Blocker can file one pseudonymous report about a Threads post to a small relay this project runs, and it paces its own passive blocking behind two configurable delay values.
This document is the canonical owner of the limits contract; other documents give a short summary and link here rather than restating the ranges.
It also owns the report flow, the exact wire payload, and the privacy disclosure attached to it.

Ownership is split across the patchlet series.
[`020-autoblock-runtime`](../patchlets/features/020-autoblock-runtime/PATCHLET.md) owns `BlockLimits`, `BlockLimitsStore`, the block scheduler, and every `limit_*` preference key.
[`070-consented-reporting`](../patchlets/features/070-consented-reporting/PATCHLET.md) owns the `threadsmod.reporting` package, the durable outbox, the report database, and the two authorized write endpoints.
`060-inline-block-controls` owns the only inline control and the only combined modal, and `050-mod-settings-ui` owns the Settings and Activity surfaces that display report and delay state.
Revision history for all of them lives in [`CHANGELOG.md`](CHANGELOG.md).

## Passive delay limits

`BlockLimits` declares exactly two user-configurable fields.
The runtime has no other user-configurable pacing, rate, budget, or per-run control.

| Field | Preference key | Range | Step | Default |
|---|---|---|---|---|
| `passiveMinDelayMs` | `limit_passive_min_delay_ms` | 2000–60000 ms | whole seconds | 4000 ms |
| `passiveMaxDelayMs` | `limit_passive_max_delay_ms` | 3000–60000 ms | whole seconds | 10000 ms |

`BlockLimits.checked` enforces three rules and throws rather than adjusting a value.
A value outside its range is rejected.
A value that is not a whole number of seconds is rejected with `must use whole-second steps`, because the check is literally `value % 1000 != 0`.
A minimum greater than its maximum is rejected with `Passive minimum delay cannot exceed its maximum.`
Nothing is silently rounded, clamped, or reordered.

Settings presents the pair as whole seconds in the **Passive delay** card, with the hints `2–60, in whole seconds` and `3–60, in whole seconds`, a **Save delay** button, and a **Use 4–10 seconds** button that restores both defaults.
The field parser accepts an integer only and multiplies it by 1000 with `Math.multiplyExact`, so a decimal, a blank field, or an overflowing value is refused before anything is written.

### Persistence is all-or-nothing

`BlockLimitsStore.save` re-validates the pair through `BlockLimits.checked`, then writes both keys in one `commit()`.
A partial pair is never applied.
The same editor also deletes the retired keys listed below.

The store raises its process-wide uncertainty latch *before* the commit, because Android can update its in-memory preference map even when disk persistence returns false or throws.
A successful commit clears the latch.
A failed commit triggers a rollback that rewrites the exact prior value of every affected key for each `SharedPreferences`-supported type — `Integer`, `String`, `Boolean`, `Long`, `Float`, and `StringSet` — so a previously corrupt value stays corrupt and visibly invalid instead of disappearing into a valid missing-key default.
A key that had no prior value is removed.
The latch returns to its pre-save value only if that rollback itself commits; otherwise it stays raised.

While the latch is raised, `load` returns the defaults and `isValid` returns false.

Read-back is equally strict.
Both keys absent is valid and means the defaults.
One key present without the other, either key stored as a non-`Integer`, or a stored pair that fails `checked` is invalid; `load` then returns the defaults for display only, and `isValid` stays false.

### Invalid stored limits pause passive work

Passive blocking will not start while `BlockLimitsStore.isValid` is false.
The runtime shows `Stored passive delay needs review; passive blocking remains fail-closed until both delay values are saved again.` and re-wakes on the safety-review interval instead of quietly proceeding with defaults.
Settings shows the same state in the Passive delay card and points at the **Use 4–10 seconds** button.

### What the delays actually pace

The delays apply to passive blocking only, and only between attempts.
Each time the passive path reserves an attempt it draws one uniformly random value from the inclusive range `[passiveMinDelayMs, passiveMaxDelayMs]`, persists `now + delay` as the viewer-scoped pace deadline in the same commit that records the attempt, and refuses the next passive attempt until that deadline passes.
The stored deadline is read back against a plausibility bound of `MAX_PASSIVE_MAX_DELAY_MS + 1000` ms; a wrong-typed or implausible value is not read as zero, it pauses passive work for review.
The scheduler reloads the limits from the store before each selection, so a saved change applies without restarting the process.

**Manual inline Block is unpaced and uncapped.**
Its attempt reservation performs no limits validity check, no pace check, and writes no pace deadline, so nothing in this contract delays or limits it.
It is still serialized by the single-flight scheduler, is still held behind the shared failure pause after a failed attempt, and a queued inline Block is drained before passive work resumes.
A user who taps the inline control repeatedly issues Block mutations at whatever rate they tap.

Every Block this build performs, passive or inline, is a real Threads account mutation made through Threads' own signed-in native path.
It is server-side state on the signed-in account, not a local filter, and it survives uninstalling the clone.

There is no per-hour, per-day, per-run, or per-target cap anywhere in the runtime.
The viewer-scoped attempt trail `attempts_threads_<viewer>` is a bounded 2,000-entry record that is appended to and trimmed but never read by any limit, and `automatic_attempts_threads_<viewer>` is deleted on every reservation and never read.

### Retired limit keys

Builds from before the passive-only model stored nine further keys.
`BlockLimitsStore.RETIRED_LIMIT_KEYS` is deletion-only: every successful save removes all nine, and no code path reads any of them back as configuration. The only other reference is the failed-commit rollback described above, which restores their prior values along with the two live keys.

- `limit_manual_min_delay_ms`
- `limit_manual_max_delay_ms`
- `limit_automatic_min_delay_ms`
- `limit_automatic_max_delay_ms`
- `limit_automatic_per_hour`
- `limit_target_budget`
- `limit_total_per_hour`
- `limit_total_per_day`
- `limit_max_per_run`

The controls those keys configured do not exist in this build.
A reader upgrading from an older install should expect the values to be deleted, not honoured.
Any note, screenshot, or document that presents them as live controls, or that describes half-second delay steps, describes a build that no longer exists.

## A report is created only by an explicit tap

The sole inline control opens one modal titled **Block and report** (Vietnamese: `Chặn và báo cáo`).
It shows the bounded target identity, the immutable post excerpt, a reason picker, the persisted **Also block this profile** checkbox, one positive action, a concise disclosure, and **Cancel**.
The positive action reads **Block** while the checkbox is checked and **Report** while it is unchecked, and the label updates live as the checkbox changes.

That tap is the entire authorization.
There is no separate consent checkbox, no payload preview, no editor, no `Review report` step, and no second confirmation.
There is also no one-click bypass, because the modal is the only entry point.
**Cancel** creates neither a report nor Block work.

Tapping the positive action always requests exactly one report.
The **Also block this profile** checkbox decides only whether the same tap additionally enqueues the native Block; it never decides whether a report is created.
The inline control has no path that blocks without reporting: the Block enqueue is reached only after the report queue call has been made.
The checkbox value persists in `ui_also_block_profile`.

`ReportController.queueFromForeground` is the only queue authority in the build.
It must run on the main looper, and it rejects the call unless the initiating Activity is still the live foreground Activity and is neither finishing nor destroyed, the initiating viewer ID is still the live signed-in viewer, the request passes `isValidForNewQueue`, and the reason is one of the seven accepted tokens.
A target equal to the active viewer is refused as a self-report.
Activity replacement, account change, or loss of foreground between opening the modal and tapping it rejects the enqueue rather than silently re-scoping it.

No automatic process can create a report.
No lifecycle callback, background worker, Block callback, retry path, Settings action, or passive matching run holds queue authority.
The row request factory returns data, not authority: it cannot queue, send, render a control, launch UI, or decide viewer eligibility while the host composes the row.

## What makes a request valid

A new report requires all of the following.

- A non-empty normalized profile username of at most 64 UTF-16 units: lowercased, leading `@` stripped, and restricted to `a`–`z`, `0`–`9`, `_`, and `.`.
- A profile ID of 4 to 24 decimal digits whose first digit is not zero.
- A non-empty post or reply excerpt, trimmed Unicode-safely to at most 280 UTF-16 units and never left with a dangling surrogate. A caption that cleans to empty becomes exactly `(no text in this post)`.
- One reason from `redbull`, `clone`, `impersonation`, `scam`, `harassment`, `spam`, or `other`.
- A same-row post permalink.

The permalink is accepted only over HTTPS from exactly `www.threads.com` or `www.threads.net`, with the raw authority equal to the host, no user-info, no explicit port, no query, no fragment, no percent-encoding in the path, exactly one `/post/` segment, and a path of `/@<normalized-username>/post/<shortcode>` whose username equals the request's own normalized username and whose shortcode uses only ASCII letters, digits, `_`, and `-`.
Every accepted permalink normalizes to `https://www.threads.com/@<username>/post/<shortcode>`, whichever of the two hosts it arrived on.

Missing username, an invalid or self ID, an empty excerpt, a missing or mismatched permalink, an unknown reason, lost initiating foreground or viewer context, a full outbox, or unsafe local storage rejects the request before any network delivery.

The mandatory-permalink rule applies to new requests only.
Durable rows written by an earlier build may carry an empty `targetUrl` with an empty `evidence` array; they stay readable, reviewable, retryable, and deletable, and they gain no authority to create a new report.

## Disclosure and wire payload

The modal carries a concise warning, and the Settings **Reports** card carries the complete disclosure, including the connection-side fields that never appear in the JSON.

The relay and backend store the full connection IP address, the full HTTP `User-Agent` (`ThreadsMod-CloneBlocker/1`), and network-derived city and country alongside the report.
Moderators and project operators can view and correlate those values, and server backups include them.
Server-side reports have no automatic expiry and remain until an administrator deletes them.
The clone cannot delete or recall a server copy.

The request body is a bounded JSON object with a closed key set.

| Field | Contract |
|---|---|
| `pseudonym` | Per-install and per-account pseudonym: `acct_` plus the first 24 lowercase hex characters of an HMAC-SHA-256 over `threads:<viewerId>`, keyed by a local 32-byte random secret |
| `platform` | Exactly `threads` |
| `targetId` | Required canonical 4–24 digit profile ID |
| `targetUser` | Required normalized profile username |
| `targetName` | Optional bounded display name, at most 120 UTF-16 units |
| `targetUrl` | Required canonical `https://www.threads.com/@<targetUser>/post/<shortcode>`, at most 300 UTF-16 units |
| `reason` | Required reason token |
| `note` | Empty compatibility field; the modal has no note editor |
| `quote` | Required normalized post or reply excerpt, at most 280 UTF-16 units |
| `evidence` | Exactly one entry, byte-identical to `targetUrl` |
| `tz` | Bounded device time-zone identifier, at most 64 UTF-16 units |
| `lang` | Bounded device language tag, at most 32 UTF-16 units |

The raw Threads viewer ID is used locally only to derive that pseudonym and a SHA-256 viewer storage scope.
The JSON body never contains `postId`, the raw viewer ID, the active `UserSession`, cookies, an access or bearer token, an authorization header, a Threads device identifier, the local row or item key, an IP address, a User-Agent, a city, or a country.
A permalink cannot smuggle credentials or token-like data, because user-info, ports, queries, fragments, percent-encoding, foreign hosts, extra path segments, and username mismatches all fail validation.
The four connection-side values named above arise outside the JSON and are stored server-side as disclosed.
Transport refuses to start while a process-wide `CookieHandler` default is installed, and re-checks after opening the connection.

## Exact endpoint policy

Exactly two write endpoints are authorized, both on the same reviewed host.

```text
https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/reports
https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/installs
```

`/v1/reports` is the only report destination.
`/v1/installs` receives only the activation-statistics ping described below, and never a report.
For both, the scheme, host, path, and the absence of a port, user-info, query, and fragment are checked exactly, and the reconstructed URL must equal the literal.
Redirects are refused, and there is no origin fallback, alternate report host, or configurable endpoint.
`tree55.com` is forbidden in canonical source and in the final DEX.

This relay has nothing to do with the Threads Block mutation.
Block runs through `ThreadsBlockBridge` and Threads' own authenticated client.
The reporting package contains no account-mutation call path.

## Activation statistics ping

The clone sends one activation-statistics ping per installed build to `/v1/installs`.
It is not opt-in.
`ModBootstrap.onResume` calls `InstallStats.maybeSend` under `AutoBlockSync.isEnabled`, and that method returns true for any non-null context and reads no preference, so the ping goes out on the first eligible foreground resume of every installation.
Passive blocking is likewise always on and has no user-facing switch, which is why there is no longer a gate for the caller to read.
The clone shows no first-run dialog; the Settings **Reports** card is the sole disclosure surface, and it names every field the ping carries.

The payload is a closed 13-key field set with a fixed key order and a restricted token charset, so the serialized form never needs escaping and a hostile device string cannot inject structure.

| Key | Contract |
|---|---|
| `v` | Payload schema version, currently `1` |
| `installId` | `inst_` plus the first 24 lowercase hex characters of an HMAC-SHA-256 over the fixed tag `install:v1`, keyed by a local 32-byte random secret |
| `packageName` | Clone package name, `app.tree55.threads` |
| `versionName` | `444.0.0.45.85-threadsmod.1` |
| `versionCode` | `511407878` |
| `modBuild` | Mod build number, currently `1` |
| `sdk` | Android SDK level |
| `manufacturer` | Device manufacturer |
| `model` | Device model |
| `abi` | Primary CPU ABI |
| `lang` | Bounded device language tag |
| `tz` | Bounded device time-zone identifier |
| `sentAt` | Send timestamp |

The install secret is generated locally and takes no account, advertising, or hardware identifier as input.
`installId` is therefore stable per installation, is not the reporting pseudonym above, and cannot be correlated to a Threads account.
No Threads account, target, username, permalink, post text, or free-text value appears in the ping.
Delivery is best effort on one bounded daemon thread: a failure is silent, leaves the ping due again on a later foreground resume, and can never affect Block, report, list, proxy, or updater work.
The relay additionally sees that request's connection IP address and User-Agent, as the Reports card discloses.

The `POST /v1/installs` route is deployed at the origin and the relay allowlist admits it, so a ping from this build would be accepted end to end.
That is backend state outside the APK transaction.
No ping from the published bytes has been sent or observed, because those bytes have never been installed or run on any device.

## Durable outbox, retry, and cancellation

After the positive action, payload preparation runs off the main thread.
The candidate install secret behind the pseudonym is committed only if it still reproduces that exact pseudonym, and the immutable `ReportPayload` is committed to the initiating viewer's outbox before any network worker can select it.
Each accepted action receives its own report ID and durable row, even when another report for the same profile is already pending.
Every delivery attempt is reserved synchronously in that outbox before the POST.
A failed or mismatched commit produces no network attempt.
The callback reports the local queue result only; it never claims server acceptance.

Delivery is foreground-only and single-flight for the active viewer.
Pending attempts use this ladder:

1. 30 seconds
2. 1 minute
3. 2 minutes
4. 5 minutes
5. 15 minutes
6. 1 hour
7. 6 hours
8. 12 hours, and every 12 hours thereafter

The foreground owner schedules the exact next wake, bounded at 24 hours per wake.
Only a 2xx response carrying a bounded, complete, valid-UTF-8, strict JSON root object whose unique `ok` member is the JSON boolean `true` removes the pending payload and records bounded local outcome history.
Malformed UTF-8, comments or single quotes, trailing data, duplicate member names including escape-equivalent ones, the string `"true"`, or a 2xx response without that acknowledgement is a retryable failure.
HTTP 403 is terminal.
Other HTTP and transport failures retry, and after 15 attempts the item leaves the outbox as an explicit `gave_up` history outcome rather than being silently discarded.
`gave_up` means delivery could not be confirmed, not that the server definitely rejected it, because a committed POST can lose its acknowledgement.
The UI says exactly that: `Delivery could not be confirmed after 15 attempts; the server may have accepted it. Review before reporting again.`

Requests are capped at 16 KiB, responses at 8 KiB, connect and read timeouts at 15 seconds each, and one drain sends at most 20 items before the status snapshot refreshes the UI.

Local bounds, per viewer:

- at most 1,000 pending reports;
- at most 500 bounded outcome-history records, with no time-based expiry;
- at most 16 KiB of UTF-8 for each stored report payload.

The outbox retains the full disclosed payload while an item is pending.
Terminal history retains only the bounded target username and ID, the outcome, the attempt count, and a timestamp.
A user can retry every eligible pending item, or confirm deletion of one unsent item, from the mod Activity.
Deletion fails once that item is an active delivery.
Because delivery and cancellation can race, a POST may finish before cancellation acquires the item, so a local delete never means a server copy was deleted.
Uninstalling clears the local outbox, history, and install secret, but cannot retract an accepted report.

### Storage is fail-closed

Report rows live in `threadsmod_reporting.db` at schema v2, with the reviewed fail-closed v1-to-v2 upgrade.
That upgrade preserves existing v1 rows and removed the old target-level uniqueness constraint, so a later post from the same profile cannot be silently deduplicated away.
No permalink column and no further report migration were introduced: the URL stays inside the existing bounded payload JSON.
The block list is a separate database, `threadsmod_blocklist.db`, at schema v3; see [07 — Clone Blocker auto-block](07-CLONE-BLOCKER-AUTO-BLOCK.md).

Before a foreground delivery generation can reserve anything, one asynchronous full snapshot verifies every bounded row, rejects a target equal to the raw in-memory viewer ID, and requires report IDs to be disjoint between the pending and terminal tables.
The raw viewer ID is used there for that equality check only, and no row stores it.
Activity or account replacement invalidates the trusted generation; a still-unwinding worker has its viewer, generation, and wake deadline rejected, and the replacement context receives a fresh drain.
A same-generation enqueue or manual retry that collides with a running worker records a scoped drain request, and completion re-enters the current store instead of trusting a stale snapshot.
Enqueue, attempt reservation, cancellation, retry, and terminal transitions are atomic, and after preflight each delivery touches only its indexed row.
History is trimmed only after the runtime itself inserts a verified terminal row, so an already oversize or corrupt table is preserved for review rather than silently reduced.

Malformed rows, oversize payloads, schema drift, and database corruption are never treated as empty and never reset or overwritten.
A wrong-typed or corrupt committed pseudonym secret surfaces immediately as its exact review state, even when outbox and history are both empty, and wake scheduling then selects no delivery.
Stored times beyond the reviewed plausibility horizon are treated as corruption; normal retry waits are exact, while any longer safe wait is scheduled in overflow-safe chunks so `Handler` arithmetic cannot create an immediate wake loop.

The UI's active viewer is separate from those durable rows.
Only the live signed-in Threads feed hook may publish it, and only in process memory.
The retired `ui_active_viewer` preference is deletion-only and its value is never trusted.
If the Activity or Settings is restored after process death, it shows no viewer scope and cannot inspect, retry, or delete report work until the user re-enters a signed-in feed in that new process.

## Version binding and what is not proven

The report and limit contracts are bound to one exact source set through the ordered catalog and the current [Threads 444 resolution](../patchlets/resolutions/444.0.0.45.85/resolution.json), with the split inputs, derived source identity, and private-seam review recorded in the accompanying [evidence](../patchlets/resolutions/444.0.0.45.85/EVIDENCE.md).
Obfuscated Threads descriptors stay in the resolution or in rendered Smali; stable Java receives normalized values only and contains no private host descriptor.
Any future APK whose username, caption, permalink, action-row, identity binding, one-control topology, constructor flow, or register evidence drifts fails closed.
Re-resolve it with the bounded [`RESOLVE-INLINE-REPORT.md`](../patchlets/ai/tasks/RESOLVE-INLINE-REPORT.md) task rather than copying the current obfuscated names.

Everything above is a source and static-gate contract.
No published build has ever been installed or run on a device, and every published release replay records `runtimeValidation: not-run`.
Nothing here proves device rendering, live row shape, account state, a real Threads Block mutation, server acceptance of a report, cancellation timing, or delivery behaviour on a phone.
Those need separate deliberate tests with controlled data and an account and device prepared for the risk.

Release artifacts, sizes, hashes, and the revision history behind them are recorded in [`CHANGELOG.md`](CHANGELOG.md).
The Settings and Activity surfaces that display this state are described in [09 — Activity, Settings, and inline Block](09-ACTIVITY-SETTINGS-AND-INLINE-BLOCK.md), and the passive matching loop these delays pace is described in [12 — Passive blocking](12-PASSIVE-BLOCKING.md).
