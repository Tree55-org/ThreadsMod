# Server-driven auto-block: feasibility and design

## Decision

A true account block is only possible in-process.
Blocking is a server-side mutation on Threads' own account graph, and reaching it needs two things that exist only inside the running app: the live `UserSession` the foreground activity already holds, and the private, obfuscated mobile API stack layered on top of it.
Meta's public Threads API cannot block a profile at all.
Its documented surface covers publishing, media retrieval, reply management, users, insights, and oEmbed, and it contains no block or unblock operation.
A companion app, a hosted service, or a public-API integration can therefore hide replies on posts you own, but it cannot block anybody.

That finding is why Clone Blocker is an APK patch rather than a separate app.
The mutation is issued from the foreground process, with the activity's non-null `UserSession`, through Threads' own authenticated block helper.
The mod calls the app's existing block path from one isolated helper; it does not re-implement the request.

The costs of that route are real and cannot be designed away.
This is a private, obfuscated API, brittle across releases, and automating it may violate Meta's terms or trigger account enforcement.
Patching and re-signing the APK voids Meta's signature, so the result is a different application that neither Google Play nor Meta's own update path recognises.
A block is durable server-side account state: it survives uninstalling the clone, and removing a profile from the block list never unblocks anyone.
No published build has been installed on a device, and `runtimeValidation` is `not-run` for every release, so every runtime statement in this document is a design and static-analysis claim rather than an observed one.
If hiding replies on your own posts is sufficient, use the supported public-API route described under Alternatives instead of modifying the APK.

## Historical Threads 415 research call chain

Threads 415-era research evidence, kept for provenance only; its decompiled paths, obfuscated class names, and operation codes are not authority for the current version.

Current version-bound mappings and the review boundary live in the [Threads 444 resolution](../patchlets/resolutions/444.0.0.45.85/resolution.json) and its [raw-Smali evidence](../patchlets/resolutions/444.0.0.45.85/EVIDENCE.md).
Decompiler output lives under `decompiled/`, which is not published; the paths below are cited as provenance, not as links a reader can follow.

| Step | Local evidence | Finding |
|---|---|---|
| App/launcher | `decompiled/jadx-1.5.6/resources/AndroidManifest.xml:133-184` | `BarcelonaAppShell` launches `BarcelonaActivity`; `INTERNET` permission is present at line 40. |
| Foreground session | `decompiled/jadx-1.5.6/sources/com/instagram/barcelona/mainactivity/BarcelonaActivity.java:2028-2047` | `onResume()` reads `this.A01`, throws if it is null, then performs foreground work. |
| Exact smali hook | `decompiled/apktool-3.0.3/smali/com/instagram/barcelona/mainactivity/BarcelonaActivity.smali:6964-6998` | Register `v6` holds the non-null `UserSession` after the branch at line 6998. |
| Single-block caller | `decompiled/jadx-1.5.6/sources/p000X/C39345HhN.java:9-39` | Took a numeric target ID, read the user model from cache or fetched it, then called the block helper with operation `0`. |
| User fetch by ID | `decompiled/jadx-1.5.6/sources/p000X/C40578Igx.java:22-35` | The authenticated profile-info path. It is decompilation evidence only and is not rendered into the current bridge. |
| User fetch by name | `decompiled/jadx-1.5.6/sources/com/instagram/repository/user/UserNetworkDataSource.java:38-67` | Supports `users/{user_name}/usernameinfo/`. |
| Block request | `decompiled/jadx-1.5.6/sources/p000X/AbstractC32622DNo.java:217-272` | Builds `friendships/block/%s/` with `user_id`, `surface`, `container_module`, callback, and scheduler. |
| Bytecode confirmation | `decompiled/apktool-3.0.3/smali_classes7/X/DNo.smali:201-249,319-348` | Confirms the block branch, parameters, request creation, callback attachment, and queue submission. |
| Current blocked list | `decompiled/jadx-1.5.6/sources/p000X/AbstractC215728Wl.java:6-13` | Pages `users/blocked_list/` using optional `max_id`. |

On 415 the request also sent `is_auto_block_enabled`.
`X/064.smali` resolved that literal, and operation `0` sent it as false.
In this app it describes Threads/Instagram's existing "also block related or future accounts" behaviour; it is not Clone Blocker's server-list sync feature.

