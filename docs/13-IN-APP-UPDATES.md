# In-app updates

Patchlet `085-in-app-update` adds a foreground-initiated update check and a user-visible Android package-installer handoff for the clone package `app.tree55.threads`.
It does not modify the official Threads installation, install an APK silently, or grant Android's unknown-app-source permission on the user's behalf.

## Current status

The updater is inert in production.
No signed `threadsmod-update.json` has ever been published for `app.tree55.threads`, so every check finds no metadata and no update can be offered, downloaded or installed.

The updater cannot bridge package names.
A `com.threadsmod.barcelona` clone from an older build is a different Android package: Android installs it side by side, and because the updater's application ID is the compiled constant `app.tree55.threads` — `UpdateController.onResume` returns without checking anything when the running package is not that constant, and every downloaded archive must declare that same constant — no `com.threadsmod.barcelona` install can ever be upgraded to `app.tree55.threads`.
`adb install -r` cannot cross that boundary either.

No published build has been installed or started on a device, so no update check, download, verification, installer handoff or rollback attempt has ever run on hardware.
Every `Release` report records `runtimeValidation: not-run`, and the release gate's `update-installer-contract` subresult records `runtimeInstallTested: false`.
Everything below is a property of the signed bytes, proven statically.

Release history for every published artifact is in [`CHANGELOG.md`](CHANGELOG.md).

## What the client requires of a backend

To become live the client needs exactly one thing: an Ed25519-signed update manifest served as `threadsmod-update.json` from at least one of the three mirrors listed below, naming APK objects reachable on two independent provider classes.

The publisher and relay that would serve it are a separate project in the `CloneBlockerBackend` repository.
That repository is not part of this one and is not published here, so its internals, deployment hashes and test counts are deliberately out of scope for this document: they drift independently of these bytes.
Nothing in it can weaken any check on this page: an unsigned, mis-signed, replayed or mis-bound manifest is rejected by the client regardless of which mirror served it.

## Signed discovery

Update discovery uses its own Ed25519-signed metadata envelope.
The verification key is shared with the reviewed Clone Blocker publishing system, but the purpose string `threadsmod-app-update` and schema version `1` keep update authority separate from block-list authority, so a signed block-list document can never be replayed as an update policy.

The envelope is strict JSON with exactly three keys — `payload`, `sig` and `alg` — and any other, missing or duplicated key rejects it.
`alg` must be `ed25519`.
`sig` must be exactly 86 base64url characters that decode to exactly 64 bytes and re-encode to the identical string, and the signature scalar must be below the Ed25519 group order, so a malleable variant of an otherwise valid signature is refused.
The signature is verified over the exact `payload` text as it appears on the wire — the JSON is never re-serialised before verification — against the key pinned both in `UpdateSignature.PRODUCTION_PUBLIC_KEY` and in the exact resolution's `update.metadataPublicKey`, `fYcRAV8CRof15IAinUoDOZuBbqqDtDXDPl3lwSLoMhk`.
Verification failure rejects the whole envelope.
There is no unsigned, degraded or operator-override path.

Metadata is requested from three fixed HTTPS URLs, in this order:

1. `https://raw.githubusercontent.com/nsc55/cloneblocker-mirror/published/threadsmod-update.json`
2. `https://cdn.jsdelivr.net/gh/nsc55/cloneblocker-mirror@published/threadsmod-update.json`
3. `https://h0w1lwun39.execute-api.ap-southeast-1.amazonaws.com/threadsmod-update.json`

Each URL is re-derived from a separately compiled host and path and must match the compiled string exactly, so no host, port, query, fragment or userinfo can be substituted at runtime.
All three mirrors are always attempted, so a stale or blocked mirror cannot hide a newer valid revision.
Every response must be HTTP 200; automatic redirect following is disabled, so a redirected metadata mirror simply fails and the next one is tried.
Among the valid signed envelopes the highest `revision` wins, and if two mirrors present that same revision with different signed payloads they are equivocating and the whole read fails closed.
`tree55.com` is a forbidden string in the updater sources and in the final DEX, so the project's own domain can never become an update path.

