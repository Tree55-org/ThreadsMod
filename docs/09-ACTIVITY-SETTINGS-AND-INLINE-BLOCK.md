# Activity, settings, and inline controls

This document owns the user-visible contract of the Clone Blocker clone: the two private mod screens,
the single inline Block control on post and reply rows,
and the combined modal that control opens.
It states what the code does today.
Release history, revision numbers and per-build evidence live in [CHANGELOG.md](CHANGELOG.md);
pacing and report policy in [reporting and limits](10-REPORTING-AND-LIMITS.md);
the passive scheduler in [indexed passive blocking](12-PASSIVE-BLOCKING.md).

Nothing described here has been exercised on a device.
Every published build records `runtimeValidation: not-run`,
so every claim below is a source and signed-DEX contract, not observed behaviour.

## What the mod adds

The mod ports the useful management concepts from `CloneBlockerExtension` into Android
and places one Block control beside the native post and reply actions.
One exact-SHA helper in the host row class resolves a single immutable author/media snapshot,
and one memory-only callback reports when that exact action row is in the clipped viewport.
The control always opens one **Block and report** modal:
every positive action durably queues a report,
while a persisted **Also block this profile** checkbox independently adds the same target
to the shared Block scheduler. Passive visibility never creates a report.

Passive blocking is always on.
There is no opt-in, no switch, and no in-app way to stop it:
`AutoBlockSync.isEnabled` returns true for any non-null context and reads no preference,
and `AutoBlockSync.disable(Context)` does not exist.
The Settings screen discloses the behaviour instead of gating it.
Blocks are real server-side account state on the signed-in Threads account;
they survive uninstalling the clone and are not undone by removing it.

Patchlet 050 owns both private activities, `CloneBlockerUi`, the drawer row and the manifest entries;
patchlet 060 the inline control, its host rewrites, the modal and the viewport observer;
patchlet 070 the report factory that consumes the same row snapshot.
Patchlet 020 supplies the scheduler, limits, diagnostics and viewer-scoped state,
patchlet 030 the exact-SHA private bridge, patchlet 080 the Proxy Settings destination,
and patchlet 090 the blocking signed-DEX proofs.
None of this is a manual edit to a decoded or built APK: every patchlet requires an exact
source-APK SHA-256 resolution, exact anchors, one-owner metadata, no-op reapplication,
and blocking release gates.

## Settings screen

`com.threadsmod.CloneBlockerSettingsActivity` is a resource-free screen with no ActionBar.
Its header is the title **Settings** and one **Activity** button that opens the Activity screen.
Below the header is one line of intro copy:
`Control passive on-screen blocking and the inline Block action. Settings stay on this device.`

The screen is seven cards, in this order.

| Card | Contents |
| --- | --- |
| **Current status** | live status text and a **Sync now** button |
| **Passive blocking** | a static `Always on.` description; no switch |
| **SOCKS5 proxy** | live proxy status, a one-line summary, and a **Configure proxy** button |
| **Inline action** | the **Also block this profile** switch |
| **Passive delay** | the two delay fields, **Save delay**, and **Use 4–10 seconds** |
| **Reports** | report counts, delivery state, the full privacy disclosure, and **Open report outbox** |
| **Mirror-only list access** | how signed lists are fetched, and what the request does not carry |

### Current status

The status text is the word `Enabled`, then the viewer-scoped status sentence, then a blank line, then five list lines:

```
List fetch: <phase>
Records: <installed id rows>
New this refresh: <new ids in the last refresh>
Database index: Ready · generation <n>
Inline control: <hook and render counters for this process>
```

`List fetch:` reports one closed phase, or a failure naming one closed class per mirror,
such as `Failed — previous index retained (mirror 1 too_large)`.
The failure class is chosen by exception type, never from a message, URL, header, or response body.
Until a signed-in foreground session supplies a live status,
the status sentence falls back to `Enabled; waiting for a signed-in foreground session.`,
and that fallback never reads the stored `enabled` preference for any decision.
`Inline control:` reports `not observed in this process` until the host hook runs,
then bounded per-process counters only; it logs no account data.

**Sync now** verifies and indexes the signed list.
It does not queue the list for blocking, and it is disabled while a sync or list refresh is already running.
The screen polls this card once a second while resumed and stops on pause;
if Android refuses the poll, the card appends
`Unavailable: live block-list status refresh stopped. Reopen this page.` in the danger colour.

