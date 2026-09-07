# AI-driven APK patchlets

This document owns the patchlet system as a model.
It covers what the ordered catalog is, where AI sits relative to the write path, what the deterministic pipeline proves, and how a proposed change reaches a published artifact.
Release history — which revision shipped when, with which hashes — belongs to [CHANGELOG.md](CHANGELOG.md) and is not repeated here.

## Outcome

Everything the clone does is represented by the reusable [`patchlets/`](../patchlets/README.md) system: the separate application identity, the optional app-scoped SOCKS5 VPN transport, always-on indexed passive Block, the ten-minute foreground mirror refresh, the single inline Block control and its one **Block and report** modal, the Activity and Settings screens, lifecycle hooks, diagnostics and quarantine, in-app updates, packaging, signing, and the release checks.
No behaviour lives in a hand-edited decompiled tree.
Every build is a replay of the same ordered catalog against a hash-locked source set, and a run that cannot reproduce its own inputs produces no artifact at all.

The current source is the exact `Threads-444.0.0.45.85/` base + arm64-v8a + xhdpi split set, not the historical 415 single APK and not an earlier modified tree.
Patchlet 005 deterministically derives one pristine unsigned standalone APK from that set, after which every ordinary patchlet is replayed against a resolution bound to both the source-set digest and the derived-APK digest.

The Threads 444 resolution is `verified-current` with its signed-Dex review blocker cleared, and six builds have been published from this Threads 444 series.
The current artifact is `ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-d.apk`, 135,150,120 bytes, SHA-256 `e6ec4d70dacfa094659e31e09f2a890c537ba72b574767d62337a6a929c672a4`, published 2026-09-06 into `dist/`, which is not part of this repository.
`runtimeValidation` is `not-run` for all six.
No published APK has ever been installed on a device or exercised against a real account: installation, startup, login, feed scrolling, Block, report delivery, live mirror fetch, VPN routing, and updater behaviour are all unobserved for 444.
Static, archive, and signed-DEX gates are the only evidence that exists, alongside an isolated emulator probe that constructs the two mod screens from a candidate's exact primary DEX.

The catalog has eleven ordered patchlets.
Series order is 005, 010, 020, 030, 040, 050, 070, 060, 080, 085, 090.
It is dependency order, not numeric order: 070 is applied before 060 because 060 declares `070-consented-reporting` in its `dependsOn` set.

| Patchlet | Stable work (reviewable Java and templates) | Version-bound work (resolution only) |
|---|---|---|
| `005-split-source-universalization` r1 | Source-set snapshot and lock, pinned two-pass APKEditor merge, byte-preservation checks, split-metadata removal | Three split roles and member hashes, APK-only set digest, tool contract, deterministic unsigned standalone digest |
| `010-clone-identity` r5 | Clone ID policy and the exact rewrite engine | Classified manifest, resource, and DEX identity occurrences |
| `020-autoblock-runtime` r24 | Always-on passive blocking, ten-minute foreground refresh of the chunked v3 index, SQLite schema v3 with a reviewed v2 migration, one-target ownership, preflight before running state, atomic non-clearing deadline and attempt reservation, the two passive delay fields, unpaced manual routing, scheduler, diagnostics, quarantine | Android SDK and minimum DEX placement facts |
| `030-native-block-bridge` r7 | Reviewed Smali templates, callback-free passive preflight, cache-first session get-or-create-by-ID fallback, exact model-ID guard, narrow private-seam protection with callbacks outside, closed terminal stages | Resolution-selected SHA-bound templates plus the obfuscated session, model, ID, cache-factory, predicate, and mutation descriptors and their proofs |
| `040-main-activity-hooks` r2 | One `ModBootstrap` entry point | Launcher activity, live session register, lifecycle anchors |
| `050-mod-settings-ui` r17 | Activity and Settings with identical live status, bounded checked polling, exactly two passive-delay fields, report review and disclosure, the persistent checkbox, Proxy Settings navigation | Resolution-selected templates, exact private manifest registrations, keyed native drawer-row bindings |
| `070-consented-reporting` r10 | Consumes the immutable row snapshot without private identity re-resolution, exact no-text excerpt, canonical URL, one bounded request, durable foreground reporting | Resolution-selected caption, code, and permalink templates, exact `targetUrl` and sole-evidence equality, no second inline action |
| `060-inline-block-controls` r14 | Shared host rewrite, one memory-only observer, one combined modal, report-always and Block-optional routing, the immutable row request, no composition viewer gate, callback-driven Block UI | Resolution-selected snapshot and action-row templates, the one-control post-Share topology, Compose lifecycle, animation, exact anchors |
| `080-socks5-proxy` r3 | Private Proxy Settings, explicit VPN consent, app-UID routing, bounded numeric bypass, encrypted credentials, pinned arm64 engine, four guard and forwarding topologies, lifecycle-bounded polling | Exact Application hook, components, native hash, truthful status and lifecycle behaviour |
| `085-in-app-update` r2 | Strict Ed25519 metadata parsing, GitHub raw -> jsDelivr -> AWS discovery, monotonic revision and modBuild state, bounded private download, artifact verification, visible Android installer handoff | Exact target clone version and modBuild, signer pin, manifest permission rewrite, FileProvider authority and cache path, signed update policy |
| `090-release-gates` r62 | The signed-DEX bridge, report, passive, updater and UI proofs, the pinned-JADX readable-evidence contract, the isolated Activity matcher, the release-tool argument contract | Exact resolution-owned fixture counts and semantics, bounded DTD-free UI XML, viewport and nonzero-bounds visibility, five nonempty ordered status values, one-positive/nine-negative matcher evidence |