Operation `2` used the same one-target endpoint with `is_auto_block_enabled=true`; analytics called it a multi-block outcome, but it was not a batch primitive for arbitrary server targets.
Operation `3` called `friendships/block_all_suggested_blocks/`, which is specifically Meta's suggested-block set and likewise cannot accept a custom list.
There is no server-side batch block for an arbitrary list, on 415 or since, so the design has always been one target per request.

The 415 blocked-list parser read `blocked_list` and `next_max_id`, with rows carrying `user_id`, username, profile metadata, interop fields, and `is_auto_block_enabled`.
A reconciliation built on it would have to follow every page until `next_max_id` is absent before claiming completeness.
The shipped mod does not page `users/blocked_list/` at all.
It reads Threads' own already-blocked predicate against the cached user model instead, which needs no extra authenticated request.

## Current bridge topology and safety contract

On Threads 444 the resolution binds every private symbol the bridge touches, and the build fails closed if any of them moves.

| Role | Resolved 444 symbol |
|---|---|
| Session | `Lcom/instagram/common/session/UserSession;` |
| User model | `Lcom/instagram/user/model/User;` |
| Model ID accessor | `Lcom/instagram/user/model/User;->getId()Ljava/lang/String;` |
| Ordinary cache lookup | `LX/0036;->A0a(Lcom/instagram/common/session/UserSession;Ljava/lang/String;)Lcom/instagram/user/model/User;` |
| Cache factory | `Lcom/instagram/user/model/UserCache;->A00(Lcom/instagram/common/session/UserSession;)Lcom/instagram/user/model/UserCache;` |
| Get-or-create by ID | `Lcom/instagram/user/model/UserCache;->A05(LX/02ft;Ljava/lang/String;)Lcom/instagram/user/model/User;` |
| Already-blocked predicate | `Lcom/instagram/user/model/UserExtKt;->A0I(Lcom/instagram/user/model/User;)Z` |
| Block endpoint literal | `friendships/block/%s/` in `smali_classes6/X/0AN9.smali` |
| Block mutation helper | `LX/0AND;->A00(...)`, 13 arguments |
| Mutation callback interface | `LX/0LnI;` (`DWP` started, `Dan` failure, `DtY` ended, `onSuccess`, `onCancel`) |
| Surface and container module | `ig_text_feed_profile` |

Calling Threads' own helper rather than hand-building the HTTP request is the safer choice, because the helper owns the optimistic model and cache work, the analytics, the callbacks, and the failure UI.
It applies optimistic relationship state before transport; the failure path invokes the supplied failure callback and rolls that state back, and the success path calls `onSuccess()`, records the outcome, parses relationship fields, and refreshes cache state.
The cost is that the helper can surface Threads' own UI messages while a run is in progress.
Any custom queue must preserve those callbacks and must never mark a target successful merely because a request was enqueued.

The bridge has two mutation entries and one shared mutation body.
The direct-ID entry isolates the session cast, the ordinary-cache lookup, the cache factory, and placeholder get-or-create in separate try regions before dispatching outside them.
The resolved-row entry separately isolates the session and opaque-model casts before the same dispatch.
A callback-free `prepareModel` isolates only the private model-ID accessor and the already-blocked predicate.
`blockModel` interprets its fixed mismatch, already-blocked, or mutation-ready result outside any try, and separately protects only the `prepareModel` invocation and the native mutation invoke.
There is no shared mutable failure-stage register and no broad `Throwable` region spanning several seams.

`passivePreflight(session, targetId)` is the passive-only, callback-free entry.
It performs the same cache-first model construction, the exact numeric-ID check, and the native already-blocked predicate, and it performs no mutation, callback, report, scheduler transition, or persistence.
It runs before passive-delay reservation and before `passive_running` persistence, so a profile Threads already reports as blocked consumes no configured delay and no attempt reservation.
A mutation-ready result may proceed; a fixed failure stage fails closed.
The normal bridge then deliberately repeats the exact-ID preparation and the already-blocked predicate immediately before mutation, so state drift after the preflight cannot authorise a stale decision.