### Passive blocking

One static sentence, with no control beside it:

> Always on. Refreshes the signed index every 10 minutes in the foreground, then blocks only listed profiles whose post or reply action row becomes visible.

Refresh runs on an exact ten-minute cadence only while the clone is foregrounded with a valid live viewer,
and catches up on resume.
The card makes no Android background-scheduling claim, because the mod schedules no background work.

### SOCKS5 proxy

The card shows the live proxy status token, a one-line description of app-scoped SOCKS5 routing
with ordered numeric IP/CIDR direct exceptions, and a **Configure proxy** button
that opens the private `com.threadsmod.ProxySettingsActivity`.
Any status beginning `Paused`, `Unprotected`, or `Unavailable` is drawn in the danger colour.
Settings reads that token when it builds the card and again on every resume; it runs no proxy poll of its own.
The 500 ms lifecycle-bounded polling with checked Handler rejection lives in Proxy Settings.
See [SOCKS5 proxy](11-SOCKS5-PROXY.md) for what each status token means and what it does not protect.

### Inline action

One switch, **Also block this profile**, default on,
backed by the single persisted interaction key `ui_also_block_profile`.
It sets the initial checkbox state in every **Block and report** modal.
Turning it off changes the modal's positive action to **Report**;
it does not suppress report creation.

### Passive delay

This card is the only limit configuration the build has.
`BlockLimits` declares exactly two user-configurable fields.

| Field | Range | Step | Default |
| --- | --- | --- | --- |
| passive minimum delay | 2–60 seconds | whole seconds | 4 seconds |
| passive maximum delay | 3–60 seconds | whole seconds | 10 seconds |

`BlockLimits.checked` rejects any value where `value % 1000 != 0`
with `must use whole-second steps`, rejects out-of-range values,
and rejects a minimum greater than the maximum.
There are no half-second steps and no other configurable limit.
Nine keys from the retired limit model — the manual and automatic delay pairs,
`limit_automatic_per_hour`, `limit_target_budget`, `limit_total_per_hour`, `limit_total_per_day`
and `limit_max_per_run` — survive only in `BlockLimitsStore`'s deletion-only
`RETIRED_LIMIT_KEYS` array, which removes them in the same commit that writes a new delay pair.
They are not readable, not configurable and not enforced.

**Manual inline Block is unpaced and uncapped.**
The card says so twice, and the runtime agrees:
only passive work consults `BlockLimitsStore.isValid`.
The delay pair is parsed, range-checked, step-checked, order-checked and committed atomically;
no partial pair is ever applied.
Missing configuration is valid defaults; partial, mistyped or out-of-range stored state is not,
and while stored state is invalid, passive blocking is paused
until one complete valid pair is saved or **Use 4–10 seconds** restores the default.
How those delays are consumed is in [reporting and limits](10-REPORTING-AND-LIMITS.md),
which is the canonical owner of every limit in this build.

### Reports

The card shows the viewer-scoped counts `Pending`, `Sent (retained)`, `Rejected` and `Unconfirmed`,
then delivery state, then the complete privacy and retention disclosure,
then an **Open report outbox** button that opens the Activity screen.

This card is the build's privacy statement, and it carries the disclosure in full:
that a report is created only when you tap Block or Report in the combined modal;
the whole payload, including the canonical post permalink carried as `targetUrl` and the sole `evidence` entry;
that the relay stores the connection IP address, full User-Agent and network-derived city and country,
that moderators and project operators can view and correlate them, that backups include them,
and that server-side reports have no automatic expiry before administrative deletion;
that the JSON never contains the raw viewer ID, Threads cookies, session or access token;
that pending payloads can remain viewer-scoped indefinitely and retry only while Threads is foregrounded;
that local terminal history keeps at most 500 records with no time-based expiry;
and that cancellation can race active delivery and cannot retract a server-accepted copy.
It also discloses the activation ping, which is unconditional and gated on no opt-in:
one ping per installed build to `/v1/installs` on the same relay host,
carrying an install identifier derived from a local random secret with no account input
plus build and device metadata, never linked to a Threads account or to a report.
The exact payload is in [reporting and limits](10-REPORTING-AND-LIMITS.md).