This split is deliberate.
Stable behaviour stays reviewable Java and templates that a human can read once and keep reading; facts that drift with every obfuscation pass live only in an exact-hash resolution that has to be re-proved per Threads version.

Determinism applies to the patched source tree, the exact operation states, and the gate results.
Apktool archive timestamps and signing metadata are not normalized, so two independent successful builds are not required to produce the same final APK SHA-256.

## Deterministic execution

```text
exact base + ABI + density APK set
  -> patchlet 005 snapshot/lock + two identical unsigned merges
  -> exact derived standalone APK
  -> fresh decode + no-change rebuild
  -> schema/proof/count validation
  -> ordered patchlets
  -> zero-write reapply test
  -> build + 16 KiB align + v2 sign
  -> package/DEX/bridge-flow/URL/signer/native-library gates
  -> publish candidate
```

Each arrow is a precondition, not a step that can be retried past.
A failed stage leaves the run directory as readable evidence and produces no installable file.

## The AI trust boundary

AI is outside this write path.
It can rank a finite candidate inventory and cite supplied evidence.
It cannot edit the decoded APK, invent a symbol, loosen a count, change an endpoint, sign, install, or publish.

An AI proposal is never itself a patch and never gains production authority.
`New-AiResolutionTask.ps1` assembles a schema-checked task that records immutable authority flags forbidding production edits and publication, and the AI receives only that task plus a bounded template from [`patchlets/ai/tasks/`](../patchlets/ai/tasks).
The required answer is proposal JSON, nothing else.
`Test-AiResolutionProposal.ps1` validates it and fails closed on invented candidate or evidence IDs, digest mismatch, missing roles, cross-role alternatives, or an unmarked high-risk role.

Only a human converts an accepted proposal into a `review-required` resolution with executable anchors and exact rewrite sets, and only a human promotes that resolution to `verified-current`.
A future Threads version with incomplete evidence stays unresolved rather than silently reusing the current obfuscated names.

## Current 444 split source authority

The exact source authority is:

| Role | Member | Size | SHA-256 |
|---|---|---:|---|
| Base | `Threads-444.0.0.45.85/base.apk` | 60,119,977 bytes | `16c2e2c31f7f4481d3a7c4d3e754ceaaef1b22255dab5b8605ef4b7893401b24` |
| ABI | `Threads-444.0.0.45.85/split_config.arm64_v8a.apk` | 65,743,557 bytes | `b1af0d13bcf22bd729e489399217c7c4c0549bdcb06e21ca5882c5085fb2eedb` |
| Density | `Threads-444.0.0.45.85/split_config.xhdpi.apk` | 4,307,549 bytes | `11ba8380bd6595a8d4161da3ced7bfa31bae67da688e229d7a3ad42f6970b17c` |

The canonical APK-only source-tree digest is `5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`.
The two-pass APKEditor 1.4.9 derivation produces an unsigned standalone APK with SHA-256 `156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`.
That derived file remains source input, never a release result.

The source identity is `com.instagram.barcelona`, versionName `444.0.0.45.85`, versionCode `511407877`, minSdk 28, targetSdk 36, arm64-v8a.
The patchlet target is the separate clone `app.tree55.threads`, launcher label `Threads 55`, versionName `444.0.0.45.85-threadsmod.1`, versionCode `511407878`, mod build 1.
The older `com.threadsmod.barcelona` identity is historical only: Android installs it side by side with the current clone, and the in-app updater cannot bridge between package names.

