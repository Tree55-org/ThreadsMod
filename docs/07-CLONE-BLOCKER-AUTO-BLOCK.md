# Clone Blocker indexed passive-blocking Android mod

Clone Blocker is a patched, re-signed copy of Meta's Threads Android app (`com.instagram.barcelona` 444.0.0.45.85, arm64-v8a).
It installs beside the official app as a separate package, `app.tree55.threads`, with the launcher label `Threads 55`.
Inside it runs a port of the Clone Blocker signed-list workflow: the clone refreshes a signed, content-addressed block index while it is in the foreground, then blocks a listed profile when that profile's post or reply action row becomes visible on screen.

Three facts decide whether you should install it at all.

- Passive blocking is armed the moment the APK is installed and opened.
  There is no in-app switch, no first-run opt-in, and no `Disable` control.
  Uninstalling the clone is the only way to stop it.
- A block the clone performs is an ordinary Threads block.
  It is server-side account state: it appears in official Threads, on every device signed into that account, and it survives uninstalling the clone.
  Nothing in this project can undo it.
- No published build has ever been installed or run on a device.
  Every release run records `runtimeValidation: not-run`.
  The evidence behind this artifact is static packaging and proof-gate evidence only.

This document is the operator guide: what the mod does, how to install it, and how to test it without damaging an account you care about.

## Current build

| Property | Value |
|---|---|
| Artifact | `ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-d.apk` |
| Size | 135,150,120 bytes |
| SHA-256 | `e6ec4d70dacfa094659e31e09f2a890c537ba72b574767d62337a6a929c672a4` |
| Published | 2026-09-06 |
| Application ID | `app.tree55.threads` |
| Launcher label | `Threads 55` |
| Version | `444.0.0.45.85-threadsmod.1` (`versionCode 511407878`) |
| Minimum / target SDK | 28 / 36 |
| ABI | `arm64-v8a` only |
| Runtime floor | Android 9 (API 28) or newer |
| APK signer | one v2 signer using the workspace test key; certificate SHA-256 `317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079` |

The release replay writes the artifact into `dist/`, which is not part of this repository.
Nothing here distributes the APK; the table above is what you verify a copy against.

Release history — every superseded artifact, what changed in it, and why it was replaced — lives in [CHANGELOG.md](CHANGELOG.md).
The historical demo and first separate-app-ID builds are described in [05-HISTORICAL-DEMO-BUILDS.md](05-HISTORICAL-DEMO-BUILDS.md).
Do not judge the current release gates by any earlier artifact.

The clone is signed with the workspace test key, not Meta's production key.
Re-signing the APK voids Meta's signature by definition.
Side-by-side installation comes from the separate application ID, not from the new signature; what the new signature does is make Play updates, signature-gated permissions, SSO, and some backend flows liable to refuse the package.

## What the mod does

The eleven-patchlet catalog under [`patchlets/`](../patchlets/README.md) replays the clone deterministically from a hash-locked three-APK split set.
The current series is 005 r1, 010 r5, 020 r24, 030 r7, 040 r2, 050 r17, 060 r14, 070 r10, 080 r3, 085 r2, 090 r62.
The runtime it produces has four user-visible parts.

**Indexed passive blocking.**
With a signed-in Threads `UserSession` in the foreground, the clone refreshes the signed index on a ten-minute cadence after success and a bounded 15/30/60/120/300 s ladder after failure, indexes only verified, self-consistent generations into a local SQLite store, and pauses itself on invalid store state.
It then blocks only a listed profile whose reviewed post or reply action row is currently visible; refresh never enqueues Block work, and nothing enumerates the database to block in bulk.
Coverage is deliberately narrow — posts and replies that render the reviewed action row, including those in profile post lists, and nothing else, not profile headers, search results, or follower and following lists.
See [12-PASSIVE-BLOCKING.md](12-PASSIVE-BLOCKING.md) for the admission and match contract.

**One explicit Block and report control.**
Posts and replies carry a single inline Block control after Share and no separate Report button.
Every tap opens exactly one compact **Block and report** modal; no path bypasses it, and passive work never creates a report.
See [10-REPORTING-AND-LIMITS.md](10-REPORTING-AND-LIMITS.md).