The three-mirror read has a 24-second monotonic deadline.
Each attempt is capped at eight seconds inside it, with at most a three-second connect and five-second read wait, and a daemon watchdog disconnects the live HTTPS connection at the attempt deadline so trickled headers or body bytes cannot outlast it.
A metadata body is bounded at 24 KiB.
The client refuses to run at all while a process-wide `CookieHandler` is installed, sends only a fixed `ThreadsMod-Updater/1` User-Agent with `Accept: application/json` and `Accept-Encoding: identity`, disables caches, and never sends a Threads cookie, an `Authorization` header, a referrer or an account identifier.

## The signed payload

The payload carries exactly these fourteen keys and nothing else.

| Field | Accepted value |
|---|---|
| `v` | integer `1` |
| `purpose` | `threadsmod-app-update` |
| `packageName` | the clone application ID, `app.tree55.threads` |
| `revision` | positive integer, at most 2,147,483,647 |
| `publishedAt` | UTC `uuuu-MM-dd'T'HH:mm:ss.SSS'Z'` that round-trips to the identical string, at most 24 hours in the future |
| `modBuild` | positive integer, at most 2,147,483,647 |
| `minimumModBuild` | 0 through `modBuild` |
| `versionCode` | positive integer, at most 2,147,483,647 |
| `versionName` | matches `^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$` |
| `notes` | string, possibly empty, at most 2,000 characters, no control characters, no leading or trailing whitespace |
| `apkSize` | 1 MiB through 200 MiB |
| `apkSha256` | 64 lowercase hex characters |
| `signerSha256` | equal to the resolution-pinned signing certificate SHA-256 |
| `downloadUrls` | two or three distinct HTTPS URLs ending in the same `.apk` filename, spanning both provider classes |

An unknown, duplicate, missing, mistyped, out-of-range or noncanonical field rejects the complete envelope, not just the field.
Age alone never invalidates a payload: a valid old publication timestamp is still valid policy.
The timestamp is parsed to an epoch once and that exact result is reused, so it cannot be re-read differently later.

## Persisted policy and rollback protection

Accepted revision and mod-build state is persisted with raw-type checks and synchronous commits — `.commit()` is required and `.apply()` is forbidden — so a policy is either durably recorded or treated as uncertain.
Revision and mod build never move backwards.
A higher revision may keep the same mod build only when the binary identity it describes (version code, version name, size, artifact hash and signer) is unchanged, and a higher mod build must carry a strictly higher version code.
A stored envelope must bind exactly to the separately typed revision and mod-build floors; when it does not, the state is ambiguous, and only a candidate whose revision is strictly greater than the stronger of the parsed and typed floors may repair it.

Corrupt or uncertain state pauses update authority instead of resetting rollback protection.
Before any policy commit the store records the strongest attempted verified policy as an in-memory floor.
A false or thrown editor outcome keeps that floor, makes ordinary policy loads fail closed, and rejects older candidates until a successful synchronous recommit clears it.
During that uncertainty the process may keep enforcing one previously verified required policy, but only one that came from a successful load or commit.
That retained manifest never leaves `UpdateStore`; only a boolean required-policy fact reaches the controller, which may then show only a noncancelable **Update unavailable** dialog with **Retry**.
Retained state cannot show an Update action, open unknown-sources settings, download, verify or launch an installer, and a failed first commit or a previously optional policy can never manufacture a required lock.

## Eligibility and dialog behaviour

The exact [Threads 444 resolution](../patchlets/resolutions/444.0.0.45.85/resolution.json) owns the running mod build (`update.currentModBuild`, currently 1) and the clone target version code `511407878`, displayed as `444.0.0.45.85-threadsmod.1`.
Its pristine derived source stays at version code `511407877`, version `444.0.0.45.85`; the [resolution evidence](../patchlets/resolutions/444.0.0.45.85/EVIDENCE.md) records the split-source and validation boundary.

A candidate is offered only when both conditions hold: its signed `modBuild` is greater than the running build's, and its signed `versionCode` is greater than the installed clone's.
`minimumModBuild` is a required-update policy threshold only; it is never a substitute for either newer-build check.
A required policy whose artifact is not actually newer produces **Update unavailable**, not an install.

A required eligible update presents one noncancelable dialog with a single **Update** action.
Back and outside taps are refused, and it returns on every foreground resume until a higher signed policy or a successful install changes applicability.
An optional update presents **Update** and **Later**.
**Later** synchronously records only that one verified revision; it cannot dismiss a required update and it cannot hide a later revision.
Cancelling an optional dialog runs the no-update continuation without recording **Later**.
Notes longer than 600 characters are elided in the dialog body.

