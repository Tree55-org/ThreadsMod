# Build, signing, and test plan

## Build

Signing passwords come from the environment only, never from a command line, a script, or a file in the tree.
`Invoke-PatchletPipeline.ps1` reads them from the variables named by `-KeyStorePasswordEnvironment` and `-KeyPasswordEnvironment`, which default to `THREADSMOD_KS_PASS` and `THREADSMOD_KEY_PASS`.

```powershell
$env:THREADSMOD_KS_PASS  = Read-Host 'Keystore password' -MaskInput
$env:THREADSMOD_KEY_PASS = Read-Host 'Key password' -MaskInput
```

Releasing is two-phase.
The first phase produces signed evidence that cannot become a release artifact.

```powershell
.\patchlets\tools\Invoke-PatchletPipeline.ps1 `
  -SourceApkSet .\Threads-444.0.0.45.85 `
  -RunRoot .\work\patchlet-signed-review-NEW `
  -ResolutionPath .\patchlets\resolutions\444.0.0.45.85\resolution.json `
  -KeyStore "$env:USERPROFILE\.android\debug.keystore" `
  -KeyAlias androiddebugkey `
  -ValidationMode SignedReview `
  -ReviewDeviceSerial emulator-5554
```

`SignedReview` requires the exact resolution to be `review-required` with `release.updateSignedDexReviewRequired: true`, requires `-ReviewDeviceSerial` for the isolated Activity UI probe, and rejects `-PublishPath` before it creates the run directory.
Its candidate and reports stay under that `work` run and record `reviewOnly: true` and `releaseEligible: false`.

A human must then read that exact signed candidate and its evidence, and separately promote the resolution to `verified-current` with `release.updateSignedDexReviewRequired: false`.
Promotion is a reviewed state transition, not a build result: the pipeline never performs it, and without it no run can publish.

Only after promotion does a second, fresh run publish.

```powershell
.\patchlets\tools\Invoke-PatchletPipeline.ps1 `
  -SourceApkSet .\Threads-444.0.0.45.85 `
  -RunRoot .\work\patchlet-release-NEW `
  -ResolutionPath .\patchlets\resolutions\444.0.0.45.85\resolution.json `
  -KeyStore "$env:USERPROFILE\.android\debug.keystore" `
  -KeyAlias androiddebugkey `
  -PublishPath .\dist\ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-NEW-mod1.apk
```

`-PublishPath` must resolve under `dist/` and must not already exist.
The pipeline refuses to overwrite a published artifact, so each revision publishes a new filename rather than replacing an earlier one.
`-RunRoot` must resolve under `work/` and must not already exist either, so no run can reuse or overwrite another run's evidence.

`-ValidationMode` defaults to `Release`, `-AndroidSdk` to `$env:LOCALAPPDATA\Android\Sdk`, and `-BuildToolsVersion` to `36.0.0`.
`-ResolutionPath` has a default too, but pass it explicitly so the bound version is visible in the command that produced the artifact.
The keystore itself lives outside this repository — the commands above name the default Android debug keystore under `$env:USERPROFILE` — and its passwords never appear in the tree, in a script, or on a command line.

For the per-stage scripts behind the orchestrator, see [patchlets/README.md](../patchlets/README.md).
For the patchlet model itself, see [the patchlet guide](08-AI-DRIVEN-PATCHLETS.md).

## Current state

The current published artifact is `ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-d.apk`, 135,150,120 bytes, SHA-256 `e6ec4d70dacfa094659e31e09f2a890c537ba72b574767d62337a6a929c672a4`, published 2026-09-06 from the eleven-patchlet series 005 r1, 010 r5, 020 r24, 030 r7, 040 r2, 050 r17, 060 r14, 070 r10, 080 r3, 085 r2, 090 r62.
It is package `app.tree55.threads`, launcher label `Threads 55`, version name `444.0.0.45.85-threadsmod.1`, version code `511407878`, minimum and target SDK 28 and 36, arm64-v8a, signed under APK Signature Scheme v2 by exactly one signer whose certificate SHA-256 is `317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
That `Release` run recorded `status: passed`, `releaseEligible: true`, `artifactProduced: true`, and `runtimeValidation: not-run`.
No published build has ever been installed or started on a device: the only device evidence any revision holds is an isolated, no-permission Activity UI probe on an emulator — for the Threads 444 builds against a review candidate whose bytes differ from the published artifact, and for the last Threads 415 build against that build's exact primary DEX repackaged behind a no-permission manifest. No probe ever launched a published APK.
`dist/` is not part of the published repository, so no clone contains the APK; build it or obtain it separately, and verify its SHA-256 before installing.