### Mirror-only list access

Signed blocklists are read only from the reviewed HTTPS mirror allowlist.
Redirects are refused, payload size is capped, and Ed25519 verification is required.
The list request receives no Threads cookie, token, session object, or account ID;
blocks use Threads' own signed-in native action.

### Fail-closed shell

If local settings cannot be rendered, the screen replaces its content with one
**Settings data needs review** card in the danger colour,
which states that stored data was not reset, that blocking stays paused,
and that an active Android VPN stays fail-closed while direct traffic may continue without one.
Settings never submits a report and exposes no endpoint editor.

### Reaching the screen

The page is reachable from a keyed native row labelled **Clone Blocker settings**
at the true bottom of the left feed-menu drawer, immediately before its bottom spacer.
The [Threads 444 resolution](../patchlets/resolutions/444.0.0.45.85/resolution.json) binds two drawer hosts,
one per drawer layout the source APK ships,
with their raw-Smali basis recorded in [EVIDENCE.md](../patchlets/resolutions/444.0.0.45.85/EVIDENCE.md).
The click path launches only the already registered private Settings activity;
it creates no launcher entry and no exported route.
Both mod activities are declared `android:exported="false"`,
`android:excludeFromRecents="true"`, `singleTop`, portrait, and carry no intent filters.

## Activity screen

`com.threadsmod.CloneBlockerActivity` is a viewer-scoped operational view.
Its header is the title **Activity** plus **Refresh** and **Settings** buttons,
followed by the viewer scope line, either `Viewer scope: Threads account <id>`
or `Open a signed-in Threads feed to select its local activity scope.`
Failure and runtime status intentionally precede metrics and history, so the sections run:
**Needs attention**, **Current status**, **Overview**, **Passive block list**,
**Report outbox**, **Manual queue**, **History**.

**Needs attention** appears only when a viewer-scoped alert or a failure-like status exists.
It renders the bounded message in the danger colour with its diagnostic code and timestamp and,
when a viewer is in scope, a **Clear notices** button that clears that viewer's alerts and rebuilds the page.
**Current status** repeats the Settings status card's sentence and five list lines, plus a `State:` line.
**Passive block list** repeats the ten-minute foreground refresh description and offers **Sync now**.
The six **Overview** tiles are:

| Tile | Value |
| --- | --- |
| Blocked | completed blocks for this viewer |
| Queued | items waiting in the manual queue |
| Last hour | attempts in the last hour |
| Today | attempts today |
| Failed / abandoned | terminal failures plus abandoned inline work |
| Indexed profiles | installed id rows in the local signed-list store |

**Indexed profiles** is the store's installed row count, not the size of the signed list on the mirror.
Handle-only rows are counted during a refresh but never indexed, so they do not appear here,
and an invalid store reports zero.
It is the same number as the `Records:` line on both status cards.

The **Report outbox** lists at most 20 pending rows, each with a **Delete** button
that reads **Sending** while delivery is active.
Deleting asks for confirmation, fails for active delivery, cannot recall a server-accepted report,
and does not erase corrupt storage; its **Retry all** makes pending reports eligible on the next
foreground return.
The **Manual queue** lists at most 30 items and **History** at most 40 entries,
filtered by **All**, **Blocked**, **Failed**, **Abandoned** or **Queued**.

The Manual queue's **Retry** and **Retry all** are the only completion-review escape.
In one atomic preference commit they transition only the selected retryable manual items,
remove their matching quarantine and clear the corresponding process-local latch.
They do not reset unrelated queued or running work,
and they refuse to act at all if the stored completion-review set is itself invalid.

The active viewer exists only in process memory after validation by the live signed-in feed hook,
so restoring either private activity after process death shows no account scope
and cannot read, retry or delete a report until the feed is re-entered.
Blocking records never store a Threads session, cookie, access token or mirror response body.
If local activity state cannot be rendered, the screen keeps its header and shows one
**Activity data needs review** card stating that blocking remains fail-closed and stored data was not reset.

## Inline post and reply control

The extension uses one Threads pressable-container injector for both posts and replies.
The APK evidence likewise resolves a shared dense UFI action row,
so the mod adds one action-row hook rather than inventing an unrelated comment hook.

