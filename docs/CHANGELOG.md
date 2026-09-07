# Release history

This file owns the release history for the whole repository.

`dist/` and `work/` are local-only and are not published here, so every artifact below is identified by filename, byte size and SHA-256 rather than by a link.
None of these files can be downloaded from this repository.
`dist/SHA256SUMS.txt` is the local ledger of published bytes; it lists sixteen artifacts, and only the three most recent Threads 444 builds are still present on disk.
Every entry records whether its file is still retained locally.

No published build has ever been installed or run on a device.
Every `Release` report in this history records `runtimeValidation: not-run`.
Nearly all device evidence below is an isolated, no-permission Activity UI probe on an emulator: for the Threads 444 builds it ran against a review candidate whose bytes differ from the published artifact, and for the last Threads 415 build against that build's exact primary DEX repackaged behind a no-permission manifest.
No probe ever launched a published APK, and each proves screen construction only.
The one other piece of device evidence is recorded under `tree55-mod1` below: a review candidate that is not the published artifact reached the Threads login screen on an arm64-capable emulator without crashing, which proves startup and nothing past it.
No installation, login, feed scrolling, list refresh, chunk download, database migration, Block, report, activation-ping delivery, in-app update, proxy or VPN behaviour has been exercised on a device for any published build.

Entries are newest first, one per published artifact.
Failed runs, review-only `SignedReview` candidates, and per-run report inventories are evidence under `work/` and are deliberately not entries here; a candidate is named below only where it is the sole device evidence for a build.
Where a failed run is the reason a release gate exists, that reasoning belongs to the patchlet document that owns the gate.
A series line lists the patchlet revisions that the release records name for that build; patchlets the records leave unnamed did not move.

## Identity carried by every Threads 444 build

| Property | Value |
|---|---|
| Application ID | `app.tree55.threads`, except the 2026-09-04 build, which is `com.threadsmod.barcelona` |
| Launcher label | `Threads 55` from 2026-09-05 17:44 onward; `Threads Mod Demo` before that |
| Version name | `444.0.0.45.85-threadsmod.1` |
| Version code | `511407878` |
| Minimum / target SDK | 28 / 36 |
| ABI | arm64-v8a |
| Signing | one APK Signature Scheme v2 signer, certificate SHA-256 `317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079` |
| Alignment | 16 KiB |

The application ID and version code do not change across the `app.tree55.threads` builds, so each one updates the previous install in place rather than sitting beside it.
`com.threadsmod.barcelona` is a different package: Android installs it side by side, and the in-app updater cannot bridge package names.

Patching and re-signing the APK voids Meta's signature.
Blocks these builds perform are real server-side account state on the signed-in Threads account and survive uninstalling the clone.
In every build from `threads55-mod1` (2026-09-05 17:44) onward, the current `-d` build included, passive blocking is always on, with no opt-in and no in-app way to switch it off, and the activation-statistics ping is therefore unconditional.
Only the two builds published before that, `tree55-mod1` and `update-mod1`, gated passive blocking behind an opt-in, and both are historical.

Configurable limits are two fields and only two: passive minimum delay, 2,000-60,000 ms, default 4,000, and passive maximum delay, 3,000-60,000 ms, default 10,000.
Both accept whole-second steps only, and the maximum may not fall below the minimum.
Manual inline Block is unpaced and uncapped.
[`10-REPORTING-AND-LIMITS.md`](10-REPORTING-AND-LIMITS.md) owns that contract in full.

## 2026-09-06 19:28 (+07:00) - `threads55-mod1-d`, current

- Artifact: `ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-d.apk`
- Size: 135,150,120 bytes
- SHA-256: `e6ec4d70dacfa094659e31e09f2a890c537ba72b574767d62337a6a929c672a4`
- Series: 005 r1, 010 r5, 020 r24, 030 r7, 040 r2, 050 r17, 060 r14, 070 r10, 080 r3, 085 r2, 090 r62
- Retained in `dist/`: yes