Every release, review, promotion, and failed run — with its hashes, counts, and dates — is recorded in [the changelog](CHANGELOG.md), which this document does not repeat.

## What the pipeline enforces

Everything below is checked automatically on every run.
A failure at any of them fails closed: the run writes `artifactProduced: false`, leaves the output and published bindings null, and creates no `dist` artifact.
None of it is runtime evidence.
These are static proofs about bytes, and passing all of them says nothing about how the app behaves on a device.

- **Mode and resolution state.** `Release` requires the exact resolution to be `verified-current` with `release.updateSignedDexReviewRequired: false`; `SignedReview` requires `review-required` with that flag `true`. The pair is re-read from disk and re-checked at pre-report, pre-publish, and post-publish, so a resolution edited mid-run stops the run.
- **Fresh directories.** `-RunRoot` must resolve under `work/` and must not exist. `-PublishPath` must resolve under `dist/` and must not exist.
- **Input binding.** The three-APK split source set, the universal source APK derived from it, and the resolution file are hashed and bound into every report, and the derived source hash must equal `source.sha256` in the resolution. An unknown or drifted APK is rejected before any decode.
- **Frozen inputs.** The canonical `patchlets/**` tree, the resolution directory, the decoded tree, the build-working copy, and the signed candidate are hashed, file-locked, and monitored for the life of the run, then re-verified at pre-report, pre-publish, and post-publish. Any retained tree-change event fails the run.
- **Catalog and assets.** The patchlet catalog, the host patchlet assets, and all 46 resolution-pinned assets are hash-checked before patching, several of them as whole-tree digests.
- **Exact-count patching.** Each rewrite declares an exact path, complete before and after anchor text, and an expected count, and the engine is strictly tri-state: pristine at the exact count applies, already-applied at the exact count is a no-op, anything else stops with a drift report.
- **Idempotency.** Replaying the complete series against the already-patched tree must be content-identical across the whole decoded tree, before and after.
- **Signed-DEX flow proofs.** Four fixture matrices run against the signed candidate's primary DEX at the exact counts pinned in the resolution — currently 328 bridge, 41 report-permalink, 13 proxy-bootstrap, and 96 updater cases. Each matrix carries hash-pinned negative fixtures, and a missing, duplicate, nonliteral, or divergent expectation fails before any positive case can pass.
- **Targeted decompilation.** A SHA-pinned, alias-free JADX 1.5.6 gate must recover every resolution-owned class — currently 40 — and the DEX must carry all 54 required class descriptors.
- **Clone identity.** The final manifest must declare application ID `app.tree55.threads`, version code `511407878`, version name `444.0.0.45.85-threadsmod.1`, minSdk 28, targetSdk 36, the resolution's launcher activity, exactly one clone-owned non-exported FileProvider authority that grants URI permissions, and clone-owned custom permissions, task affinities, and authenticator account type.
- **Endpoints.** List reads must use exactly the three signed v3 roots in declared order — GitHub raw, then jsDelivr, then the AWS relay. Report writes must use only the single AWS `/v1/reports` URL with no fallback. Every string in the resolution's forbidden set must be absent from the DEX.
- **Diagnostics bounds.** `BlockDiagnostic` must carry its closed reviewed stage map, the 120 / 240 / 200-character detail, status, and log bounds, `mirror=n/a`, and bridge revision `r6`, so no identifier, URL, payload, host object, or `Throwable` can reach a log line.
- **Archive, alignment, and signature.** The primary DEX must stay under 65,536 method references, `zipalign -c -P 16 4` must pass, 7-Zip must report the archive intact, and `apksigner` must report APK Signature Scheme v2 with exactly one signer whose certificate SHA-256 matches the resolution.
- **Byte preservation.** Every native library and every asset outside the exact reviewed generated-DEX exclusions must be byte-hash identical to the source, and each excluded DEX must pass the replacement-DEX gate.
- **Transactional publication.** Only a hash-checked temporary copy is moved to the `-PublishPath` name. The moved file is read-locked and SHA-256 matched against the gated output before the success report commits, and detected post-move drift rolls back that run's exact target rather than leaving a half-published file.
- **Review cannot publish.** `SignedReview` refuses `-PublishPath`, cannot enter the publication transaction at all, and reports `reviewOnly: true` and `releaseEligible: false`. Its candidate stays under `work/` and never becomes a release artifact.