The row's UFI configuration class carries exactly two injected fields: the media ID and the immutable request.
Immediately after that configuration object is constructed,
the binding obtains the current session and calls one host-owned helper, which resolves exactly once
the displayed media ID, the media through the active session, that media's displayed author,
the author's numeric Threads ID and username,
and one host-bound immutable request holding the media key, numeric target, bounded label,
opaque author model and opaque media model.
The helper trims the username and prefixes `@` only when needed,
skips missing or invalid IDs and the active viewer,
retains valid report-capable rows whose author is already blocked,
and holds the exact native author and media models only as opaque `Object` values.
Stable code downstream may use only the request's getters, and patchlet 070's factory
reads the caption and permalink from the same captured media,
so neither stable path repeats private media, author or ID resolution.

One exact rewrite in the action row replaces the native Share call and the config load that follows it.
It preserves the Share call, snapshots the style, composer, config, request and the two native long colours,
then invokes exactly one `InlineActionRowAdapter.render`,
so the Block control is a parent-row sibling rendered after Share rather than a child inside Share's container.
There is no second report sibling and no legacy Report render or tag in that rewrite.
The adapter rejects a null report request before any Compose state, click, visibility, or render authority;
every valid report-capable Block state stays visible.

One remembered observer is attached to that same sole control.
It reports visible only for attached coordinates with non-empty clipped root bounds,
deduplicates transitions, unregisters on forgotten or abandoned lifecycle state,
and calls only the bounded memory registration API, so SQLite lookup, list fetch,
scheduler selection, reporting and bridge dispatch all stay off the Compose thread.
Its main-thread authority rules are in [indexed passive blocking](12-PASSIVE-BLOCKING.md).

The reviewed seam covers post and reply UFI action rows, including those rendered in profile post lists.
It does not cover a profile header, a search result, or a follower/following list.

## Block and report modal

At click time the controller prevents double fire and binds the dialog to the initiating activity and viewer.
It always opens one compact **Block and report** modal, localized English or Vietnamese, containing:

- the bounded `@username` label and the numeric profile ID;
- the immutable post excerpt, selectable, capped at 280 UTF-16 units;
- a report reason chooser;
- the persisted **Also block this profile** checkbox;
- a concise disclosure that the report is queued for background delivery,
  that the server operator may receive a stable pseudonym, language and time zone, IP address,
  User-Agent and approximate location,
  and that cancellation can fail once delivery is active while an accepted report cannot be recalled;
- one dynamic positive action reading **Block** while the checkbox is checked and **Report** when it is not;
- **Cancel**.

There is no dedicated Report button, no one-click bypass, no separate editor or review step,
no note field, and no extra consent checkbox.
The label is local chooser, queue and history metadata only; it never enters the private bridge as identity.

Every positive action queues a distinct viewer-scoped report row
and starts foreground-only delivery only after that durable commit.
When **Also block this profile** is checked,
the controller also persists the request in the viewer-scoped manual Block queue,
and only after that durable commit may the scheduler stage the opaque author model
as a transient process-only hint keyed by viewer and target,
capped at 64 entries and expired after ten minutes.
The scheduler marks the item running and reserves the attempt before consuming that hint.

The stable controller never inspects private row objects, resolves an author ID,
or calls an already-blocked or mutation seam.
Only the SHA-bound `ThreadsBlockBridge` casts the hint, re-reads its canonical numeric ID,
and requires equality with the immutable request target before mutating;
a missing, expired or scope-mismatched hint and all restored manual work fall back
to the immutable numeric ID with the bridge's cache-first, session get-or-create path,
and passive work never uses a hint at all.
Nothing reaches mutation unless the exact model ID matches.
The admission ordering and stage vocabulary behind this are in
[indexed passive blocking](12-PASSIVE-BLOCKING.md) and [Clone Blocker auto-block](07-CLONE-BLOCKER-AUTO-BLOCK.md).

## Diagnostics

Everything the two screens display about a failure comes from the closed `BlockDiagnostic` map.
History detail, Activity status and alerts, and log lines are bounded to 120, 240 and 200 characters.
They contain no target or viewer ID, username, URL, payload, host object,
server response, exception text or echoed unknown stage;
they state `mirror=n/a` plus bridge revision `bridge=r6`;
and each failure carries a fixed code, such as `CB-BRG-112` for `model_id_exception`.
Every terminal branch before durable inline enqueue records exactly once before the UI callback;
after enqueue, only the scheduler records it.

