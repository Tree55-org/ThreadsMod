# Clone Blocker for Threads

Clone Blocker patches Meta's Threads app for Android (`com.instagram.barcelona`, version
`444.0.0.45.85`, arm64-v8a) into a re-signed, separately-installable clone: application ID
`app.tree55.threads`, launcher label **Threads 55**.

It installs *beside* official Threads rather than replacing it — its own package, UID, data
directory, provider authorities, permissions and task affinities — and adds community blocking on
top of the stock feed. This is a personal research build. It is not affiliated with, endorsed by, or
connected to Meta, and it is not distributed through any app store.

## What it does

- **Passive blocking.** Syncs a signed community block list every ten minutes while the app is in
  the foreground, and blocks a listed account when that account's own post or reply scrolls into
  view — one target at a time, under a randomised delay.
- **Passive blocking is always on.** There is no opt-in and no in-app way to turn it off.
  Uninstalling the clone is the only way to stop it.
- **Inline Block control.** Every post and reply carries one Block control that opens a single
  *Block and report* modal: the post excerpt, a reason, an optional *Also block this profile*
  checkbox, one dynamic Block/Report action, and Cancel.
- **Reports are never automatic.** Only an explicit tap on the modal's positive action queues one.
- **Settings and Activity screens**, reached from a row at the bottom of the left feed drawer:
  list-fetch status, record counts, the passive-delay controls, the report outbox, and history.
- **Two configurable values only** — passive minimum delay (2–60 s, default 4) and passive maximum
  delay (3–60 s, default 10), in whole-second steps.
- **Optional app-scoped SOCKS5 proxy** over an Android `VpnService`. Off by default, covers only the
  clone, fail-closed.
- **Signed in-app updates.** Ed25519-verified metadata, hash- and signer-checked download, handed to
  Android's *visible* package installer — never a silent, root or shell install.

**Blocks are real account state.** They are performed by Threads' own authenticated block action
using your live signed-in session, so they appear in official Threads, apply on every device using
that account, and are *not* undone by uninstalling the clone.

## Status

The current build is `ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-d.apk`,
135,150,120 bytes, SHA-256 `e6ec4d70dacfa094659e31e09f2a890c537ba72b574767d62337a6a929c672a4`,
published 2026-09-06 from patchlet series 005 r1, 010 r5, 020 r24, 030 r7, 040 r2, 050 r17, 060 r14,
070 r10, 080 r3, 085 r2, 090 r62.

**No published build has ever been installed or started on a device.** Every release records
`runtimeValidation: not-run`. The release gates are *static* — they prove properties of the signed
bytes, not that the app runs. The only device evidence anywhere is an isolated Activity-UI
probe on an emulator, run against a review candidate rather than published bytes. Login, feed
scrolling, list refresh, the SQLite v2→v3 migration, a real block, report delivery, VPN routing and
the updater are all unexercised on hardware. Treat this as unverified software.

The in-app updater is additionally inert in production: no update manifest has been published for
`app.tree55.threads`.

See [docs/CHANGELOG.md](docs/CHANGELOG.md) for release history.

## Requirements

**To run:** Android 9+ (API 28), arm64-v8a.

**To build:** Windows with PowerShell 7, a JDK on `PATH`, Android SDK build-tools 36.0.0, and the
pinned toolchain — Apktool 3.0.3, APKEditor 1.4.9, JADX 1.5.6. The upstream Threads split APKs and
the toolchain jars are local-only and **not** in this repository; their exact SHA-256 hashes are
pinned in `patchlets/resolutions/444.0.0.45.85/resolution.json`.

## Build

Passwords come from the environment only, never from the command line:

```powershell
$env:THREADSMOD_KS_PASS  = Read-Host 'Keystore password' -MaskInput
$env:THREADSMOD_KEY_PASS = Read-Host 'Key password' -MaskInput
```

Releasing is two-phase. First produce non-publishing signed evidence:

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

A human then reviews that exact candidate and promotes the resolution to `verified-current`. Only
after promotion does a fresh run publish:

```powershell
.\patchlets\tools\Invoke-PatchletPipeline.ps1 `
  -SourceApkSet .\Threads-444.0.0.45.85 `
  -RunRoot .\work\patchlet-release-NEW `
  -ResolutionPath .\patchlets\resolutions\444.0.0.45.85\resolution.json `
  -KeyStore "$env:USERPROFILE\.android\debug.keystore" `
  -KeyAlias androiddebugkey `
  -PublishPath .\dist\ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-NEW-mod1.apk
```

`-PublishPath` must not already exist — the pipeline refuses to overwrite a published artifact, so
each revision publishes a new filename. For the per-stage scripts, see
[patchlets/README.md](patchlets/README.md).

## Install