No bridge or native adapter invokes a mod callback directly.
Every cast, cache, preparation, already-blocked and error result, plus the native started, failure, and success callbacks, enters the stable `BridgeCallbackDispatcher`.
Its `Handler.post` hop guarantees that mod callback bodies run only after the synchronous bridge, host, and scheduler stacks unwind, so a failure inside a mod callback cannot be caught and mislabelled as `bridge_exception` or `mutation_exception`.
The bridge maps `model_id_exception` and `already_blocked_exception` to the identifier-free codes `CB-BRG-112` and `CB-BRG-113`, with bounded diagnostic output.

This topology is not accepted from source or decompiler appearance alone.
The signed-primary-DEX instruction and value-flow verifier must prove `passivePreflight` entry reachability, its exact cache/model/ID/predicate flow, its fixed callback-free results, its sole passive caller, and its position after the initial membership check but before the post-preflight and final membership rechecks, the passive delay, and running-state effects.
It must also prove the exact `AutoBlockSync$BlockRun`, `AutoBlockSync$ManualBlockRun`, and normal bridge-owner call provenance with zero other callers; the native callback interface; resolution-owned private calls; immutable target and model-ID flow; narrow try and handler boundaries; fixed stage and result register flow; every normal bridge and native dispatcher route; zero direct mod callbacks outside `Delivery.run`; the checked `Handler.post` firewall; the ordinary bridge recheck; and native mutation identity.
Alias-free targeted JADX is complementary readable evidence; it may not replace signed-DEX value-flow results.

The inline and manual entry has its own exact-SHA ownership boundary.
The host helper resolves the row's private media, author, numeric ID, username, author model, and media model once, and seals them into one immutable request.
The report path consumes that request for the report every combined-modal positive action durably queues, while the persisted `Also block this profile` choice independently lets Block consume the same numeric target and opaque author model through the shared scheduler.
The report factory reads caption and permalink from the same captured media, and new queues require the canonical current Threads URL.
Stable inline and report code contains no raw private author-ID, media lookup, author lookup, username accessor, or already-blocked seam.
The release gate resolution-pins the exact eleven-string `AutoBlockSync` wrapper baseline ending in `currentPassiveMatch(`; AST parity plus stale, missing, duplicate, and non-literal negatives prevent wrapper drift from reaching another signed replay.

## Recommended execution flow

```text
BarcelonaActivity.onResume
        |
        v
ModBootstrap.onResume(activity, UserSession)
        |
        v
AutoBlockSync.onResume(activity, UserSession)
        |
        +-- no live session / not foreground / already running --> return
        |
        +-- background HTTPS refresh of the signed v3 index
        |       size, schema, Ed25519 signature, freshness and rollback checks
        |
        +-- account/session still matches?
        |
        +-- indexed visible-match selection + local completion/review state
        |
        +-- for the one selected current target:
               skip self, invalid, duplicate and locally complete targets
               recheck the current visible indexed membership
               run the callback-free cache-first exact-ID native blocked-state preflight
               if already blocked, finish without consuming delay or attempt capacity
               recheck membership, then wait out the configured passive delay
               persist passive-running state, then reserve the attempt
               invoke the native single-block helper, which rechecks ID and block state
               persist completion only from the success callback
               stop on challenge, auth failure, or rate limit
```

That flow is the automatic and hintless path, and there is no switch that turns it off.
A current post or reply row already holds its displayed author model, so the inline design carries that instance into stable code only as an opaque `Object` bound to the immutable media ID and numeric target.
The same SHA-bound row adapter extracts the displayed username only as a trimmed, `@`-prefixed, 80-character-bounded local label.
The scheduler durably enqueues the manual item, marks it running, and reserves the attempt before consuming a bounded viewer/target/session-scoped hint.
Only exact-SHA Smali may cast the model; it re-reads the private model ID and requires equality with the requested target before mutation.
Null, expired, scope-mismatched, restored, and automatic work uses the ordinary host cache first, then the reviewed session cache get-or-create-by-ID seam, and every returned placeholder passes the same ID guard.

