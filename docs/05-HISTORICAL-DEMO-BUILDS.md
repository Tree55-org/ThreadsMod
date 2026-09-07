# Historical demo builds

**Historical — these builds are superseded and their APKs are not retained.**
Two proof-of-concept builds from 2026-08-30 are recorded here: a same-package dialog demo, and the first clone that carried its own Android application ID.
Neither APK is in the repository, neither is among the retained build artifacts, and no recorded APK hash for either survives anywhere in the tree, so nothing described here can be installed or re-verified.
Both are superseded by the shipped Clone Blocker build described in [07 — Clone Blocker guide](07-CLONE-BLOCKER-AUTO-BLOCK.md); release history lives in [the changelog](CHANGELOG.md).

The code these builds demonstrated is gone from the canonical tree.
`com.threadsmod.DemoDialog` was deleted by patchlet 020 r23, so the clone opens with no mod dialog.
The clone application ID `com.threadsmod.barcelona` was replaced by `app.tree55.threads` in patchlet 010 r4.

This document is kept for one reason.
It holds the evidence that a re-signed clone can carry a separate Android application ID and sit beside official Threads at every install-time layer, which is the design the shipped product still rests on.

## The two builds

Both were derived from Threads `415.0.0.26.77` (`versionCode 508504469`), minimum and target SDK 28 and 36, arm64-v8a only, built from a single downloaded APK with 12 root DEX files.

The dialog demo kept the official package name `com.instagram.barcelona` and changed one thing.
After `BarcelonaActivity` completed its superclass `onResume()`, it called a helper that showed one Android dialog per app process, titled `Threads Mod Demo`, with the message `The demo modification loaded successfully. No network or account actions are included.` and a single `OK` button.
The helper refused finishing or destroyed activities, set its process guard before creating any UI, retained no Activity or Dialog reference, and caught every dialog failure so the optional proof could not intentionally crash Threads.
It performed no server fetch, no block, no unblock, no session access, and no other account mutation.