**Private mod screens.**
A left-drawer row labelled **Clone Blocker settings** opens the private mod Settings screen, whose header **Activity** button opens the Activity screen; together they show live fetch and index status, the always-on passive-blocking disclosure, the Reports disclosure, the passive delay controls, and the SOCKS5 proxy page.
See [09-ACTIVITY-SETTINGS-AND-INLINE-BLOCK.md](09-ACTIVITY-SETTINGS-AND-INLINE-BLOCK.md) and [11-SOCKS5-PROXY.md](11-SOCKS5-PROXY.md).

**Signed in-app updates.**
A foreground update check would hand a newer signed APK to the Android package installer for the clone package only; it never touches official Threads and never installs silently.
The updater is inert in production: no signed `threadsmod-update.json` has ever been published for `app.tree55.threads`, so every check finds no metadata and no update can be offered, downloaded, or installed.
See [13-IN-APP-UPDATES.md](13-IN-APP-UPDATES.md).

## Passive blocking is always on

`AutoBlockSync.isEnabled` returns true for any non-null context and reads no stored preference.
`AutoBlockSync.disable(Context)` does not exist.
The Settings screen's **Passive blocking** card is a static description — "Always on. Refreshes the signed index every 10 minutes in the foreground, then blocks only listed profiles whose post or reply action row becomes visible." — with no switch beside it.
The clone opens with no mod dialog at all, so nothing prompts you before passive work becomes eligible to run.

Installing the APK, opening it, and signing in is therefore enough to arm passive Block.
Because passive blocking is not a stored preference, there is no state to reset: force-stopping the clone, clearing its data, or reinstalling it re-arms passive blocking on the next foreground resume with a signed-in session.

Two boundaries survive this.
Passive work still never creates a report — reports come only from a positive tap in the explicit modal.
And passive work still blocks only profiles that are both in the verified signed index and currently rendered in a reviewed action row.

The clone also sends one activation ping per installed build to `https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/installs`.
It carries an install identifier derived from a local random secret with no account input, plus the clone package name, version name and code, mod build, Android SDK level, device manufacturer, model, primary ABI, language tag, time zone, and send time.
It is never linked to a Threads account or to a report, and the relay additionally sees the connection IP address and User-Agent of that request.
The Settings screen's Reports card names every field it carries.

## Signed index, in brief

The build has three fixed mirrors, consulted in this order on every refresh — GitHub raw, jsDelivr, then the AWS relay — with the signed root at `<base>blocklist/v3/manifest.json` and the group tables and chunks it names at `<base>blocklist/v3/objects/<64 lowercase hex>.json` or `.ndjson.gz`, every URL pinned in canonical [CloneBlockerEndpoints.java](../patchlets/assets/autoblock/java/threadsmod/autoblock/CloneBlockerEndpoints.java).
A root is usable only after Ed25519 verification against the public key compiled into the APK, and an object only after the SHA-256 of its received bytes equals the name the signed root gave it, checked before any parse — so an unproven object can never become a block list.
Every refresh consults all three roots and installs only the one with the strictly newest signed `updatedAt`, subject to a 30-day staleness ceiling, a 24-hour future-clock bound, and anti-rollback; any transport, signature, hash, schema, clock, or transaction failure preserves the previous verified generation rather than treating a partial result as authority.
The retired whole-file `blocklist.json` model is gone: no `blocklist.json` URL, `MAX_TARGETS` cap, or flat `ids`/`usernames` array is compiled into this build, the ISP-blocked origin is deliberately absent, and there is no origin fallback.
The feed connection carries no Threads session, cookie, token, viewer ID, or device identifier; that is isolation, not anonymity, because the mirror, CDN, relay, and network still see the source IP and ordinary connection metadata.
The full mirror, verification, object-proof, and SQLite v3 contract — including the reviewed v2-to-v3 migration and the closed per-mirror failure classes shown on the `List fetch:` status line — is owned by [12-PASSIVE-BLOCKING.md](12-PASSIVE-BLOCKING.md).