## Runtime validation still owed

Nothing in this list has been done for any published build.
`runtimeValidation` is `not-run` in every default `Release` report, and the isolated Activity UI probe that `SignedReview` runs is an emulator probe against a review candidate, not an installation of published bytes.

Do not start with a production account.
Use a disposable Threads account and a disposable Android user, profile, or test device.
Record the source APK hash and every generated mod hash in the test log.
A block is real server-side account state, so every item below that reaches a real block changes that test account permanently.

- [ ] Install the exact published bytes on an Android 9-or-newer arm64 device and cold start them.
- [ ] Repeat background and foreground transitions, log in, log out, and switch accounts with no verifier error, multidex or class-loading failure, resource failure, or crash.
- [ ] Refresh the v3 index on a device: the signed root fetched and compared across all three bases, every object's SHA-256 proven against its signed name before parsing, and only changed chunks downloaded.
- [ ] Upgrade in place over an earlier install and confirm the SQLite store migrates v2 to v3 with its generation, both timestamps, and both counts retained.
- [ ] Exercise the failure ladder on a device: after a failed refresh the next attempt comes at 15 s, then 30, 60, 120, and 300 s, at most five per foreground session, before returning to the ordinary 600,000 ms cadence.
- [ ] Confirm a passive block of one listed profile whose post or reply row becomes visible, then verify it in Threads' own blocked-accounts UI and again after a process restart.
- [ ] Confirm the passive delay actually paces work between the configured minimum and maximum, and that manual inline Block is not paced by those values.
- [ ] Exercise the inline **Block and report** modal end to end: the modal always opens, its positive action durably queues one report first, and the checked box additionally schedules the block.
- [ ] Confirm a queued report reaches the AWS `/v1/reports` endpoint, and that cancelling before delivery leaves no server-accepted copy.
- [ ] Observe one activation ping delivered to `/v1/installs`, and confirm at most one per installed build.
- [ ] Exercise the in-app updater against a signed manifest published for `app.tree55.threads`; see [in-app updates](13-IN-APP-UPDATES.md).
- [ ] Exercise Android VPN consent, live SOCKS reachability and authentication, and packet routing for the proxy; see [the SOCKS5 proxy notes](11-SOCKS5-PROXY.md).
- [ ] Observe what Meta's servers do with a re-signed package's Play Integrity verdict, and whether the Play in-app update prompt becomes a dead end; see [the integrity and delivery audit](04-INTEGRITY-AND-DELIVERY-AUDIT.md).
- [ ] Confirm auth failure, challenge, `feedback_required`, and HTTP 429 stop the run without any bypass attempt.
- [ ] Confirm self, duplicate, invalid, and already-blocked IDs cause zero redundant mutations.
- [ ] Confirm actions are sequential, account-scoped, and persisted only after the block succeeds.
- [ ] Confirm account A's list can never be applied through account B's session after a mid-run account switch.
- [ ] Confirm no Threads cookie, token, credential, or session value ever leaves the app for the relay.
- [ ] Confirm process death, activity recreation, backgrounding, logout, repeated payload versions, partial failures, and server removal of a target all behave as documented.
- [ ] Confirm the consequences for the official Threads app, its update path, and test-profile data are understood before installing on any device that matters.

The clone contains no unblock path of any kind, so removing a target from the server list cannot undo a block that already happened.
That is a property of the source rather than a device result, but it is worth confirming on a real account before relying on it.

## Installation reality

The current published clone uses `app.tree55.threads`, while official Threads uses `com.instagram.barcelona`.
Android therefore treats them as separate apps: official Threads can stay installed, and the clone keeps separate local app data.
The historical Threads 415 builds and the first Threads 444 build used `com.threadsmod.barcelona`, which Android also installs side by side; the in-app updater cannot bridge package names, so those older clones are never updated by a current artifact.

Separate packages do not separate accounts.
A block is real server-side Threads account state: it is visible from official Threads and from every other signed-in device, it survives uninstalling the clone, and nothing in this app ever reverses it.

On an Android 9-or-newer arm64 test phone, verify and install the exact published bytes of the current artifact, `ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-d.apk`, SHA-256 `e6ec4d70dacfa094659e31e09f2a890c537ba72b574767d62337a6a929c672a4`, from the repository root.

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