Built APKs are not committed (each is ~135 MB, and they are derived from Meta's signed binaries), so
build one first. Verify its hash, then:

```powershell
adb install -r --no-streaming .\dist\<artifact>.apk
adb shell am start -n app.tree55.threads/com.instagram.barcelona.mainactivity.BarcelonaActivity
```

`-r` updates an earlier `app.tree55.threads` install only when the signer matches, migrating its
store on first open. It can never update or replace official Threads. An older
`com.threadsmod.barcelona` clone is a separate side-by-side install that the updater cannot bridge.

Read [docs/07](docs/07-CLONE-BLOCKER-AUTO-BLOCK.md) and [docs/12](docs/12-PASSIVE-BLOCKING.md)
before installing, and test with a disposable account.

## How it is built

Nothing is hand-edited. The mod is defined as eleven ordered, exact-count **patchlets** replayed
against a hash-locked three-APK split source set. Every obfuscated Threads symbol lives in a
per-version **resolution** bound to an exact source SHA-256, never in stable Java. Each rewrite rule
declares an exact path, complete before/after anchor text and an expected count, and the engine is
strictly tri-state: pristine at the exact count applies, already-applied at the exact count is a
no-op, anything else stops with a drift report.

Reapplying the complete series to an already-patched tree must be a content-identical no-op. Any
count drift, hash drift or gate failure fails closed and produces no installable artifact.
`decompiled/`, `work/`, `dist/` and built APKs are evidence or output — never source.

Details: [docs/08](docs/08-AI-DRIVEN-PATCHLETS.md) and [patchlets/README.md](patchlets/README.md).

## Repository layout

| Path | What it is | In git |
|---|---|:-:|
| `patchlets/` | Canonical source. Every change originates here. | yes |
| `patchlets/features/` | The eleven patchlets, each a `patchlet.json` + `PATCHLET.md`. | yes |
| `patchlets/resolutions/` | Per-APK-version symbol bindings and evidence. | yes |
| `patchlets/tools/` | The PowerShell pipeline and the DEX inspectors. | yes |
| `patchlets/assets/` | Injected Java, Smali templates, release-gate fixtures. | yes |
| `docs/` | Design and operator documentation. | yes |
| `AGENTS.md` | Binding project rules. | yes |
| `Threads-<version>/` | Pristine upstream split set. | no |
| `dist/` | Published APKs. | no |
| `work/` | Per-run build and review evidence. | no |
| `decompiled/` | Analysis trees. | no |
| `.tools/` | Pinned third-party toolchain. | no |

The excluded paths are local-only: they hold Meta's redistributable-restricted binaries, files over
GitHub's size limit, or per-run evidence. Their exact hashes are pinned in the resolution, so a build
is reproducible without them being committed.

## Privacy and network

Blocking uses Threads' own authenticated block action. **No Threads session, cookie, token or
account ID is ever sent to this project's backend.**

List reads come from three fixed mirrors — GitHub raw, jsDelivr, an AWS relay — where every object's
SHA-256 is proven against a signed manifest before it is parsed. There are exactly two write
destinations: a report, sent only on an explicit tap, and one anonymous activation ping per installed
build. Third-party analytics, advertising, attribution and crash SDKs are forbidden and
gate-enforced.

The relay stores the connection IP, User-Agent and derived city/country on a report, with no
automatic expiry. Full disclosure: [docs/10](docs/10-REPORTING-AND-LIMITS.md).

## Boundaries and risk

- Modifying the APK invalidates Meta's signature. A re-signed same-package APK can never update or
  coexist with the official install under the normal Android security model.
- The private endpoints and obfuscated class names are not stable APIs. Every Threads release needs
  a fresh resolution and a full regression run.
- Play Integrity, Facebook/Instagram SSO, App Links, Play in-app updates and Play split delivery are
  expected to fail or degrade under a personal signer.
- Automating private APIs and reverse-engineering may violate Meta's terms and can put the account
  at risk. Use a disposable account and test device.
- Do not redistribute a modified Meta APK without appropriate legal review.

## Documentation

| Document | Contents |
|---|---|
| [CHANGELOG](docs/CHANGELOG.md) | Release history, newest first |
| [01 — APK inventory and decompilation](docs/01-APK-INVENTORY-AND-DECOMPILATION.md) | Source APK identity, hashes, toolchain provenance |
| [02 — Auto-block feasibility and design](docs/02-AUTO-BLOCK-FEASIBILITY-AND-DESIGN.md) | Why blocking must run in-process, and the design that follows |
| [03 — Build, signing, and test plan](docs/03-BUILD-SIGN-TEST-PLAN.md) | The build lane, installation reality, staged runtime plan |
| [04 — Integrity and delivery audit](docs/04-INTEGRITY-AND-DELIVERY-AUDIT.md) | TLS, update and delivery audit *(415-era)* |
| [05 — Historical demo builds](docs/05-HISTORICAL-DEMO-BUILDS.md) | Superseded dialog and separate-ID demos *(historical)* |
| [07 — Clone Blocker guide](docs/07-CLONE-BLOCKER-AUTO-BLOCK.md) | What it does, how to install it, how to test it safely |
| [08 — AI-driven patchlets](docs/08-AI-DRIVEN-PATCHLETS.md) | The patchlet model, trust boundary, updating to a new APK |
| [09 — Activity, Settings, inline controls](docs/09-ACTIVITY-SETTINGS-AND-INLINE-BLOCK.md) | The UI contract |
| [10 — Reporting and limits](docs/10-REPORTING-AND-LIMITS.md) | Report flow, payload privacy, the limits contract |
| [11 — SOCKS5 proxy](docs/11-SOCKS5-PROXY.md) | App-scoped transport, bypass rules, fail-closed guard |
| [12 — Passive blocking](docs/12-PASSIVE-BLOCKING.md) | Signed list, indexing, visible-row admission |
| [13 — In-app updates](docs/13-IN-APP-UPDATES.md) | Signed metadata, verification, installer boundary |

[AGENTS.md](AGENTS.md) holds the binding project rules.
[patchlets/README.md](patchlets/README.md) documents the patchlet engine itself.

## License

[MIT](LICENSE) for this project's own code and documentation. It does not extend to Meta's Threads
application, to any APK derived from it, or to any Meta trademark.

Bundled third-party components — hev-socks5-tunnel (MIT), lwIP (BSD 3-Clause) and ed25519-java
(CC0) — are attributed in [NOTICE](NOTICE).