Two supporting facts matter when you test.
Android 9 support comes from the bundled [`net-i2p-crypto-eddsa` 0.3.1](../patchlets/assets/autoblock/lib/net-i2p-crypto-eddsa-0.3.1.pom) verifier ([JAR](../patchlets/assets/autoblock/lib/net-i2p-crypto-eddsa-0.3.1.jar) SHA-256 `3bc2c8922a52de7ecad21e9a34d2594b473f18598b7a2b8bd7d4b68ed6cc4dbf`, [CC0 1.0](../patchlets/assets/autoblock/lib/net-i2p-crypto-eddsa-0.3.1-LICENSE.txt)) rather than a platform Ed25519 provider, which older Android releases do not ship.
A signed reference root and its objects, captured on 2026-09-06, are checked in at [`patchlets/assets/tests/fixtures/blocklist-v3-2026-09-06/manifest.json`](../patchlets/assets/tests/fixtures/blocklist-v3-2026-09-06/manifest.json) and drive the host [verifier harness](../patchlets/assets/tests/VerifierHarness.java); copy that shape when you build a test index, and treat live mirror observations as time-specific evidence rather than canonical input.

## Block and report, in brief

The explicit path is one control and one modal, showing bounded identity, an immutable post excerpt capped at 280 UTF-16 units, the report reason, a concise disclosure, the persisted **Also block this profile** checkbox, one dynamic positive action, and Cancel.
That action is labeled **Block** when the checkbox is checked and **Report** when it is not; either label queues exactly one report, and only the checked form additionally schedules the same numeric target through the Block scheduler.
The only write route is `https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/v1/reports`, pinned in canonical [ReportEndpoint.java](../patchlets/assets/autoblock/java/threadsmod/reporting/ReportEndpoint.java); the read mirrors are not write fallbacks, and the POST never carries a raw viewer ID, Threads session, cookie, token, or authorization header.
Delivery is foreground-only and single-flight, gives up after 15 attempts into explicit `gave_up` history — meaning delivery could not be confirmed, not that the server refused it — and deleting a pending report cannot cancel an active delivery or recall a copy the server already accepted.
The complete payload, disclosure, outbox, retry, and cancellation contract is owned by [10-REPORTING-AND-LIMITS.md](10-REPORTING-AND-LIMITS.md).

The report relay has nothing to do with the Threads Block mutation, even though one checked tap can start both.
The authenticated Threads block write stays inside Meta's native mobile client stack and is never proxied through the Clone Blocker relay; no request to a feed mirror performs a block.

## How a matched target is blocked

For each selected still-visible match the port runs a callback-free preflight through a reviewed same-APK cache/model seam before the normal authenticated mutation: it resolves the model, re-reads its canonical ID, requires exact equality, and consults the native already-blocked predicate.
A model that already reports blocked finishes without durable running state, attempt reservation, callback, report, or mutation, so a profile you had already blocked triggers no second mutation and consumes no configured delay.
Only a mutation-ready result continues, the complete authority check repeats immediately before durable `passive_running`, attempt reservation, and bridge dispatch, and the bridge repeats model resolution and exact-ID validation once more to close state drift before it calls the authenticated helper.
A mutation counts as complete only after the native success callback; failure, cancellation, an ambiguous terminal callback, or a timeout does not.
[12-PASSIVE-BLOCKING.md](12-PASSIVE-BLOCKING.md) owns the full admission and match flow.

The durable queue and policy live in canonical [AutoBlockSync.java](../patchlets/assets/autoblock/java/threadsmod/autoblock/AutoBlockSync.java), and the private cache, model, ID, and predicate bindings are selected by the exact-SHA [Threads 444 resolution](../patchlets/resolutions/444.0.0.45.85/resolution.json) and reviewed in its [evidence record](../patchlets/resolutions/444.0.0.45.85/EVIDENCE.md).
Those bindings are static proof only; they are not evidence that a real Threads account was ever queried or blocked.

## Local safety limits

The clone exposes exactly two configurable values, both on the Settings screen's **Passive delay** card.