`-r` updates an earlier `app.tree55.threads` install only when its signer matches, and the updated install's SQLite store migrates v2 to v3 on first open.
A `com.threadsmod.barcelona` clone is a separate side-by-side install that this command does not touch.
Neither can ever update or replace official Threads.
If an installed clone has a different signer, stop and decide explicitly whether its separate local data can be removed; do not try to bypass Android signature checks.

After an in-place upgrade, Activity may still show an alert or history entry persisted by an older build, such as the retired `signed_list_block_failed` code.
The current build cannot emit it — the resolution lists that string as forbidden in the DEX — so the entry is stale local data, and **Activity > Clear notices** removes it.

A fresh install already has passive blocking on.
It is always on: there is no first-run dialog, no setting, and no in-app way to turn it off, and the Settings screen's **Passive blocking** and **Reports** cards are where that and the activation ping are disclosed.
**Sync now** only forces an immediate list refresh; it does not enable anything, because nothing needs enabling.

Each post and reply carries one Block control after Share, and every tap opens one compact **Block and report** modal, so there is no one-click bypass.
The modal shows the report reason, an immutable excerpt capped at 280 UTF-16 units, a concise disclosure, and the persisted **Also block this profile** checkbox; its single positive action durably queues one report, and the checked box additionally schedules the block through the shared scheduler.
There is no dedicated Report action, no editor, no consent step, and no second modal.
The control-by-control behaviour is in [Activity, Settings, and inline Block](09-ACTIVITY-SETTINGS-AND-INLINE-BLOCK.md), and the list and block flow is in [Clone Blocker auto-block](07-CLONE-BLOCKER-AUTO-BLOCK.md).

Two pacing limits are configurable, and only two: the passive minimum delay and the passive maximum delay.
Both are in whole seconds — the code rejects any value that is not a multiple of 1000 with `must use whole-second steps` — and they default to 4000 ms and 10000 ms, bounded to 2000-60000 ms and 3000-60000 ms.
They pace passive work only; manual inline Block is neither paced nor capped by them, and it has no per-run, per-hour, or per-day cap at all.
[Reporting and limits](10-REPORTING-AND-LIMITS.md) is the canonical description of both fields and of the nine retired preference keys that the store now only deletes.

This clone uses a reviewed selective identity rewrite rather than a search-and-replace over the package name.
Providers, authorities, permissions, deep links, OAuth and package-certificate binding, cross-app access, and backend checks can all still fail at runtime.
Side-by-side installation is static package separation, not proof that login or protected backend flows work.

Modifying the APK voids Meta's signature.
The result is not a Meta build, must not be redistributed as one, and stays a personal test build.

The APK contains a real, mobile-config-gated periodic Play Integrity worker and calls Meta's `attestation/create_android_playintegrity/` flow.
A re-signed package can be classified as `UNRECOGNIZED_VERSION`, and static analysis cannot determine what Meta's servers do with that result.
Local code logs and retries an attestation failure rather than showing a confirmed unconditional startup kill.
Android's [Play Integrity setup](https://developer.android.com/google/play/integrity/setup) and [remediation guide](https://developer.android.com/google/play/integrity/remediation) describe the platform verdict; [the integrity and delivery audit](04-INTEGRITY-AND-DELIVERY-AUDIT.md) holds the in-APK evidence.

The main activity also invokes Play's in-app update flow.
A re-signed build cannot consume the official Meta update, because signature continuity fails, so an update prompt can become a dead end.
Play-delivered optional modules may also be unavailable to a sideloaded signer.
Treat update UI and optional-module behaviour as explicit runtime tests, not as features that work by default.