`UpdateController.onResume` owns first-dialog arbitration on every foreground resume; it is the last call in `ModBootstrap.onResume`, which the signed-DEX proof requires to reach it on every path and never return without it.
When no update prompt applies it runs the continuation that `ModBootstrap` hands it, and that continuation is an empty, non-capturing `Runnable` that shows nothing.
The signed-DEX proof requires that `Runnable` to have a no-argument constructor and a `run()` body of exactly one `return-void`, and requires the `Lcom/threadsmod/DemoDialog;` descriptor to be absent from the primary DEX, so no mod dialog can precede, replace or obscure a required update.

Checks begin from foreground lifecycle entry and are rate-limited to one per ten eligible foreground minutes.
Update UI and installer launch stay bound to the current foreground Activity.
A metadata read already in progress, or a download started by an explicit **Update** tap, may finish and cache after pause, but it cannot show UI or launch the installer until a current foreground resume or tap.
Network failure keeps enforcing an already verified required policy, but it can never create a required gate or lock a first-run app when no verified policy exists.

## Download and installer boundary

An APK transfer begins only after an explicit **Update** tap.
If Android requires per-app unknown-source approval, that tap opens the system install-source settings and waits for the user.
The updater never grants that permission itself and cannot simulate the consent.

Artifact URLs are HTTPS and restricted to two reviewed provider classes: a canonical GitHub release URL under `nsc55/cloneblocker-mirror`, or a public AWS object host — a `*.cloudfront.net` distribution or a regional S3 host.
A regional S3 bucket must be one lowercase DNS label of 3 to 63 characters; a dotted bucket name is refused because it falls outside the reviewed TLS wildcard boundary.
Every manifest must span both provider classes, so a single blocked or compromised provider is never the only source.
An initial artifact URL carries no query, fragment, userinfo or explicit non-443 port, and is capped at 1,024 characters; a redirect `Location` and the resulting full URL are capped at 4,096, and a redirect path and query at 2,048 each.
Only 301, 302, 303, 307 and 308 redirect, at most three hops, and never across provider classes.
Each hop must still end in the same signed `.apk` filename, except a GitHub hop landing on `release-assets.githubusercontent.com` or `objects.githubusercontent.com`, whose opaque object paths are constrained by the host allowlist alone.
Any host outside those two classes is rejected, numeric-IP literals, loopback, `.localhost` and `.local` names included.

Each download attempt has a ten-minute monotonic deadline, and the whole download, cache, hash and rename operation has a twenty-minute deadline.
The transfer is bounded by the signed size, is refused if the declared content length disagrees with it, and fails closed if the completed byte count does not match exactly.
Bytes land only in updater-owned private cache under `cache/shared/updates`, in exactly two fixed filenames, `threadsmod-update.apk` and `threadsmod-update.apk.part`.
A signed URL basename is validated as policy and never becomes a local path.
`DownloadManager` is a forbidden string in the updater, because a download running under a different UID would escape the app-scoped SOCKS5 VPN boundary.

Before Android is asked to install anything, the updater proves all of the following against the completed file:

- exact byte length equal to the signed `apkSize`;
- SHA-256 equal to the signed `apkSha256`;
- archive package name equal to the clone application ID;
- archive version code equal to the signed `versionCode`, and strictly greater than the installed clone's;
- archive version name equal to the signed `versionName`;
- exactly one signer on the installed package, and exactly one on the archive;
- equality among the installed signer, the archive signer, the signed `signerSha256`, and the resolution-pinned certificate SHA-256.

Any failure leaves the bytes in private cache and offers the user another attempt; nothing is handed to Android.
Immediately before the installer callback the latest signed binary is reloaded and revalidated under the same monitor that guards policy installation, so a policy that changed during the download cannot be installed.

Only then does the updater create a content URI through the clone's existing non-exported `FileProvider` and start Android's **visible** package installer with `ACTION_VIEW`, the APK MIME type and a read-only URI grant.
The user sees the system install prompt and confirms it.
The updater never performs a silent, root, shell or unattended install, and there is no code path that could.

## Install permission proof