| Configurable control | Range and default |
|---|---|
| Passive minimum delay | 2–60 seconds, whole seconds only, default 4 |
| Passive maximum delay | 3–60 seconds, whole seconds only, default 10 |

`BlockLimits.checked` rejects a value outside its range, a value that is not a whole-second multiple ("must use whole-second steps"), and a minimum above the maximum.
`BlockLimitsStore.save` commits both fields as one snapshot or neither, and restores the previous pair when the commit fails.
The **Use 4–10 seconds** button restores the defaults.
Everything in the next table is fixed in code and cannot be configured.

| Fixed control | Implemented behaviour |
|---|---|
| Passive blocking switch | None. `isEnabled` returns true for any non-null context and reads no preference; `disable(Context)` does not exist |
| Foreground gate | `onPause` clears the foreground flag and revokes pending visible-row authority, so no new target is taken while the clone is backgrounded |
| Manual inline Block | Not paced by the passive delay pair and not capped by any configurable limit |
| Invalid stored delay | Passive attempts are refused while the stored pair is incomplete, mistyped, or out of range; manual inline Block is unaffected |
| Callback watchdog | 45 seconds |
| Failure backoff | The first opaque native failure stops the run and holds that viewer for 2 minutes |
| Duplicate handling | Skip a target already completed for the active Threads account |
| Self protection | Skip a target whose numeric ID equals the active viewer ID |
| Canonical target ID | Reject an ID that is non-decimal, shorter than 4 digits, longer than 24 digits, or begins with `0` |
| Signed-index freshness | Reject a root whose signed `updatedAt` is over 30 days old, older than the indexed generation, or more than 24 hours in the future |
| Cache clock consistency | Reject a stored snapshot whose fetch time is later than the device clock or more than 7 days old |
| In-memory bounds | At most 256 registered visible controls, 256 queued lookups, and 128 pending matches |
| Durable state writes | Stop the run when the attempt-history or completion-set `SharedPreferences.commit()` fails |

Nine older limit keys are retired and are not settings.
`BlockLimitsStore` carries them in a deletion-only `RETIRED_LIMIT_KEYS` array — `limit_manual_min_delay_ms`, `limit_manual_max_delay_ms`, `limit_automatic_min_delay_ms`, `limit_automatic_max_delay_ms`, `limit_automatic_per_hour`, `limit_target_budget`, `limit_total_per_hour`, `limit_total_per_day`, `limit_max_per_run` — and removes each of them on every successful save.
There is no target budget, per-hour cap, per-day cap, or per-run cap in this build, and no manual delay setting.
Treat any document, screenshot, or note that presents those as live controls, or that describes half-second delay steps, as describing a retired build.
[10-REPORTING-AND-LIMITS.md](10-REPORTING-AND-LIMITS.md) is the canonical owner of the limit contract; check it before relying on any limit stated anywhere else.

Read the consequence plainly: apart from the passive delay pair, nothing throttles how many profiles a session can block.
Manual inline Block is unpaced and uncapped.
The real brake on passive work is that a target must be in the verified index *and* visible on screen *and* not already completed, not a numeric budget.

Completion IDs, attempt timestamps, the manual queue, pace, backoff, status, history, and alerts are all stored under keys containing the active Threads viewer ID, so switching accounts does not reuse another account's completion or pacing state.
The signed index itself is shared by the installation, because it contains only public target IDs.

Attempts are durably reserved before the bridge can dispatch: the reservation appends to the viewer's attempt trail and, for passive work only, commits the next pace deadline in the same write.
That reservation is conservatively never rolled back even if a later authority check prevents dispatch or the mutation fails, because a reserved or submitted request is as rate-sensitive as a successful one.
Nothing here is a capacity or budget: the attempt trail is appended and trimmed but never read by any limit, and the only thing a reservation spends is the next passive delay.
The passive preflight runs before durable running state and attempt reservation, so a profile you had already blocked by hand spends no delay at all.