Patchlets 020 r24 and 090 r62 move list refresh off the whole-file legacy `blocklist.json` and onto the backend's chunked v3 index.
The compiled read allowlist is three fixed bases, GitHub raw, jsDelivr and the AWS relay in that order; the signed root is `<base>blocklist/v3/manifest.json`, and objects are `<base>blocklist/v3/objects/<64 lowercase hex>.json` or `.ndjson.gz`, the name validated before any URL text is formed.
Every refresh verifies the root from every mirror and installs only the strictly newest one; every object's SHA-256 is proven against its signed name before the object is parsed; only chunks whose signed name changed are downloaded; rows are stream-parsed with a strict `JsonReader` into a staging table, and one transaction replaces the affected hash buckets with the exact per-bucket new-id set difference.
The SQLite store is schema v3, and an older install's store migrates on first open through the reviewed chained v1-to-v2-to-v3 path.
Two new classes, `threadsmod.autoblock.ObjectFetcher` and `threadsmod.autoblock.ChunkInstaller`, take the primary DEX to 61,821 method references.

This build supersedes `threads55-mod1-c` and every earlier `app.tree55.threads` build, updating any of them in place.
The `-c` build is superseded because it reads the whole-file legacy list, which the backend keeps trimmed to fit under 512 KiB until every old install is replaced, so it syncs only the trimmed ranked slice.
The chunked v3 read path is described in [`07-CLONE-BLOCKER-AUTO-BLOCK.md`](07-CLONE-BLOCKER-AUTO-BLOCK.md) and [`12-PASSIVE-BLOCKING.md`](12-PASSIVE-BLOCKING.md).

## 2026-09-06 16:02 (+07:00) - `threads55-mod1-c`, superseded

- Artifact: `ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-c.apk`
- Size: 135,133,736 bytes
- SHA-256: `da17a14814b73ca4e94c02fe9f8e7382a0747a07682a84002b6aa086e90ad4fb`
- Series: 010 r5, 020 r23, 050 r17, 060 r14, 070 r10, 085 r2, 090 r61
- Retained in `dist/`: yes

One revision folding three changes, with the primary DEX at 61,746 method references.
The first-run `Threads Mod Auto Block` dialog is removed: `com.threadsmod.DemoDialog` is deleted, the clone opens with no mod dialog, and disclosure of always-on passive blocking and of the activation ping moves to the Settings screen's Passive blocking card and Reports card.
`MAX_RESPONSE_BYTES` rises from 512 KiB to 4 MiB, because the signed list had grown to 545,168-548,306 bytes on all three mirrors and every earlier build failed `too_large` on every mirror, showing `List fetch: Failed - no valid index` and `Records: Unavailable`.
A failed refresh now retries after 15 s, 30 s, 60 s, 120 s and 300 s, at most five attempts per foreground session, before returning to the ordinary 600,000 ms cadence, and the retained-failure status names one closed failure class per mirror.

Superseded by `threads55-mod1-d`, because this build still reads the whole-file legacy `blocklist.json`.
It supersedes `threads55-mod1-b`, which cannot refresh from a signed list larger than 512 KiB and still shows the first-run dialog.

## 2026-09-06 11:56 (+07:00) - `threads55-mod1-b`, superseded

- Artifact: `ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-b.apk`
- Size: 135,133,736 bytes
- SHA-256: `abcfb52fc23b1d819488789566c62189b5297183bf5e39652f17f132272d3bf8`
- Series: 010 r5, 020 r22, 050 r17, 060 r14, 070 r10, 085 r1, 090 r60
- Retained in `dist/`: yes

A text-only correction of two user-visible sentences and one Javadoc comment, with the primary DEX at 61,739 method references.
`AutoBlockSync.getStatus(Context, String)` no longer reads the stored `enabled` preference; its fallback is the single sentence `Enabled; waiting for a signed-in foreground session.`, and the preference is read for no decision at all.
The Settings reports disclosure becomes `this build sends one activation ping per installed build`, and the `InstallStats` Javadoc no longer claims the ping requires a caller-confirmed opt-in.
No other string, control or behaviour changed, and no gate expectation moved.