The bridge has no profile-fetch callback and emits no lookup failure.
The passive preflight returns only mutation-ready `null`, the internal `already_blocked_success` sentinel, or one reviewed fixed failure stage; it has no callback path and cannot submit a native request.
Cache and model construction and the private blocked-state predicate remain exact-version, human-reviewed seams that are runtime-unproven.
Both the preflight and the normal bridge fail closed on their reviewed session/model, cache/factory/placeholder, model-ID, and predicate stages, and only the normal bridge can reach mutation.
Those results are unrelated to Clone Blocker mirror routing.

Stable `BlockDiagnostic` converts only reviewed fixed stage tokens into identifier-free codes and bounded history, status, and log text.
It never accepts target or viewer IDs, usernames, URLs, payloads, host objects, server responses, or exception text, and unknown tokens are not echoed.
Every terminal inline branch before durable enqueue records one diagnostic before invoking its UI failure callback; after enqueue, only the scheduler records the failure.
An automatic attempt-reservation failure also records history, one viewer-scoped alert, status, and bounded log output before returning without a native request.

The `onResume()` hook does only cheap gating and enqueue work; it never performs network or JSON processing on the main thread.
The helper catches all of its own failures so a mod feature cannot crash Threads.

The applied hook is one static call inserted after the super call:

```smali
invoke-super {p0}, Lcom/instagram/base/activity/IgFragmentActivity;->onResume()V

invoke-static {p0, v6}, Lthreadsmod/bootstrap/ModBootstrap;->onResume(Landroid/app/Activity;Ljava/lang/Object;)V
```

It reuses `p0` and the register that already holds the live session, so the hook does not require increasing `.locals`.
It targets a single stable entry point on purpose: every feature registers inside `ModBootstrap` in deterministic patchlet order instead of adding another direct hook to the obfuscated Threads activity.
`ModBootstrap.onResume` hands the session to `AutoBlockSync.onResume`, arms the foreground report owner, and runs update arbitration; the matching `onPause` hook unwinds all three.

Mod code goes into primary `smali/` and keeps its dependency surface narrow.
The pipeline caps rebuilt primary-DEX method references at 65,535 and fails the build above that, so the budget is measured rather than assumed.
Do not assume a new `classes13.dex` would cooperate with Meta's custom and longtail class loading without a cold-start test, and no such test has been run on a device.

## Server contract

The block list is a signed, content-addressed chunked index at version 3.
The retired whole-file `blocklist.json` model is gone, and the release gate forbids its URLs from appearing in the endpoint class.

Reads use a fixed three-mirror HTTPS allowlist compiled into the APK, in this declared order:

1. `https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/blocklist/v3/`
2. `https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/blocklist/v3/`
3. `https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/blocklist/v3/`

The signed root is `<base>manifest.json`.
Objects are `<base>objects/<64 lowercase hex><suffix>`, where the suffix is `.json` for a group table or `.ndjson.gz` for a row chunk.
Object names are checked against that closed grammar before they may touch a URL, and each object's SHA-256 is proven equal to its signed name before its bytes are parsed.

The root is a signed envelope rather than a bare document. Field names, types, and the `v` and `hash` constants are contractual; the numbers below are illustrative.

```json
{
  "alg": "ed25519",
  "sig": "<unpadded base64url Ed25519 signature over the exact payload bytes>",
  "payload": {
    "v": 3,
    "updatedAt": "2026-09-06T12:00:00Z",
    "hash": "sha256-hi32",
    "maxChunkRows": 8192,
    "maxChunkBytes": 262144,
    "platforms": {
      "threads": {
        "k": 12,
        "g": 6,
        "total": 100000,
        "groups": ["<64 lowercase hex>", "..."]
      }
    }
  }
}
```

Required client rules:

- Require HTTPS and an exact host, path, and full-URL match on the compiled allowlist. Refuse redirects, ports, user info, query strings, and fragments, and never accept a server-supplied URL or fallback origin.
- Verify `alg` is `ed25519` and the signature over the exact raw `payload` bytes with the 32-byte public key embedded in the APK. Do not embed a reusable shared secret.
- Read every payload field type-strictly, because a lenient JSON accessor coerces silently. `v` must be the integer `3`, `hash` must be `sha256-hi32`, and `platforms.threads` must carry integer `k`, `g`, and `total` plus a `groups` array of exactly `1 << g` lowercase hex digests.
- Reject an `updatedAt` that does not parse, is more than 24 hours in the future, is older than 30 days, or is older than the retained generation.
- Cap everything before parsing: 4 MiB response, 512 KiB signed root, 64 KiB group table, 256 KiB gzip chunk, 4 MiB inflated chunk, 8,192 rows per chunk, 2,000,000 index rows, 16 bucket bits, 8 group bits.
- Consult every mirror on each refresh and verify each independently. The candidate with the strictly newest signed `updatedAt` wins, and an equal timestamp keeps the earlier mirror, so a stale but reachable mirror cannot hide a newer generation behind a first-success return or a conditional 304.
- Send `If-None-Match` only to the exact mirror that produced the retained generation, and only while that generation is still usable. Retain only an unexpired last-known-good generation.
- Refuse to fetch while a process-wide `CookieHandler` is installed. Never send Threads cookies, bearer tokens, session objects, device identifiers, viewer IDs, or account credentials to the list mirrors.
- Accept only decimal IDs and deduplicate them before any Threads request.
- Compare each target with the viewer's own account ID and refuse to block self.
- Stage and install rows into the SQLite store at schema v3 through the reviewed v2 to v3 migration; an unreviewed schema upgrade fails closed.

Prefer internal numeric Threads/Instagram user IDs.
Public Threads API IDs must not be assumed equal to private mobile IDs without live verification.
Usernames are useful as human-readable metadata, but a username-only list adds an extra private lookup and rename ambiguity.

The list is **block-only**.
Removing an ID from the server does not unblock the account, and no client path attempts it.
If unblocking is ever added, it needs a separate explicit action schema, separate user consent, and a visible preview.

## Local state and concurrency

Local state is an app-private preferences file plus the SQLite index, keyed by the active account ID.
Preferences hold sync metadata — last fetch time, refresh deadline, ETag and its exact URL, retry deadlines, the passive delay pair, and the last non-sensitive status string — plus the viewer-scoped durable work state: the manual queue, attempt reservations, the completion and completion-review sets, passive-running state, and the bounded audit history and alerts.

Safety invariants:

1. Only one sync may run per process.
2. Capture the initiating account ID and re-check it before every block.
3. Execute block requests sequentially, one target per run.
4. Treat "already blocked" as idempotent success. Passive work classifies it with the exact-ID callback-free native preflight before any delay reservation or running-state persistence; the ordinary bridge still rechecks before any mutation.
5. Persist success only from the existing block callback.
6. On 401/403, a login challenge, `feedback_required`, or 429, stop the run; never try to bypass the control.
7. Retry ordinary transient failures on a bounded fixed ladder rather than an open-ended loop. The list refresh ladder is 15, 30, 60, 120, then 300 seconds, at most five steps per foreground session, after which the ordinary 10-minute cadence resumes; a failed block attempt uses a fixed two-minute backoff.
8. Apply blocks only while the app is in the foreground. A background worker may refresh and cache the index, but it must not invent a global session.
9. If native success is confirmed but the ordinary local completion save fails, first latch the viewer and target in process memory, then attempt the strict viewer-scoped `completion_review_threads_<viewerId>` set. Skip that target during selection and again immediately before dispatch, and create no backoff, automatic queue, or automatic retry.
10. Treat a corrupt, oversized, or full 200-target completion-review set as a durable automatic-work pause. A preference exception or a commit failure retains a process-local pause. `CB-LOC-301` may disclose only the fixed `review-saved` or `review-local-failclosed` state, never an identifier.
11. Only an explicit manual **Retry** or **Retry all** may atomically transition selected retryable queue items and remove their matching quarantine, after which the corresponding process-local latch may be cleared.
12. Check the boolean acceptance result of every scheduler-critical `Handler.post` and `postDelayed`. A refusal must release passive ownership or leave durable work paused with bounded local status; optional toast delivery is the sole best-effort exception.
13. Treat an elapsed or rejected watchdog after bridge dispatch as uncertain mutation state. Install a target review quarantine before releasing ownership, create no automatic backoff or retry, and mark inline work abandoned until an explicit atomic retry removes its matching quarantine.