If completion cannot be persisted after a native success callback, the runtime installs a process-local viewer/target latch and then a strict viewer-scoped completion-review quarantine, and stops.
A confirmed-success target in that quarantine never enters backoff, an automatic queue, or an automatic retry; only an explicit Retry can change its state.

An in-place upgrade may still show a previous build's `signed_list_block_failed` Activity alert.
The current build cannot emit that code — it is a forbidden DEX string in the release gates.
Use **Activity > Clear notices** to remove the stale local entry after reading it.

## Static release validation

The release gates that produced this artifact are static: signature verification against the pinned signer certificate, 16 KiB page alignment, archive and DEX integrity, byte preservation of every native library and directly comparable asset, the primary-DEX method-reference budget, presence of the reviewed read mirrors and the report and statistics endpoints, absence of the blocked origin and of every forbidden DEX string, and the descriptor-bound signed-DEX flow proofs.
The full gate inventory is in [03-BUILD-SIGN-TEST-PLAN.md](03-BUILD-SIGN-TEST-PLAN.md).

These are packaging and preservation checks.
An isolated no-permission emulator UI probe has launched the exact signed primary DEX classes for a signed-review candidate — different bytes from any published APK — but no arm64 clone has been installed on a phone.
The release pipeline and that probe never made a live mirror GET, a report POST, an activation ping, or a Threads block.
Passing these gates does not establish clone startup, login, Android VPN consent, live SOCKS reachability, backend acceptance, or that a single account was ever blocked.

## Installing or updating the published clone

Use an Android 9-or-newer arm64 test phone.
Official Threads can stay installed, because this APK uses the separate application ID `app.tree55.threads`.
API 28 is the manifest minimum, inherited from Threads itself; the APK bundles its own Ed25519 verifier, so no supported release depends on a platform Ed25519 provider.

Install only the current artifact, `ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-d.apk`, SHA-256 `e6ec4d70dacfa094659e31e09f2a890c537ba72b574767d62337a6a929c672a4`, package `app.tree55.threads`.
Every earlier artifact — the `threads55-mod1-c`, `threads55-mod1-b`, and `threads55-mod1` builds, the `tree55-mod1` build, the `com.threadsmod.barcelona` builds, and every 415 APK — is historical, is listed in [CHANGELOG.md](CHANGELOG.md), and must not be used to judge the current release gates.

Verify the hash before you install it, from the repository root:

```powershell
$Adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
$Apk = (Resolve-Path '.\dist\ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-d.apk').Path
$ExpectedSha256 = 'e6ec4d70dacfa094659e31e09f2a890c537ba72b574767d62337a6a929c672a4'

if ((Get-FileHash -Algorithm SHA256 -LiteralPath $Apk).Hash.ToLowerInvariant() -ne $ExpectedSha256) {
  throw 'APK SHA-256 mismatch'
}

& $Adb devices -l
& $Adb install -r --no-streaming $Apk
& $Adb shell am start -W -n 'app.tree55.threads/com.instagram.barcelona.mainactivity.BarcelonaActivity'
```

If `adb` is already on `PATH`, use `adb install -r --no-streaming $Apk` after the same hash check.

`-r` preserves the clone's local data when updating an earlier clone signed with the same workspace key.
The application ID and `versionCode 511407878` are unchanged across the `-d`, `-c`, `-b`, `threads55-mod1`, and `tree55-mod1` builds, so the current artifact updates any of those in place rather than sitting beside it; an install from `-c` or older migrates its SQLite store from v2 to v3 on first open.
It cannot replace official Threads, and it installs side by side with any `com.threadsmod.barcelona` clone — the in-app updater cannot bridge package names.