Superseded by `threads55-mod1-c`: this build still shows the first-run `Threads Mod Auto Block` dialog and, bound to the 512 KiB response cap, cannot refresh from a signed list larger than that.
It should not be installed.

## 2026-09-05 17:44 (+07:00) - `threads55-mod1`, superseded

- Artifact: `ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1.apk`
- Size: 135,133,736 bytes
- SHA-256: `ca53165cc8f511e17b5967b49aae0c4b0fb0629da7da6dd0c46718250f1b3e73`
- Series: 010 r5, 020 r21, 050 r16, 060 r14, 070 r10, 085 r1, 090 r59
- Retained in `dist/`: no, removed from the directory on 2026-09-06 by something outside the pipeline

The first build under the launcher label `Threads 55`; the application ID `app.tree55.threads` is unchanged from the `tree55` build it replaced.
Passive blocking becomes always on: `AutoBlockSync.isEnabled` returns true for any non-null context and reads no preference, `AutoBlockSync.disable(Context)` is deleted, the Settings switch is replaced by a static `Always on.` description, and every `Enable & sync` button becomes `Sync now`.
Because the activation-statistics ping was gated on that same flag, it becomes unconditional: one ping per installed build, sent on the first eligible foreground resume of every installation.
Every other ping guarantee is unchanged, including the closed 13-key payload, the HMAC install identifier with no account, advertising or hardware input, the at-most-one-ping-per-installed-build rule, and the rule that a ping failure can never affect Block, report, list, proxy or updater work.
The 600,000 ms cadence and the not-before guard are list-refresh guarantees, not ping guarantees; a ping is sent at most once per installed build and never repeats on a cadence.
The primary DEX carries 61,739 method references across 13 root and 14 total DEX files.

Superseded by `threads55-mod1-b` because of misleading status text, and it should not be installed.
Its passive blocking was always on and working, but on a fresh install the status line read `Disabled until you explicitly enable it.` while blocking ran, and its Settings reports disclosure still said `enabling passive blocking sends one activation ping`.
Both sentences shipped in that APK's DEX; the defect was user-visible text rather than behaviour, and a documentation sweep found it after publication.

## 2026-09-05 12:31 (+07:00) - `tree55-mod1`, historical

- Artifact: `ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-tree55-mod1.apk`
- Size: 135,133,736 bytes
- SHA-256: `7a8850ef96fe1f973358b1b07989090e3f94ec9ce0a30addb38e304ea8d3a1e6`
- Series: 010 r4, 020 r20, 050 r15, 060 r14, 070 r10, 085 r1, 090 r58
- Retained in `dist/`: no, removed from the directory on 2026-09-06 by something outside the pipeline

The first build under the application ID `app.tree55.threads`, published with the earlier launcher label `Threads Mod Demo`.
In this series passive blocking was opt-in and the activation-statistics ping was gated on that opt-in; both became unconditional in the next build.
Because it shares the package and version code with everything published after it, any later `app.tree55.threads` build updates this install in place.

Two `adb install` attempts of these published bytes onto a test phone were cancelled by the device's own USB-install confirmation and returned `INSTALL_FAILED_USER_RESTRICTED`, so nothing was installed, started or exercised.
The review candidate for this release, SHA-256 `280fa71d00315dbadcece0de5b3fcf19dffd542ee95a8052f979c2dbe86cf9b8` and not these published bytes, did launch to the Threads login screen on an arm64-capable emulator without a crash; no login, scrolling, list refresh, Block, report, ping delivery, update or VPN behaviour followed it.

## 2026-09-04 - `update-mod1`, historical