A confirmed native Block whose local completion cannot be persisted is never reinterpreted
as a transient failure: the target enters viewer-scoped completion-review quarantine,
which creates no backoff, no automatic queue and no automatic retry,
and inline queue items stay abandoned until the Activity's explicit atomic Retry removes it.
After an in-place upgrade an older `signed_list_block_failed` alert or history item may remain
until **Activity > Clear notices** is used; the current build does not emit it.

## Animation and success semantics

The control has distinct idle, confirming, queued, started, success and failure states.

- Native start drives the visible native action pulse.
- Failure or cancellation returns the control from the working state and never shows success.
- Only the native success callback changes the control to the green success check,
  which the adapter renders by swapping in the resolved success icon.
- After the success hold the sole report-capable entry returns;
  an already-blocked result does not remove it.
- Enqueue and native start are never presented as success.

The controller holds the success state for 1,500 ms before restoring the report-capable entry.
`InlineBlockController` also publishes `SUCCESS_HOLD_MS = 550` and `SUCCESS_COLOR_ARGB = 0xff2e9e5b`
as the hold-and-colour contract the native Compose adapter is expected to mirror.

The patch does not claim it can always animate or remove the entire post or reply row.
After the block succeeds, Threads may remove the row as part of its own feed refresh.
If Threads does not refresh that surface,
only the mod control's callback-driven animation and dismissal are guaranteed by this design.

## Account and network safety

- Modifying the APK voids Meta's signature;
  the clone is re-signed with a separate key and is not the app Meta shipped.
- Blocks are real server-side account state on the signed-in Threads account and survive uninstalling the clone.
- Passive blocking is always on with no off switch; the Settings screen discloses it rather than gating it.
- Every explicit positive action in the modal queues a report;
  optional Block occurs only when the persisted checkbox is checked and always uses the shared scheduler.
  Background work cannot create a new report, and a target must be numeric and cannot equal the active viewer.
- List reads consult three fixed v3 bases in order, verify the signed root
  `<base>blocklist/v3/manifest.json` at each, install only the strictly newest signed root,
  and accept an object only when its signed 64-hex name validates before any URL text is formed
  and its bytes hash to that name before parse.
  The retired whole-file `blocklist.json` URLs are not compiled,
  and every `tree55.com` hostname is forbidden in source and in the final DEX.
- Writes have exactly two reviewed destinations on one AWS host:
  `/v1/reports` for a consented report, only after the explicit combined-modal positive tap and durable queuing,
  and `/v1/installs` for one unconditional activation ping per installed build.
  There is no write fallback and no third-party analytics SDK.
- Required in-app updates are noncancelable and Update-only, and downloaded bytes cannot reach
  Android's visible installer until exact size, hash, package, version, and signer continuity pass.
  See [signed in-app updates](13-IN-APP-UPDATES.md).
- The clone installs beside official Threads and beside a historical `com.threadsmod.barcelona` clone,
  which is a retired application ID this build no longer uses;
  the in-app updater cannot bridge package names.

## Rewrite rules and ownership

Patchlet 050 owns both activities, `CloneBlockerUi`, the `threadsmod.drawer` templates,
both manifest activity components, rule `register-clone-blocker-activities`
in `settings-manifest-rewrites.json`, the drawer hook rules in `drawer-settings-rewrites.json`,
and only the persisted `ui_also_block_profile` interaction key.
It displays but does not own limit or report storage.

The 444 resolution defines two drawer hook rules,
`drawer-settings-button-hook-v1` and `drawer-settings-button-hook-v2`,
one per drawer layout the source APK ships,
both keyed to the drawer's bottom spacer and both labelled **Clone Blocker settings**.
The unsuffixed `drawer-settings-button-hook` exists only in the retired 415 resolution,
and patchlet 050 declares all three because catalog validation requires every owned rule
to exist in the union of the two reviewed resolutions.