Android developer verification affects how sideloaded builds install on some devices and in some regions, and the rules change over time.
Check the current [Android developer verification](https://developer.android.com/developer-verification) guidance and its [FAQ](https://developer.android.com/developer-verification/guides/faq) rather than relying on a date recorded here.

## Staged runtime plan

This is the escalation order for putting a build on a real device.
Each stage assumes the previous one passed on the same signed bytes.

### Stage 0: cold-start proof

- Install and cold start the signed artifact.
- Background and foreground repeatedly, log in and out, and switch accounts.
- Confirm no verifier error, multidex or class-loading failure, resource failure, or crash.
- Confirm the primary DEX method reference count stays under 65,536.

### Stage 1: fetch and dry run

- Refresh the signed v3 index and stop before any mutation.
- Confirm the signed root is verified from every base and that only the strictly newest root installs.
- Confirm every object's SHA-256 is proven against its signed name before it is parsed.
- Test offline mode, DNS and TLS failure, an invalid signature, a stale or rolled-back root, an oversized response, an oversized chunk, and duplicate or invalid rows.
- Confirm the retained-failure status names one closed failure class per mirror and never echoes a message, URL, header, or body.

### Stage 2: one-target manual trigger

- Hard-cap the run to one known disposable target.
- Trigger it from the visible **Sync now** action.
- Resolve the target model, call the single-block helper, and persist only on its success callback.
- Verify the block in Threads' own blocked-accounts UI and again after a process restart.

### Stage 3: bounded automatic foreground sync

- Let the `onResume()` trigger run with the shipped 600,000 ms foreground cadence.
- Keep concurrency at one.
- Stop immediately on auth failure, challenge, `feedback_required`, or HTTP 429.
- Re-check the active account before every request.

### Stage 4: observability under stress

- Exercise the last-sync status, the sync-now action, and the non-sensitive audit history.
- Test process death, activity recreation, an account switch during a run, backgrounding, logout, repeated payload versions, already-blocked targets, partial failures, and server removal of a target.
- Confirm server removal never causes an automatic unblock.
- Confirm a native success followed by a completion-save failure quarantines that viewer and target and schedules no automatic retry.

## Release and update maintenance

This stays a personal test build, never a redistributed Meta APK.
When Threads ships a new upstream version:

1. Verify the new split set's hashes, manifest version, signer, ABI and split membership, and alignment.
2. Create a new resolution directory under `patchlets/resolutions/<version>/` bound to that exact source SHA-256. Never carry an obfuscated symbol forward: classes such as `X/DNo` and `X/Igx`, register numbers, and endpoint literals are version-specific and must be re-derived and re-proved.
3. Start that resolution at `review-required`, run `SignedReview`, and have a human read the signed candidate before promoting it.
4. Promote to `verified-current`, then run `Release` from a fresh `-RunRoot` with a new `-PublishPath`.
5. Repeat the complete staged runtime plan. A passing pipeline on new bytes proves nothing about the device.
6. Keep the same personal signing key so your own updates install over each other, and do not confuse it with Meta's signing identity.

Source and rebuild evidence is not runtime, backend, or account-safety proof.
Do not leave a build blocking unattended on an account you care about until the one-target and multi-account tests pass on the exact signed artifact.

## Historical: manual prototype patch layout

The rest of this document records the earlier manual research prototype.
It is not how a release is made — the canonical lane is the two-phase pipeline at the top of this page — and it is kept only because it explains where the current design came from.
The demo and clone builds that used it are described in [historical demo builds](05-HISTORICAL-DEMO-BUILDS.md).

Create a working copy of the Apktool tree; do not edit the evidence decode in place.

```powershell
$SourceTree = '.\decompiled\apktool-3.0.3'
$ModTree = '.\work\mod-v1'
Copy-Item -LiteralPath $SourceTree -Destination $ModTree -Recurse
```

Expected changes in that copy:

1. Add a small helper package under `smali/threadsmod/autoblock/`.
2. Add one `invoke-static` in `smali/com/instagram/barcelona/mainactivity/BarcelonaActivity.smali`, immediately after the non-null `UserSession` branch in `onResume()`.
3. Keep the main-thread hook non-blocking and exception-contained.
4. Reuse `X/Igx` for ID-to-user resolution and `X/DNo` operation `0` for the actual block rather than duplicating session authentication.
5. Implement the two small callback interfaces those helpers need, and process targets sequentially.
6. Add user-facing settings and resources only after the headless dry run and the one-target test pass.

Obfuscated names are version-specific.
Gate the patch on all three values:

- Input SHA-256 `0f6b4515902f78ea194b1bc0563bfcab07f2559d8e80cf6f329d3d1ef786487e`
- Manifest version `415.0.0.26.77`
- Presence of the expected endpoint literals and method signatures in `X/DNo.smali`

Abort instead of applying a fuzzy patch to an unknown APK.

## Historical: manual build, align, and sign

```powershell
$Java = (Get-Command java).Source
$Apktool = '.\.tools\apktool\apktool_3.0.3.jar'
$BuildTools = "$env:LOCALAPPDATA\Android\Sdk\build-tools\36.0.0"
$Framework = '.\decompiled\apktool-framework'
$ModTree = '.\work\mod-v1'
$Out = '.\work\build-v1'

New-Item -ItemType Directory -Force -Path $Out | Out-Null

& $Java -jar $Apktool b $ModTree `
  --frame-path $Framework `
  --output "$Out\threadsmod-unsigned.apk"

& "$BuildTools\zipalign.exe" -P 16 -f 4 `
  "$Out\threadsmod-unsigned.apk" `
  "$Out\threadsmod-aligned.apk"

& "$BuildTools\zipalign.exe" -c -P 16 -v 4 `
  "$Out\threadsmod-aligned.apk"
```

Generate and protect a dedicated development key outside the repository and workspace.
Keep its location out of the repository, out of the documentation, and out of command history, and let `keytool` prompt for passwords rather than passing them as flags.
`$KeyStore` below is an operator-supplied path that is deliberately not recorded here.

```powershell
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $KeyStore) | Out-Null