- Artifact: `ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`
- Size: 135,133,736 bytes
- SHA-256: `85124df5d5995af7ca3efd80b1a16f14b0e8fd380fc61e1bfe303b4037708ec4`
- Series: 085 r1 and 090 r53; the contemporaneous revisions of the other patchlets are not recorded
- Retained in `dist/`: no, removed from the directory on 2026-09-06 by something outside the pipeline

The first Threads 444 artifact and the first updater-capable build, under the old application ID `com.threadsmod.barcelona`.
Patchlet 085 adds the signed, foreground-initiated in-app update path described in [`13-IN-APP-UPDATES.md`](13-IN-APP-UPDATES.md); patchlet 090 r53 changed release proof only, not APK behaviour.
Because its package differs from `app.tree55.threads`, Android installs this build side by side with every later one, `adb install -r` cannot update across the two, and the in-app updater cannot bridge them.

No `threadsmod-update.json` has ever been published for `app.tree55.threads`, so the in-app updater cannot serve any current build until a signed manifest exists.
Since 2026-09-06 the backend update channel is bound to `app.tree55.threads` with bootstrap version code `511407878`.

## Backend changes outside the APK transaction

The backend is not an APK and has no artifact, so it is not an entry in the sequence above.
It changed twice on 2026-09-06 in ways that decide which of the builds above can still refresh its list, so both changes are recorded here.

The legacy whole-file `blocklist.json` is now kept under 524,288 bytes by trimming only the oldest ranked `targets` entries.
The first fitted publish was 520,358 bytes with 1,654 ranked targets, every one of the 1,784 ids still listed in `ids`, `idTags` and `idNames`; it was deployed at 06:44Z and mirrored at 06:50Z.
That is why every build before `-d` syncs at all: each reads the whole file, and each sees only the trimmed ranked slice.

The chunked v3 index is published beside the legacy file and has been live on the origin, the AWS relay, GitHub raw and jsDelivr since `2026-09-06T07:14:05.577Z`.
Its signed root `/blocklist/v3/manifest.json` uses the same key and envelope as the legacy file and names content-addressed objects under `/blocklist/v3/objects/`.
The first production build carried 1,633 threads rows and 862 facebook rows in 16 chunks each, 35 objects, 427,821 bytes, verified byte for byte from all four sources.
Only the `-d` build reads it; every earlier build, and the Chrome extension, still reads the legacy file, so the legacy file stays published until every old install is replaced.

## Historical Threads 415 builds