`android.permission.REQUEST_INSTALL_PACKAGES` is proven only from the final signed manifest.
It must appear exactly once, as a direct `uses-permission` child of `<manifest>`, in both the structural decoded-XML check and the `aapt2 dump xmltree` check.
The resolution's DEX-marker list must contain it zero times, because a manifest permission is not class-string evidence.
Seven decoy negatives are asserted to fail, so a decoy attribute cannot satisfy the gate: the permission missing; a `meta-data` element carrying the permission name, in decoded XML and again in `xmltree`; a duplicate `uses-permission`; an unnamespaced `name` attribute; a nested child element carrying the name; and a `uses-permission` parented under `<application>` instead of `<manifest>`.

## Release evidence

The reviewed primary-DEX control-flow and value-flow inspector is the authoritative updater evidence.
It runs fourteen named checks — `completeUpdaterGraph`, `normalControlFlow`, `exceptionalControlFlow`, `registerValueFlow`, `bootstrapArbitration`, `signatureAndMetadata`, `eligibilityAndPolicy`, `requiredOptionalDialog`, `explicitUpdateTap`, `retainedUnavailableOnly`, `verifiedFileProvenance`, `currentBinarySerialization`, `lifecycleOwnership` and `storeAntiRollback` — over a scope of every `Lthreadsmod/update/` class plus `Lthreadsmod/bootstrap/ModBootstrap;` and its inner classes, and reduces them to one semantic digest that must equal `release.requiredDexUpdateFlow.expectedSemanticSha256` in the exact resolution.
The scoped class count, the expected fixture count and the pinned digest live in the exact resolution's `release` block and are not restated here.

Normalisation is deliberately narrow: equivalent `const-string` and `const-string/jumbo` forms, equivalent `goto` widths, branch, switch, try and catch raw offsets expressed as semantic instruction indices, and only an unreferenced odd-offset alignment NOP immediately before a payload and after an unconditional terminal.
A separate encoding-variant carrier keeps one semantic digest after every `const-string` in it is forced to `const-string/jumbo` and the DEX is reassembled, so representation alone cannot move the digest.
The generated-D8 fixture matrix is one positive case plus one exact bypass mutation per negative case in `patchlets/assets/release-gates/dex-update-flow/negative/fixtures.json`.
Every negative must be rejected by its own reviewed failure code before the digest is compared at all, so a mutation cannot pass by falling through to a hash match.

`Test-PatchedApk.ps1` requires the identical inspector to pass the final signed candidate before a release report can succeed.
Its updater subresults may report `passed` with `authoritative = true` only through raw primary-DEX evidence; a contract negative proves that a remaining targeted-JADX record cannot grant authority once its raw-DEX binding is removed.
Source strings, host fixtures, targeted JADX output and earlier signed candidates are all nonauthoritative for the exact 444 boundary.
The executable host harnesses for the store floor, the update policy and the Ed25519 verifier prove those behaviours at source level only; they are not raw-DEX evidence and do not stand in for it.

Publishing promotes the exact resolution to `verified-current` only after a human reviews a `SignedReview` candidate.
`resolution.schema.json` couples `release.updateSignedDexReviewRequired` to that promotion state, so any revision that returns the resolution to `review-required` re-arms the flag and forces a fresh raw-signed-DEX re-proof before another release can publish.
Per-run reports, candidate hashes and review records are evidence under `work/`, which is not published in this repository.

## Bootstrapping and package identity

Published builds from before the updater existed contain no update code at all, so they cannot discover mod build 1.
Reaching an updater-capable build from one of those is a one-time manual install; built APKs are not committed, so that install has to come from a build you produce and verify yourself.
Only mod build 1 and later can receive in-app update prompts, and none of them can receive one until a manifest is published.

Every `app.tree55.threads` build so far shares one application ID and one version code, so the current artifact updates any earlier `app.tree55.threads` install in place rather than sitting beside it, provided the signer matches.
It installs beside a `com.threadsmod.barcelona` clone rather than upgrading it.
Artifact filenames, sizes and hashes for each published build are in [`CHANGELOG.md`](CHANGELOG.md).

Publishing signed update metadata is a separate, deliberate operator action.
Nothing in this feature authorises it, and no release run has performed it.

The owning patchlet is [`085-in-app-update`](../patchlets/features/085-in-app-update/PATCHLET.md).