keytool -genkeypair `
  -keystore $KeyStore `
  -storetype PKCS12 `
  -alias threadsmod-dev `
  -keyalg RSA `
  -keysize 4096 `
  -sigalg SHA256withRSA `
  -validity 3650

& "$BuildTools\apksigner.bat" sign `
  --ks $KeyStore `
  --ks-key-alias threadsmod-dev `
  --out "$Out\threadsmod-signed.apk" `
  "$Out\threadsmod-aligned.apk"

& "$BuildTools\apksigner.bat" verify `
  --verbose `
  --print-certs `
  "$Out\threadsmod-signed.apk"

& "$BuildTools\zipalign.exe" -c -P 16 -v 4 `
  "$Out\threadsmod-signed.apk"

Get-FileHash -Algorithm SHA256 -LiteralPath "$Out\threadsmod-signed.apk"
```

`apksigner` must run after `zipalign`; any byte change after signing invalidates the signature.
See Android's [app signing guide](https://developer.android.com/studio/publish/app-signing), the [apksigner reference](https://developer.android.com/tools/apksigner), and AOSP's [APK signing documentation](https://source.android.com/docs/security/features/apksigning).

## Historical: same-package prototype consideration

The official APK is signed by Meta, and a development key cannot update its package.
An old same-package prototype test therefore required removing official Threads from a test profile first.

1. Use a disposable Android user or profile.
2. Record or export anything needed from the official app first.
3. Remove the official Threads package from that test profile.
4. Install the signed mod with ADB.

```powershell
$Adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $Adb devices -l
& $Adb install '.\work\build-v1\threadsmod-signed.apk'
```

Do not automate that uninstall in a build script.
It destroys app-local data and belongs in an explicit operator step.
The current clone needs none of this, because it installs under its own application ID beside official Threads.

## Historical: Threads 415 published test release

| Property | Value |
|---|---|
| APK | `ThreadsMod-CloneBlocker-415.0.0.26.77-arm64-v8a-socks5-proxy.apk` |
| Size | 81,481,510 bytes |
| SHA-256 | `53f65dc1454f873b2da11548c3550b4bed09aae689abb191c3e5f4b9a8ab82e8` |
| Application ID | `com.threadsmod.barcelona` |
| Version | `415.0.0.26.77` (`versionCode 508504469`) |
| Minimum / target SDK | 28 / 36 |
| Signer | one v2 Android Debug signer; certificate SHA-256 `317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079` |

The authoritative run for those bytes was `work/patchlet-socks5-proxy-20260902-d`.
Its build, release, and idempotency reports passed and bound source SHA-256 `0f6b4515902f78ea194b1bc0563bfcab07f2559d8e80cf6f329d3d1ef786487e`, promoted resolution SHA-256 `6c12261780fd2902dac40f9a465ffa27a116869b0aa880f9a676944070d0e702`, and output SHA-256 `53f65dc1454f873b2da11548c3550b4bed09aae689abb191c3e5f4b9a8ab82e8`.
Complete-tree reapplication covered 115,715 files, 7,824 directories, and 123,539 entries and was content-identical before and after.

Those gates prove the then-reviewed path for those frozen Threads 415 inputs only.
They prove nothing about the current Threads 444 resolution, and `runtimeValidation` for that release was `not-run` as well: it establishes no installation, cold start, VPN consent, SOCKS reachability, packet routing, login, backend acceptance, report delivery, or real block.