The resolution at [`patchlets/resolutions/444.0.0.45.85/resolution.json`](../patchlets/resolutions/444.0.0.45.85/resolution.json) is the canonical source for every member, source-set, and deterministic unsigned-input hash, with its derivation and current proof boundary summarized in [EVIDENCE.md](../patchlets/resolutions/444.0.0.45.85/EVIDENCE.md).
Patching and re-signing the APK voids Meta's signature; the clone carries a different signer and Meta will not treat it as its own build.

## What the gates prove, and why they are shaped that way

The gate set is not a general test suite.
Most gates exist because something specific once passed a weaker check, and the shape of each gate is the record of that failure.

**The signed DEX is authoritative; readable decompiler output is secondary evidence with exact counts.**
Pinned JADX 1.5.6 once rendered the compiled `"POST"` literal as `TigonRequest.POST`, and on another run recovered five `AutoBlockSync.recordInlineRenderStage(` expressions where the resolution expected four, because it duplicated one shared block into each caller.
Neither was a runtime change; both were readability artifacts that would have been read as behaviour if readable output were the authority.
`ReportClient.post` is now proved directly in the signed DEX: exactly one HTTPS `setRequestMethod(String)` invocation immediately preceded by `const-string "POST"` into the exact argument register, with no branch, switch, or exception-handler entry into that call, and positive, decoy-GET, different-method, duplicate-call, and branch-merge fixtures all blocking.
Targeted JADX recovery stays alias-free, SHA-pinned, and bound to exact counts and order.

**The isolated Activity probe matches rendered UI, not raw attributes.**
An earlier matcher read raw XML attributes and accepted a build whose live status was in fact a single visible multiline node.
The probe now parses at most 1 MiB of DTD-free UI XML with external entity resolution disabled, requires a nonzero viewport and nonzero viewport-intersecting bounds on every accepted node, matches resolution-declared fixed labels as exact visible node text, and requires `List fetch:`, `Records:`, `New this refresh:`, `Database index:`, and `Inline control:` to appear in that order as one contiguous multiline node with a nonempty value on every line.
Its executable contract is one positive fixture and nine bypass negatives, covering content-description-only, mid-line prefix, wrong prefix order, missing prefix, malformed XML, zero bounds, offscreen bounds, empty status value, and split status nodes.
The probe installs only a no-permission package around the candidate's exact primary DEX and removes it afterwards, so it proves Java and DEX screen construction — not the host app, an account, a mirror, a report, or a block.

**The release tooling checks its own call sites.**
One run completed patching, idempotency, rebuild, alignment, and signing and then stopped before publication because the signed-APK gate passed an undeclared `AndroidSdk` parameter to the bridge fixture harness; another stopped because the outer test expected four reviewed terminal routes while both the canonical fixture evidence and the real signed result contained five.
The release-tool contract now AST-parses caller and callee, requires the exact ordered named-parameter set, rejects positional, duplicate, splatted, missing, or undeclared arguments, and binds every expected count to the evidence producer rather than to a hand-written constant.

**Fixture matrices are resolution-owned and exact.**
The current counts are 328 bridge-flow, 41 report-permalink, 13 proxy-bootstrap, and 96 updater cases, declared in the resolution as `expectedDexBridgeFlowFixtureCount`, `expectedDexReportPermalinkFlowFixtureCount`, `expectedDexProxyBootstrapFlowFixtureCount`, and `expectedDexUpdateFlowFixtureCount`.
A revision that changes behaviour has to move the declared count in the resolution, which is a reviewed change, rather than letting a harness quietly agree with itself.

**Asset preservation is byte equality with one named exception.**
`assets/longtail/classes.dex` is the only asset byte-comparison exclusion, because Apktool `--all-src` deterministically reassembles it instead of copying its ZIP bytes.
The exclusion is an exact file path, not a directory or a glob, the replacement all-DEX header, checksum, and signature gate stays blocking, and every other packaged asset is SHA-256 compared with the pristine APK.

**Endpoints are pinned in the signed DEX.**
Block-list reads are exactly GitHub raw, then jsDelivr, then the AWS relay, in that order, against the signed root `<base>blocklist/v3/manifest.json` with content-addressed objects under `<base>blocklist/v3/objects/`; each object's SHA-256 is proved against its signed name before it is parsed.
Report writes use the single reviewed AWS `/v1/reports` URL with no fallback, and `tree55.com` is forbidden as an in-app origin and must be absent from the DEX.

