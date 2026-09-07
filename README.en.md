# Clone Blocker for Threads

*[Tiếng Việt](README.md) · English*

Clone Blocker patches Meta's Threads app for Android into a re-signed clone —
application ID `app.tree55.threads`, launcher label **Threads 55** — that blocks
impersonator accounts from a shared community list.

It installs *beside* official Threads rather than replacing it. Not affiliated
with Meta, and not on any app store.

## Install

<a href="https://cdn.jsdelivr.net/gh/Tree55-org/ThreadsMod@main/docs/media/threads55-install-guide.mp4"><img src="docs/media/threads55-install-guide-poster.jpg" width="270" alt="Install and block walkthrough video, 47 seconds (Vietnamese captions)"></a>

**[▶ Watch the walkthrough — 47 s](https://cdn.jsdelivr.net/gh/Tree55-org/ThreadsMod@main/docs/media/threads55-install-guide.mp4)** (Vietnamese captions; plays in the browser)
· [download the MP4](https://raw.githubusercontent.com/Tree55-org/ThreadsMod/main/docs/media/threads55-install-guide.mp4)
· [file in the repo](docs/media/threads55-install-guide.mp4).
It is an animated mockup of the UI, not footage from a device.

Download from the **[release page](https://github.com/Tree55-org/ThreadsMod/releases/tag/release)**:

| File | Size | Use |
|---|---:|---|
| `tree55-threads-mod.apk` | 129 MB | The app. Install this. |
| `tree55-threads-mod.zip` | 83 MB | The same APK, zipped — for when `.apk` downloads are blocked. Unzip, then install. |

Requires **Android 9 or newer**, **arm64-v8a**. You will need to allow installing
from an unknown source.

Verify the download before installing — it should be exactly:

```
SHA-256  e6ec4d70dacfa094659e31e09f2a890c537ba72b574767d62337a6a929c672a4
```

```powershell
Get-FileHash -Algorithm SHA256 tree55-threads-mod.apk    # Windows
sha256sum tree55-threads-mod.apk                         # Linux / macOS
```

If the hash does not match, do not install it.

Installing over an earlier **Threads 55** keeps your data. It can never update or
replace official Threads, and an older `com.threadsmod.barcelona` build is a
separate app the updater cannot bridge.

Read [what it does](#what-it-does) and the [risks](#risks) first, and test with an
account you can afford to lose.

## What it does

- **Blocks impersonators as you scroll.** It syncs a signed community list every
  ten minutes while the app is open, and blocks a listed account when that
  account's own post or reply appears on screen — one at a time, with a random
  delay.
- **This is always on.** There is no switch. Uninstalling is the only way to stop it.
- **One Block control on every post and reply**, opening a single *Block and
  report* dialog: the post excerpt, a reason, an optional *Also block this
  profile*, and Cancel.
- **Reports are never automatic** — only an explicit tap sends one.
- **Settings and Activity screens** from the bottom of the left drawer: list
  status, record counts, the report outbox, and history.
- **Optional SOCKS5 proxy** covering only this app. Off by default.
- **Signed in-app updates**, handed to Android's normal installer — never a
  silent or root install.

**Blocks are real.** They run through Threads' own block action on your live
session, so they appear in official Threads, apply on every device using that
account, and are **not** undone by uninstalling.

## Status

Current build `tree55-threads-mod.apk`, published 2026-09-06, from patchlet
series 005 r1, 010 r5, 020 r24, 030 r7, 040 r2, 050 r17, 060 r14, 070 r10,
080 r3, 085 r2, 090 r62.

**No published build has ever been installed or started on a device.** Every
release records `runtimeValidation: not-run`. The release gates are static — they
prove properties of the signed bytes, not that the app works. Login, feed
scrolling, a real block, report delivery and the updater are all unexercised on
hardware. Treat this as unverified software.

History: [docs/CHANGELOG.md](docs/CHANGELOG.md).

## Privacy

Blocking uses Threads' own authenticated action. **No Threads session, cookie,
token or account ID is ever sent to this project's backend.**

The list is read from three fixed mirrors, and every object's SHA-256 is proven
against a signed manifest before it is parsed. There are exactly two things sent
out: a report, only when you tap to send one, and one anonymous activation ping
per install. No analytics, advertising or crash SDKs — that is gate-enforced.

A report stores your connection IP, User-Agent and derived city/country on the
relay, with no automatic expiry. Full detail:
[docs/10](docs/10-REPORTING-AND-LIMITS.md).

## Risks

- Modifying the APK voids Meta's signature, so this can never coexist with
  official Threads under the same package name.
- The private endpoints and obfuscated class names are not stable APIs. Every
  Threads release needs new work.
- Play Integrity, Facebook/Instagram sign-in, App Links and Play updates are
  expected to fail or degrade under a personal signer.
- Automating private APIs may violate Meta's terms and can put the account at
  risk. Use a disposable account.
- Do not redistribute a modified Meta APK without legal review.

## Build it yourself

Requires Windows with PowerShell 7, a JDK, Android SDK build-tools 36.0.0, and
the pinned toolchain (Apktool 3.0.3, APKEditor 1.4.9, JADX 1.5.6). The upstream
Threads APKs and the toolchain are **not** in this repository; their exact hashes
are pinned in the resolution.

Releasing is two-phase: a non-publishing `SignedReview` run, a human promotion of
the resolution to `verified-current`, then a `Release` run that publishes. The
commands are in [docs/03](docs/03-BUILD-SIGN-TEST-PLAN.md); the per-stage scripts
are in [patchlets/README.md](patchlets/README.md).

Nothing is hand-edited. The mod is eleven ordered, exact-count patchlets replayed
against a hash-locked source set, with every obfuscated symbol isolated in a
per-version resolution. Any drift fails closed and produces no artifact.

## Layout

| Path | |
|---|---|
| `patchlets/` | Canonical source — every change starts here |
| `patchlets/features/` | The eleven patchlets |
| `patchlets/resolutions/` | Per-version symbol bindings and evidence |
| `patchlets/tools/` | The build pipeline and DEX inspectors |
| `docs/` | Design and operator documentation |
| `AGENTS.md` | Binding project rules |

Upstream APKs, `dist/`, `work/`, `decompiled/` and `.tools/` are local-only —
Meta's binaries, files over GitHub's size limit, or per-run evidence. Their hashes
are pinned, so builds reproduce without them.

## Documentation

[Changelog](docs/CHANGELOG.md) ·
[01 APK inventory](docs/01-APK-INVENTORY-AND-DECOMPILATION.md) ·
[02 Feasibility and design](docs/02-AUTO-BLOCK-FEASIBILITY-AND-DESIGN.md) ·
[03 Build, signing, tests](docs/03-BUILD-SIGN-TEST-PLAN.md) ·
[04 Integrity audit](docs/04-INTEGRITY-AND-DELIVERY-AUDIT.md) ·
[05 Historical demos](docs/05-HISTORICAL-DEMO-BUILDS.md) ·
[07 Clone Blocker guide](docs/07-CLONE-BLOCKER-AUTO-BLOCK.md) ·
[08 Patchlet system](docs/08-AI-DRIVEN-PATCHLETS.md) ·
[09 UI contract](docs/09-ACTIVITY-SETTINGS-AND-INLINE-BLOCK.md) ·
[10 Reporting and limits](docs/10-REPORTING-AND-LIMITS.md) ·
[11 SOCKS5 proxy](docs/11-SOCKS5-PROXY.md) ·
[12 Passive blocking](docs/12-PASSIVE-BLOCKING.md) ·
[13 In-app updates](docs/13-IN-APP-UPDATES.md)

## License

[MIT](LICENSE) for this project's own code and documentation. It does not extend
to Meta's Threads app, to any APK derived from it, or to any Meta trademark.
Bundled third-party components are attributed in [NOTICE](NOTICE).