Patchlet 060 owns the `threadsmod.inlinecontrol` class family and its strings,
the media-ID carrier and the shared post/reply action-row host hook,
the one request-and-model-keyed clipped-viewport observer and its Compose lifecycle route,
the single exact-host author/media/ID/username capture and its opaque handoff through stable code,
and the trimmed, `@`-prefixed, 80-character-bounded local label —
never the report payload and never mutation identity.
Its `inline-control-rewrites.json` in the 444 resolution defines four active rules:
`inline-media-id-field`, `inline-media-id-bind`, `inline-action-row-hook`,
and `inline-author-snapshot-host-method`.
`inline-action-spacing-capture` is **not** among them.
It exists only in the retired 415 resolution,
where the Share-adjacent Compose object had to be preserved in a spare register
before a later popup path overwrote it.
The 444 topology pre-binds the immutable request into the UFI configuration object,
so the single action-row rule preserves the Share call itself and needs no separate spacing capture.
Patchlet 060 still lists the rule in its ownership set, and that is correct rather than stale:
catalog validation requires every owned rule id to exist in the union of the two reviewed rewrite sets,
the host-asset check accepts zero or one spacing rule and fails only on more than one,
and `EVIDENCE.md` records the arrangement explicitly.

Patchlet 070 owns all `threadsmod.reporting` descriptors, the shared-request report factory template,
the caption and permalink proofs taken from that same opaque media model,
the viewer-scoped SQLite outbox and history tables, and the reviewed AWS report POST contract.
The target username, canonical 4–24 digit ID, non-empty Unicode-safe 280-UTF-16-unit excerpt,
and canonical `https://www.threads.com/@<username>/post/<shortcode>` permalink are immutable,
and that URL is written identically to `targetUrl` and to the sole `evidence[0]`.
See [reporting and limits](10-REPORTING-AND-LIMITS.md).

## For a future Threads APK

Do not copy the current obfuscated descriptors.
Build a deterministic candidate and evidence inventory
and use [`RESOLVE-DRAWER-SETTINGS.md`](../patchlets/ai/tasks/RESOLVE-DRAWER-SETTINGS.md),
[`RESOLVE-INLINE-ACTION-ROW.md`](../patchlets/ai/tasks/RESOLVE-INLINE-ACTION-ROW.md),
[`RESOLVE-PASSIVE-BLOCKING.md`](../patchlets/ai/tasks/RESOLVE-PASSIVE-BLOCKING.md),
and [`RESOLVE-INLINE-REPORT.md`](../patchlets/ai/tasks/RESOLVE-INLINE-REPORT.md) in proposal-only mode.
Human review is mandatory for drawer placement, both action-row topology anchors,
sole-control topology, the one host-owned media/author/ID/username/model snapshot,
the sole memory-only clipped-viewport observer and its cleanup, explicit post-and-reply-only coverage,
zero stable-code private re-resolution, and bridge-side model-ID equality with null fallback.
Any unresolved role or ambiguous anchor fails closed.
See [AI-driven patchlets](08-AI-DRIVEN-PATCHLETS.md) for how those tasks are run and reviewed.

## Validation boundary

These are source and signed-DEX contracts, not live Threads evidence.
The obfuscated session, cache, model, ID, and already-blocked bindings
require human review for this exact source SHA.
All seams are exact-SHA and fail closed on drift.
Targeted JADX is secondary readable evidence only;
a decompiler-rendered catch value is not authoritative, and raw signed DEX decides.

**No published build has ever been installed or run on a device,
and every published release records `runtimeValidation: not-run`.**
The only device evidence anywhere in this project is an isolated, no-permission Activity UI probe
on an emulator: for the Threads 444 builds it ran against a review candidate whose bytes differ
from the published artifact, and for the last Threads 415 build against that build's exact primary
DEX repackaged behind a no-permission manifest. No probe ever launched a published APK.
It records no account or network action and proves screen construction only —
that the Activity, Settings and Proxy Settings screens build with specific node texts present.

A device and account test is still required to establish cache-placeholder behaviour,
the native predicate's real state, row-to-account timing, actual Block outcomes,
row-visibility behaviour, database behaviour at real list sizes, and report delivery.
Current coverage is post and reply action rows and must not be described as profile-header coverage.
Such a test should install the separate clone beside official Threads
and use a disposable account, a disposable profile and controlled target data;
blocks made during it are real and persist on the account after the clone is removed.

Historical build-by-build evidence, superseded artifacts, and failed replays
are recorded in [CHANGELOG.md](CHANGELOG.md).