## What the gates cannot prove

Signed-DEX reachability shows that passive preflight is callback-free and precedes passive running state and delay reservation, that the exact-host identity and media snapshot is consumed without private re-resolution, and that the endpoint order and diagnostic stages are the reviewed ones.
It is not live-account proof.
Cache-placeholder behaviour, the private already-blocked predicate, state changes before dispatch, and actual mutation outcomes remain runtime boundaries.
The exact-SHA session, cache, model, ID, and predicate bindings still require human review for every Threads version, because no gate can tell a correct binding from a merely plausible one.

## Where each contract is documented

This document does not restate per-feature behaviour.

- Passive blocking, admission, and the refresh cycle: [12-PASSIVE-BLOCKING.md](12-PASSIVE-BLOCKING.md).
- Reporting, and the two configurable limits: [10-REPORTING-AND-LIMITS.md](10-REPORTING-AND-LIMITS.md), which is the canonical owner of limits.
- Activity, Settings, and the single inline Block control: [09-ACTIVITY-SETTINGS-AND-INLINE-BLOCK.md](09-ACTIVITY-SETTINGS-AND-INLINE-BLOCK.md).
- The Clone Blocker runtime as a whole: [07-CLONE-BLOCKER-AUTO-BLOCK.md](07-CLONE-BLOCKER-AUTO-BLOCK.md).
- Build, sign, and test procedure: [03-BUILD-SIGN-TEST-PLAN.md](03-BUILD-SIGN-TEST-PLAN.md).
- SOCKS5 transport: [11-SOCKS5-PROXY.md](11-SOCKS5-PROXY.md); in-app updates: [13-IN-APP-UPDATES.md](13-IN-APP-UPDATES.md).

Only two limit fields are user-configurable, both owned by patchlet 020 and both passive-only: `passiveMinDelayMs` (2,000–60,000 ms, default 4,000) and `passiveMaxDelayMs` (3,000–60,000 ms, default 10,000), each in whole-second steps.
Manual inline Block is unpaced and uncapped.
Nine older limit keys survive in the store only as a deletion list and are not settings; [10-REPORTING-AND-LIMITS.md](10-REPORTING-AND-LIMITS.md) is the canonical owner of all of this.

## SignedReview and post-promotion Release workflow

A change that touches runtime behaviour cannot go straight to a release.
It goes through `SignedReview`, a human promotion of the resolution, and then a separate default `Release` run.

`SignedReview` runs only against a resolution whose `status` is `review-required` and whose `release.updateSignedDexReviewRequired` is `true`.
It requires a keystore and a device serial, keeps every candidate below `work`, runs the complete signed-APK raw-DEX gate and the isolated exact-primary-DEX Activity UI probe, and emits `reviewOnly: true` with `releaseEligible: false`.
It refuses `-PublishPath` outright — `SignedReview mode forbids PublishPath and cannot publish an APK` — before the run directory is even created, so a review run has no path by which an artifact can escape.
The run directory must be fresh; the pipeline refuses to reuse one.
Passwords are read without echo and passed only through process environment variables.

```powershell
$env:THREADSMOD_KS_PASS = Read-Host 'Keystore password' -MaskInput
$env:THREADSMOD_KEY_PASS = Read-Host 'Key password' -MaskInput

.\patchlets\tools\Invoke-PatchletPipeline.ps1 `
  -SourceApkSet .\Threads-444.0.0.45.85 `
  -RunRoot .\work\patchlet-signed-review-NEW `
  -ResolutionPath .\patchlets\resolutions\444.0.0.45.85\resolution.json `
  -KeyStore "$env:USERPROFILE\.android\debug.keystore" `
  -KeyAlias androiddebugkey `
  -ValidationMode SignedReview `
  -ReviewDeviceSerial emulator-5554