That build could not coexist with official Threads, which is what produced the second one.
A re-signed APK that keeps the official package name presents a different signing identity under the same name, so Android refuses to install it over the Meta-signed app and reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE` while any differently signed build of that package is registered.
Installing it therefore required removing the official app first, which deletes that installation's local data, and a work profile or per-user removal is not a guaranteed signer-isolation boundary.
This constraint has not changed and still applies to any same-package rebuild.

The separate-ID clone demo carried the same dialog payload under application ID `com.threadsmod.barcelona` with launcher label `Threads Mod Demo`.
It was separate from official Threads at Android's package, UID, data-directory, provider, permission, AccountManager, process and task-affinity layers.
That is more than a one-field manifest rename: the build selectively rebased clone-owned namespaces while preserving original component class names such as `com.instagram.barcelona.mainactivity.BarcelonaActivity`, because renaming every `com.instagram.barcelona.*` class would make the manifest point at classes that do not exist.

| Property | Dialog demo | Separate-ID clone demo |
|---|---|---|
| Application ID | `com.instagram.barcelona` (unchanged) | `com.threadsmod.barcelona` |
| Label | `Threads` (unchanged) | `Threads Mod Demo` |
| Launcher class | `com.instagram.barcelona.mainactivity.BarcelonaActivity` | `com.instagram.barcelona.mainactivity.BarcelonaActivity` |
| Version | `415.0.0.26.77` (`versionCode 508504469`) | `415.0.0.26.77` (`versionCode 508504469`) |
| Minimum / target SDK | 28 / 36 | 28 / 36 |
| ABI | `arm64-v8a` only | `arm64-v8a` only |
| Signature | one v2 signer; v1, v3 and v4 disabled | one v2 signer; v1, v3 and v4 disabled |
| Signer certificate SHA-256 | `317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079` | `317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079` |

The clone column's application ID, label, launcher class and required signer certificate are the values pinned in [`patchlets/resolutions/415.0.0.26.77/resolution.json`](../patchlets/resolutions/415.0.0.26.77/resolution.json), which is why they can still be checked.
The version row is the source version that both demos left unchanged rather than that resolution's own later `target.versionCode`, and the dialog demo's identity is pinned nowhere, because it changed nothing about the official package.
The recorded file sizes and APK hashes of the two demo artifacts are not repeated here, because the files are gone and no pinned source corroborates them.

That signing certificate is not Meta's, and it is still the certificate the release gate requires today.
Modifying and re-signing the APK voids Meta's signature, for these builds and for every build since.

## Selective identity mapping

Against the official package, the clone rebased:

- the manifest package;
- all five declared provider authorities;
- all four app-declared permissions and their clone-owned consumers;
- five explicit task affinities, three of which never contained the official package prefix at all and had to be rewritten by name;
- the AccountManager type, from `www.instagram.barcelona` to `com.threadsmod.barcelona`, including all five direct DEX constants;
- clone-owned push categories, the birthday broadcast action, the shortcut permission reference, FileProvider consumers and lite-provider content URIs;
- reviewed current-package checks in the component factory, AppOps, running-service inspection, Android metadata, billing, update and split-install code;
- the application and launcher labels.

It deliberately did not globally replace every exact or prefixed occurrence of the official package.
Residual occurrences include real component class names, and intentional references to the official Threads product, its Play Store listing, cross-app providers, installed-app probes and backend `app_bundle_id` values.

The exact rule set is still readable: 54 rules in [`patchlets/resolutions/415.0.0.26.77/identity-rewrites.json`](../patchlets/resolutions/415.0.0.26.77/identity-rewrites.json).
Each rule declares one path, one before value, one after value and an exact count, and the engine applies it only when `before` occurs exactly that many times and `after` does not.
[`patchlets/features/010-clone-identity/PATCHLET.md`](../patchlets/features/010-clone-identity/PATCHLET.md) owns that contract now.

## Packaged coexistence verification

These checks were recorded against the final signed clone APK, not only against decoded source.

- `aapt2` reported package `com.threadsmod.barcelona`, label `Threads Mod Demo`, and the expected launcher class.
- The official and clone provider-authority sets intersected in `0` entries, across five authorities each.
- The official and clone declared-permission sets intersected in `0` entries, across four permissions each.
- The official and clone explicit task-affinity sets intersected in `0` entries, across five affinities each.
- The packaged authenticator XML reported account type `com.threadsmod.barcelona`.
- `apksigner verify -Werr` confirmed one v2 signer, with v1, v3 and v4 disabled.
- The APK passed 16 KiB `zipalign` verification and archive testing.
- Every root DEX checksum passed.
- The retired clone-owned AccountManager and FileProvider strings were absent from their respective DEX files.
- Targeted decompilation of the signed APK recovered the injected dialog call in `BarcelonaActivity`, the dialog implementation, and the component factory's self-package comparison against the clone ID.
- Every `lib/**` and `assets/lib/**` payload entry was hash-identical to the supplied original APK.

The zero-intersection results are the load-bearing part, and they are structural rather than incidental: each rewritten authority, permission and task affinity lands in a clone-owned namespace that the official app does not declare.

These checks establish install-time namespace separation and nothing more.
No Android device was attached, so they do not prove that both apps start, log in, or stay independent on a real phone.
That boundary has never been lifted.
Every published build records `runtimeValidation: not-run`, and no published build has been installed or run on any device.

## Important runtime boundaries

These were written for the demo clone and remain true of the shipped product.

- Play Integrity reports the clone's actual package and certificate, which do not match Meta's Play configuration, so scheduled attestation and protected backend flows can fail even when cold start succeeds.
- The signing certificate is not in Meta's trusted signing allowlist, so Facebook and Instagram SSO, signature permissions, shared providers and cross-app callbacks can fail or fall back.
- Official `threads.com` and `threads.net` App Links cannot verify for the clone without server-side `assetlinks.json` authorization.
- The custom `barcelona://` scheme stays shared with official Threads, which can affect link routing; it does not merge app storage or packages.
- Billing, Play in-app update and Play split-install calls use the clone ID for UID consistency, but the clone is not Play-listed, so those calls are expected to fail or be unavailable.
- Some backend requests intentionally retain the official product bundle ID; changing them blindly would break a server contract, and retaining them does not mean Meta accepts the clone.
- Packed native code can contain checks that plaintext scanning does not recover.

A separate app is therefore proven at Android's static install namespace, not at Meta's authentication or backend layer.
The integrity, TLS and delivery audit behind these bullets is [04 — Integrity and delivery audit](04-INTEGRITY-AND-DELIVERY-AUDIT.md).

## What carried forward

The separate application ID became the shipped design.
The current clone is `app.tree55.threads`, launcher label `Threads 55`, versionName `444.0.0.45.85-threadsmod.1`, `versionCode 511407878`, minimum and target SDK 28 and 36, arm64-v8a.
It is built from a hash-locked three-APK split source set with 13 root DEX files rather than from one downloaded APK, and the identity conversion is still selective and rule-pinned: 63 exact rewrites at 444, covering seven provider authorities and six task affinities.
Both resolutions cap primary-DEX method references at 65,535, and both require the same signer certificate.

## What did not carry forward

The first-run dialog is gone.
`com.threadsmod.DemoDialog` was deleted from the canonical tree and from patchlet 020's class prefixes, class descriptors and compiled sources, and the release gate now proves that the descriptor is absent from the shipped DEX.
Disclosure of always-on passive blocking and of the activation ping lives in the mod Settings screen instead, on the Passive blocking card and the Reports card.

The old application ID is gone, and this is the part of the historical record that most needs correcting.
Keeping `com.threadsmod.barcelona` does not give an upgrade path to anything.
Android treats `app.tree55.threads` as a different package, so a current build installs beside an old `com.threadsmod.barcelona` clone instead of upgrading it, and the in-app updater cannot bridge the two because it requires the downloaded archive's package to equal the clone ID; see [13 — In-app updates](13-IN-APP-UPDATES.md).
Anyone still running the old clone should uninstall it from Android Settings, which deletes that clone's local app data and nothing else.
Uninstalling does not undo any block the old clone already applied: a block is server-side account state, and it stays on the account.

The harmlessness of the demos did not carry forward either.
The demo builds performed no blocking of any kind.
The shipped product does: passive blocking is always on, there is no in-app switch to turn it off, and a block is real server-side account state that stays on the account after the clone is uninstalled.
The passive delay bounds and the full limits contract are owned by [10 — Reporting and limits](10-REPORTING-AND-LIMITS.md), and the blocking behaviour itself by [12 — Passive blocking](12-PASSIVE-BLOCKING.md).