Account mutations use only the concrete `UserSession` passed in from the foreground activity.
That avoids a multi-account race, and it is why no mutation runs from a background worker.
Do not obtain an arbitrary global session from a background worker: the app's own session registry warns that doing so is unsafe with multiple logged-in accounts (415-era evidence, `decompiled/jadx-1.5.6/sources/p000X/C64992ar.java:28`).

Release provenance for the semantics above, including which replay published which artifact, lives in [CHANGELOG.md](CHANGELOG.md).
Every release to date records `runtimeValidation: not-run`: device startup, live UI, account behaviour, mirror and report delivery, backend acceptance, update installation, and real Block behaviour are all untested on hardware.

## User controls

Passive blocking is always on.
There is no opt-in switch and no in-app way to disable it, so the Settings screen discloses the behaviour instead of gating it: "Always on. Refreshes the signed index every 10 minutes in the foreground, then blocks only listed profiles whose post or reply action row becomes visible."
Uninstalling the clone stops future blocks but does not undo any block already applied.

The controls that do exist are:

- **Sync now** plus a live status line and a viewer-scoped activity list.
- Two passive delay fields: minimum 2 to 60 seconds (default 4) and maximum 3 to 60 seconds (default 10), both in whole-second steps, saved as one validated pair or not at all. See [10-REPORTING-AND-LIMITS.md](10-REPORTING-AND-LIMITS.md) for the full limit contract.
- The persisted `Also block this profile` choice on the inline combined modal.
- A bounded local audit history showing each target's label or numeric ID, outcome, source, and time; it never contains cookies or tokens.

Manual inline Block is deliberately unpaced and uncapped: the passive delay pair applies only to automatic work, and there is no per-hour, per-day, per-run, or per-target ceiling on either path.
Nine older limit keys are recognised in storage for deletion only and are not configurable controls.

There is no master off switch and no dry-run preview; earlier drafts of this document proposed both, and neither was built.

## Alternatives

| Route | True profile block? | Assessment |
|---|---:|---|
| In-process smali/helper patch | Yes | Best feature match; carries the private-API, update, signing, terms, and account-risk burden. |
| Plain companion app | No | Cannot access Threads' `UserSession` or its authenticated request stack. |
| Accessibility companion | Partly | Can drive visible UI after explicit user enablement, but is localization-, Compose-, focus-, and release-sensitive; not reliable background automation. |
| Public Threads API reply moderation | No | Supported and much safer; hides matching replies on your own posts only. |

As of 2026-08-30, Meta's complete public [Threads API reference](https://developers.facebook.com/docs/threads/reference) lists publishing, media retrieval, reply management, users, insights, and oEmbed, but no profile block or unblock operation.
[Reply management](https://developers.facebook.com/docs/threads/reference/reply-management) and Meta's official [Hide Replies request](https://www.postman.com/meta/threads/request/34203612-b819fb2c-8315-461f-8f30-365f7a32d1b1) support hiding and unhiding replies to the authenticated user's own Threads.

A supported service could fetch replies, match their usernames against a server list, and call `POST /{reply_thread_id}/manage_reply?hide=true`.
It cannot prevent those accounts from viewing, following, mentioning, or interacting elsewhere.
That gap is the entire reason the in-process route exists.

## Security and policy boundaries

The APK's `fb_network_security_config.xml` pins Meta domains, and a second native/Java verifier is wired into Tigon/MNS.
This feature does not weaken, replace, or globally bypass either layer.
A separate HTTPS host with a separate platform client and normal system trust is sufficient; Android's [Network Security Configuration](https://developer.android.com/privacy-and-security/security-config) documents domain-scoped controls if a manifest change ever becomes necessary.
See the [integrity and delivery audit](04-INTEGRITY-AND-DELIVERY-AUDIT.md) for exact evidence and scope.

Threads' [Terms](https://help.instagram.com/769983657850450) incorporate Instagram's [Terms](https://help.instagram.com/581066165581870).
Current terms restrict reverse engineering, modification, circumvention, and unauthorized automated collection.
Automating a private endpoint therefore carries contractual and account-enforcement risk even when the technical action is only blocking users.
Keep testing personal, limited, non-distributed, and on a disposable account.
Legal review is outside the scope of this technical analysis.