```

After human review of that exact candidate's evidence, the resolution is separately promoted to `verified-current` with the signed-Dex blocker set false and every changed asset hash rebound.
`resolution.schema.json` couples those two fields, so returning a resolution to `review-required` re-arms the blocker automatically and the next `SignedReview` has to re-prove the updater contracts before promotion can clear it again.
Promotion is a reviewed edit to the resolution, not a pipeline output.

The corresponding default `Release` form drops `-ValidationMode SignedReview`, because `Release` is the default mode, and drops `-ReviewDeviceSerial` — the pipeline throws `ReviewDeviceSerial is valid only in SignedReview mode`.
A publishing run adds `-PublishPath`, which must resolve under `dist/` and must not already exist, because the pipeline throws `Refusing to overwrite published artifact` before its first stage.
A revision that changes the artifact's name therefore publishes a new file beside the old one rather than replacing it.

```powershell
.\patchlets\tools\Invoke-PatchletPipeline.ps1 `
  -SourceApkSet .\Threads-444.0.0.45.85 `
  -RunRoot .\work\patchlet-release-NEW `
  -ResolutionPath .\patchlets\resolutions\444.0.0.45.85\resolution.json `
  -KeyStore "$env:USERPROFILE\.android\debug.keystore" `
  -KeyAlias androiddebugkey `
  -PublishPath .\dist\ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-NEW-mod1.apk