If ADB reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE`, an installed `app.tree55.threads` was signed with a different key.
Uninstall that package deliberately, accepting that its local data is lost, or install on a clean device.
Do not use a signature-bypass workaround.

Installing this build is the act that arms passive blocking.
There is no post-install step that leaves it dormant.

## Recommended first test

Do not start with the public production list, and do not start with an account you care about.

1. Use a disposable Threads account, and a disposable device profile if you have one.
   Assume every block this test performs is permanent.
2. Before installing, publish a correctly signed v3 index whose `threads` partition contains exactly one test target that you control and are prepared to block.
   The checked-in 2026-09-06 fixture shows the exact root, group-table, and chunk shape the client accepts.
3. Install or update the clone and sign in.
   Confirm ordinary navigation works before scrolling any feed.
   Passive blocking is already armed at this point, so treat every feed row as live.
4. Open the mod Settings screen from the drawer and read the **Passive blocking** and **Reports** cards, then press `Sync now` once.
   The clone opens with no mod dialog, so this screen is the only place the behaviour is disclosed.
5. Watch the `List fetch:` and `Records:` status lines, and capture logs before retrying anything:

   ```powershell
   adb logcat -s ThreadsModAutoBlock:V AndroidRuntime:E
   ```

6. Confirm the intended target became blocked and that no second target was attempted.
7. Open official Threads with the same account and confirm the block is visible there too.
   This is the step that proves the block is real server-side state and not a local flag.
8. Force-stop and relaunch the clone, then shrink the signed index before widening test scope.
   There is no in-app `Disable`; uninstalling the clone is the only way to stop passive work.

The package separation is local only.
If the clone and official Threads use the same account, a successful block made by the clone appears in official Threads and on every other device signed into that account.
Uninstalling the clone does not undo those blocks.

## Runtime boundaries and risks

The current series has a statically gate-passed installable artifact and nothing more.
`runtimeValidation` is `not-run` for every published build.
All of the following are unverified at runtime:

- full clone cold start on an arm64 phone, with no mod dialog preceding the clone's own UI;
- the v3 refresh itself — root selection across the three mirrors, object download, hash proof, chunk staging, per-bucket replacement, and the v2-to-v3 migration of an upgraded install;
- clone login and session creation;
- Play Integrity, Meta signing checks, and protected backend acceptance;
- live author and media snapshot extraction shared between Block and Report, cache-placeholder creation, exact model-ID validation, and the block callback path on a live account;
- rate-limit, challenge, cancellation, and account-switch behaviour at runtime;
- modal rendering, foreground retry and wake timing, cancellation races, and server acceptance of a report;
- Android VPN consent, live SOCKS reachability, and packet routing;
- whether later Threads delivery modules or server flags reject this re-signed package.

The bridge uses private, obfuscated classes from this exact Threads build.
A Threads update can rename or change any of them, so this patch must not be copied to another APK version without tracing and testing again.
The version-bound mappings stay in the [Threads 444 resolution](../patchlets/resolutions/444.0.0.45.85/resolution.json) and its [evidence record](../patchlets/resolutions/444.0.0.45.85/EVIDENCE.md).

Because the clone has a different application ID and a non-Meta signature, Facebook and Instagram SSO, verified links, Play updates, signature permissions, and some backend flows may fail even when the launcher opens.
A failed login or integrity check is not evidence that the index or the block bridge is correct — it usually means you never reached them.

The unrecoverable risk is not a crash.
It is a correct-looking run against the wrong list or the wrong account: passive blocking needs no confirmation, blocks are real account state, and nothing in this project can retract one.

## Disabling or removing it

Passive blocking cannot be disabled inside the app.
There is no Disable control, no switch, and no first-run notice; the Settings screen's **Passive blocking** card discloses the behaviour instead of gating it.
The only way to stop passive blocking is to uninstall the clone, and uninstalling cannot retract a Threads request that has already been submitted.

To remove only the clone:

```powershell
adb uninstall app.tree55.threads
```

A historical `com.threadsmod.barcelona` clone is a separate side-by-side install that `app.tree55.threads` does not update or remove.
It needs its own command:

```powershell
adb uninstall com.threadsmod.barcelona
```

Uninstalling removes the clone's local index, preferences, completion IDs, attempt history, report install secret, report outbox, and local report history.

It does not remove official Threads.
It does not unblock any account: every block the clone made stays in effect on the Threads account, on every device, indefinitely, and has to be undone one profile at a time in the official app if you want it undone.
It does not cancel an active report delivery or recall a report the relay already accepted, and it does not delete anything from the relay operator's systems.