These predate the Threads 444 series and the `app.tree55.threads` rename.
All ten are package `com.threadsmod.barcelona`, version `415.0.0.26.77`, version code `508504469`, minimum/target SDK 28/36, arm64-v8a, and carry the one v2 signer used throughout this repository, certificate SHA-256 `317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
None of them is retained in `dist/`; `dist/SHA256SUMS.txt` still lists all ten, and those lines now verify only against run-local copies under `work/`.
None was installed or run on a device.
They are historical evidence only, and none carries the current passive, reporting, limits, proxy or updater contracts.

| Date | Artifact suffix | Size (bytes) | SHA-256 | What it added |
|---|---|---|---|---|
| 2026-09-02 | `socks5-proxy` | 81,481,510 | `53f65dc1454f873b2da11548c3550b4bed09aae689abb191c3e5f4b9a8ab82e8` | Patchlet 080 SOCKS5 proxy and Proxy Settings; the last published 415 build |
| 2026-09-02 | `post-permalink` | 81,305,196 | `47f8f70fdf615463de336ddb34edd34c2f81f4e4014b2fa4f8d85f19b5dc5cd3` | The canonical same-row permalink as both `targetUrl` and sole evidence |
| 2026-09-01 | `block-and-report` | 81,305,196 | `e707821b8d0620cdc1c533aa48d35ef43ff3bb6734bdc4c36593b2e3eba191a4` | One compact combined Block and report modal in place of a separate Report control |
| 2026-09-01 | `cache-id-diagnostics` | 81,309,292 | `042c780ff15f9f2a5a94261eb7a6f0a989d7c3f91f19fa98b71a21c3d7d372fb` | The cache-first direct-ID bridge with per-seam handlers and closed identifier-free diagnostics |
| 2026-08-31 | `resolved-inline` | 81,301,100 | `93c521d4f9b4d709d5582d91e1f4b7f9f567751d458c13ecba0f996a9a370192` | The resolved inline author-model handoff and model-ID mismatch refusal |
| 2026-08-31 | `single-action-compact` | 81,301,100 | `f64aa8478edf8c70b53859482690d81ef2313139f2b216dbccbe0e5f928f2831` | Exactly one inline control and no separate Report render |
| 2026-08-31 | `report-limits-activity-fix` | 81,305,196 | `61b9978e59c56adccc3375ac49e74611a15e42d0ffa472be2765eea0e6bd58f4` | The fix for the Activity crash in the build below |
| 2026-08-31 | `report-limits` | 81,305,196 | `f9a26ea6aefc64443dec8e9f6c1d973194aa44bd58014b213f326db576b3a43c` | Reporting and configurable limits; known broken, see the note below |
| 2026-08-31 | `drawer-rich-inline` | 81,260,140 | `55f7daedc524dbb10a9686d6438da04d25afb266a871a65ad064ace21b471735` | The native drawer Settings row and the rich inline dialog |
| 2026-08-31 | `ui-inline` | 81,251,948 | `5137f0085b1ba3799a583ecccd99e169ef5b3e857ee7338c2fce736b046cd7e4` | The first UI and inline-control series, with the private Activity and Settings screens |

Full filenames follow the pattern `ThreadsMod-CloneBlocker-415.0.0.26.77-arm64-v8a-<suffix>.apk`.

The `report-limits` build is known broken for the Activity page.
Its exact signed primary DEX reproduces a pre-`setContentView` `NullPointerException` from `CloneBlockerActivity.statCard()` passing null layout parameters.
Keep it as historical evidence only; `report-limits-activity-fix` is the corrected build.

The static release evidence for the last 415 build passed 13 proxy-bootstrap, 275 bridge and 20 permalink fixture cases, all 28 targeted-JADX recoveries, and the archive, DEX, native-library, alignment, signature, signer, drift, rollback and publication-order contracts.
An isolated exact-primary-DEX probe on an API 37 x86_64 16 KiB emulator constructed the Activity, Settings and Proxy Settings screens with no account or network action.
That probe proves screen construction only.
It establishes no arm64 clone startup, no Android VPN consent, no live SOCKS5 reachability or authentication, no packet routing or capture, no login, no backend acceptance, no report delivery and no real account block.

## Earlier demonstration builds

Dialog-only demonstration builds precede everything above.
They performed no network and no account actions: they showed a dialog and nothing else.
They also predate the separate application ID, so the earliest of them shared the host package rather than installing beside it.
They are described in [`05-HISTORICAL-DEMO-BUILDS.md`](05-HISTORICAL-DEMO-BUILDS.md), which also covers the move to a separately installable clone.

## Verifying a copy you already hold

Nothing in this repository can hand you an artifact, so the hashes above are the only way to tell one build from another.
The three retained files are in `dist/`, which is local-only; the sizes and hashes recorded above were re-verified against those bytes.

```powershell
Get-FileHash -Algorithm SHA256 .\dist\ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-d.apk
```

An artifact whose SHA-256 is not listed above was not produced by the release pipeline, and nothing in this history vouches for it.
A file that matches a listed hash is still an unvalidated build: the hash proves provenance, not that the build has ever run.

## Where the rest of the record lives

The document index is in the [root README](../README.md).
The build, signing and release-gate pipeline is in [`03-BUILD-SIGN-TEST-PLAN.md`](03-BUILD-SIGN-TEST-PLAN.md), and the patchlet workflow that produces every artifact above is in [`08-AI-DRIVEN-PATCHLETS.md`](08-AI-DRIVEN-PATCHLETS.md).
Canonical, hash-pinned sources are under [`patchlets/`](../patchlets/README.md).