```

`Release` runs only against a `verified-current` resolution with the blocker false, and it is the only mode that may receive `-PublishPath`.

### What a run actually does

Patchlet 005 first validates and snapshots exactly `base.apk`, `split_config.arm64_v8a.apk`, and `split_config.xhdpi.apk`.
It locks that set, runs two independent SHA-pinned APKEditor 1.4.9 semantic merges, and requires byte-identical outputs with exact root-DEX, arm64-library, density-payload, resource-configuration, and split-metadata-removal evidence before any ordinary patch replays.

The orchestrator refuses an existing run directory.
It copies and locks the exact source and the complete resolution directory, freezes the full canonical `patchlets/**` tree plus external tools, retains frozen-tree change events, and uses the snapshotted semantics for every stage.
It validates catalog and schema order, exact APK binding, tools and assets, semantic proofs, no-change rebuild, and complete-decoded-tree reapply idempotency while a zero-exception canonical decoded lock is held through publication.
It then creates a fresh disjoint build-working copy, binds its complete SHA-256 and its file, directory, and entry counts to idempotency, and runs pinned Apktool only there.
Stable work files stay read-locked; monitors permit only the exact `build/**` tree plus the root manifest and `.orig` lifecycle, and fail on unexpected structure, file changes, or overflow.
The candidate is locked immediately after build, the work cache is removed, `.orig` must be absent, and the restored work tree is sealed before the release gates run.

The remaining gates cover DEX-only required and forbidden evidence, the signed-primary-DEX bridge instruction and value-flow contract, duplicate-free preservation inventories, package, endpoints, alignment, signature, native libraries, reviewed `assets/**` preservation, and alias-free SHA-pinned targeted JADX recovery.
The bridge verifier is authoritative for exact entry, dispatcher, and private-seam caller provenance, raw private calls, register and value flow, exception ranges, handlers, callback-interface identity, and mutation identity.
Every report binds the initial source, the exact resolution file, canonical and work-tree proofs, and output hashes, and a failed build retains the canonical lock and freeze plus readable work residue as evidence.

Publication is transactional: it rechecks the freeze, moves a hash-checked temporary, read-locks and re-hashes the actual `dist` file, rechecks again, and commits success inside a rollback transaction.
Ordinary failure reports `artifactProduced: false` only after verified cleanup; an OS-refused cleanup is recorded truthfully as exact residue.

A run authorizes only its own frozen inputs.
Evidence from an earlier revision, a failed review, or a historical 415 build never authorizes current bytes.

Use a dedicated retained release key for any real update channel.
The debug key is only an experimental workspace key, and changing or losing the app signer prevents an in-place update of the clone.

## Update for a future Threads APK

1. Inventory and decode the new APK into a fresh directory. Derive version data from its manifest, not its filename.
2. Look for a reviewed resolution whose `source.sha256` exactly matches the APK. A version-name match is insufficient.
3. If none exists, stop in resolve-only mode. Follow [`UPDATE-FUTURE-APK.md`](../patchlets/ai/UPDATE-FUTURE-APK.md) to extract finite candidates and evidence for identity, the bridge (cache, model ID, closed stages), lifecycle, the native drawer row, the one exact-host immutable author and media snapshot shared by the sole inline control and the report request, the one memory-only post/reply observer, indexed passive admission, database status and counts, the passive-only delay pair, diagnostics and quarantine, caption plus code-first and fallback permalink extraction from the same media, and release drift.
4. Assemble a schema-checked task with `New-AiResolutionTask.ps1`. The task records immutable authority flags that forbid production edits and publication.
5. Give the task plus the matching bounded template under [`patchlets/ai/tasks/`](../patchlets/ai/tasks) to an AI. Require proposal JSON only.
6. Validate the proposal with `Test-AiResolutionProposal.ps1`. Invented candidate or evidence IDs, digest mismatch, missing roles, cross-role alternatives, or an unmarked high-risk role fail closed.
7. Human-review account mutation, callbacks, session/cache/model registers, the exact-host identity and media snapshot, zero stable-code private re-resolution, model-ID equality and cache-placeholder fallback, narrow handlers, diagnostics and quarantine, passive attempt and deadline reservation, database migration and status state, captured caption/code/permalink ordering, path-username binding, the exact no-text fallback, the one-control topology, combined-modal routing, and identity preservation. Convert the accepted proposal into a new `review-required` resolution with executable anchors and exact rewrite sets.
8. With the resolution still `review-required` and its signed-Dex blocker true, run the hash-bound `SignedReview` pipeline. It must create only a work-local signed candidate, run the complete raw signed-DEX bridge, updater, and bootstrap evidence plus the exact-primary-DEX Activity UI probe, reject publication, and report `releaseEligible: false`.
9. Human-review that exact candidate's evidence. Rebind every changed canonical asset and tool hash, promote the resolution to `verified-current`, and clear the blocker only through that reviewed change. Then run a fresh default `Release` pipeline that repeats the signed-DEX and archive gates; only this second mode may receive `-PublishPath`.

## Add another feature

Follow [`ADD-FEATURE.md`](../patchlets/ai/ADD-FEATURE.md).
Put stable logic behind `threadsmod.bootstrap.ModBootstrap`, and avoid adding another direct hook into an obfuscated activity.
A new private Threads call requires a small resolution-rendered adapter, semantic candidate roles, proofs, a bounded AI task, ownership metadata, human review, and blocking release gates.
Stable features that need no private API should remain ordinary Java assets plus deterministic postconditions.

Drift in an existing seam has a dedicated task template: drawer drift uses [`RESOLVE-DRAWER-SETTINGS.md`](../patchlets/ai/tasks/RESOLVE-DRAWER-SETTINGS.md), shared row and Block drift uses [`RESOLVE-INLINE-ACTION-ROW.md`](../patchlets/ai/tasks/RESOLVE-INLINE-ACTION-ROW.md), passive lifecycle and visibility drift uses [`RESOLVE-PASSIVE-BLOCKING.md`](../patchlets/ai/tasks/RESOLVE-PASSIVE-BLOCKING.md), and report-extraction drift uses [`RESOLVE-INLINE-REPORT.md`](../patchlets/ai/tasks/RESOLVE-INLINE-REPORT.md).

## Important limits

- Patchlets reduce repeated engineering; they cannot make a private obfuscated API stable.
- A different input digest always requires a new reviewed resolution, even when old anchors appear to match.
- Passive blocking is always on. There is no in-app switch to turn it off, and the build sends one activation ping per installed build on its first eligible foreground resume regardless. Both are disclosed on the Settings screen, in the Passive blocking card and the Reports card.
- Blocks are real server-side account state. They are performed on the signed-in Threads account, they persist on Meta's servers, and uninstalling the clone does not undo them.
- Modifying and re-signing the APK voids Meta's signature. The clone is a separate unofficial application carrying a different signer, not a Meta build.
- The release pipeline never installs, logs in, or mutates a real account. The separately invoked Activity probe installs only a no-permission package around the candidate's exact primary DEX and removes it afterwards.
- A callback-driven green check proves only that the selected native callback reported success; feed-row removal remains Threads behaviour.
- The sole inline control always opens one **Block and report** modal. Its positive action always durably queues one report; **Also block this profile** only adds a scheduler-backed Block. Dedicated Report, editor, review, consent, and one-click paths must remain absent. Report POST may use only the exact reviewed AWS endpoint with no fallback; mirror GETs remain ordered GitHub raw -> jsDelivr -> AWS, and `tree55.com` remains forbidden.
- The opaque inline model is only a current-row optimization. Null and passive work uses the cache-first same-APK session get-or-create-by-ID path, whose model is still subject to exact ID validation. Cache-placeholder acceptance and every fixed failure stage remain device-runtime boundaries until explicitly tested.
- A confirmed native success whose completion save fails is review work, not a transient mutation failure: the viewer and target are quarantined with no automatic retry, and only an explicit atomic manual retry may remove a matching quarantine.
- No published build has been installed or run on a device. `runtimeValidation` is `not-run` for every published artifact, and no runtime, network, or installer result exists for any published 444 bytes.
- Full arm64 clone and device validation remains a separate explicit step, using a disposable account or profile and one controlled target.
