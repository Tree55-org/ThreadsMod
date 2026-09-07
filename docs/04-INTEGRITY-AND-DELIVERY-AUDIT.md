# Integrity, TLS, updates, and delivery audit

## Scope

Every finding in this audit comes from one file: the historical monolithic APK `com.instagram.barcelona-444-0-0-45-85-arm64-v8a-android60.apk`, SHA-256 `0f6b4515902f78ea194b1bc0563bfcab07f2559d8e80cf6f329d3d1ef786487e`.
Its filename says 444; its decoded manifest does not.
That APK declares package `com.instagram.barcelona`, versionName `415.0.0.26.77`, versionCode `508504469`, minimum SDK 28, and target SDK 36.
Every `decompiled/jadx-1.5.6/...` path and line number below is an offset into the JADX tree produced from that single APK; a path written without that prefix is a path inside the APK itself.
Neither the source APK nor that tree is published with this repository, so those paths are reproduction coordinates rather than links; [01-APK-INVENTORY-AND-DECOMPILATION.md](01-APK-INVENTORY-AND-DECOMPILATION.md) records how the tree was generated and where the 415 evidence stops.

**These findings have never been re-run against the current `444.0.0.45.85` three-APK split source, and never against any released Clone Blocker build.**
None of the findings below has been re-verified since the 415 tree was cut.

The obfuscated coordinates are demonstrably stale.
The 415 APK carries 86,923 distinct `X`-package class names and the current 444 base APK — the one second source this document reads, and only for this staleness check — carries 95,040; not one name occurs in both, and the two builds do not even use the same name length.
Every `p000X/...` reference below therefore identifies a class in the 415 tree only, and has to be re-located from scratch before it says anything about 444.
Some of the human-readable names cross the version gap and some do not: `IgGooglePlayIntegrityAttestor`, `PlayIntegrityRequester`, `PlayIntegrityAttestationClient`, `VerificationPluginImpl`, `CertificateVerifier`, and `TigonMNSServiceHolder` still appear in the 444 base DEX string tables, while `PlayIntegrityAttestationWorker`, `PlayIntegrityAttestationScheduler`, and `BCNBottomHttpLayer` do not.
That is string presence only.
It was not investigated, and it is evidence for nothing about what 444 executes.

Read what follows as the integrity surface of one earlier Threads build, not as a current inventory.

## Summary

This APK has real Play Integrity scheduling, registration-flow SafetyNet calls, two TLS-pinning layers, Play in-app update code, and optional split-module delivery.
It also collects root/hook risk telemetry.
Static analysis did **not** establish an unconditional local startup kill for a re-signed APK; server-side enforcement and packed native behavior still require runtime testing.

Confidence labels below distinguish executable wiring from mere library or string presence.

## Play Integrity: executable and scheduled (high confidence)

- `decompiled/jadx-1.5.6/sources/com/instagram/security/attestation/playintegrity/client/IgGooglePlayIntegrityAttestor.java:44-53` obtains the Play Integrity client and requests a token.
- `decompiled/jadx-1.5.6/sources/com/instagram/security/attestation/playintegrity/client/PlayIntegrityRequester.java:53-68` validates the nonce, builds the request, and dispatches it; lines 96-99 mark success.
- `decompiled/jadx-1.5.6/sources/com/instagram/security/attestation/playintegrity/client/PlayIntegrityAttestationClient.java:113-137` obtains a nonce from `attestation/create_android_playintegrity/` with `app_scoped_device_id`; lines 63-85 submit validation and throw on validation failure.
- `decompiled/jadx-1.5.6/sources/p000X/C49628Nnl.java:580-618` mobile-config-gates and schedules unique WorkManager work named `PlayIntegrityAttestationScheduler`, with constraints and backoff.
- `decompiled/jadx-1.5.6/sources/com/instagram/security/attestation/playintegrity/worker/PlayIntegrityAttestationWorker.java:98-185` requires a `UserSession`, chooses an attestation implementation, and returns success or retry.

This proves a real periodic execution path, not just a bundled Play Core dependency.
The inspected failure path logs and retries; it does not prove that the app always exits locally.
Meta's server-side account or feature response is not visible in static code.

Android documents that modified binaries or certificate/package mismatches can receive `UNRECOGNIZED_VERSION`: [Play Integrity setup](https://developer.android.com/google/play/integrity/setup) and [remediation](https://developer.android.com/google/play/integrity/remediation).

## SafetyNet: executable in registration flows (high confidence)

- `decompiled/jadx-1.5.6/sources/com/instagram/nux/deviceverification/impl/VerificationPluginImpl.java:47-111` creates a nonce, checks Play Services, and runs SafetyNet attestation.
- `decompiled/jadx-1.5.6/sources/p000X/C8JI.java:8-24` reflectively instantiates and delegates to that implementation.
- Registration callers exist at `decompiled/jadx-1.5.6/sources/p000X/C6IT.java:655-664` and, behind mobile config, `decompiled/jadx-1.5.6/sources/p000X/C9NV.java:210-218`.

This is not evidence of a universal logged-in startup gate; it is concrete evidence for the identified registration paths.

## Signing and self-certificate checks (scoped)

`decompiled/jadx-1.5.6/sources/p000X/AbstractC27940xG.java:31-44` hashes the current package's first signing certificate and checks a trust set, with modern signing history support in `decompiled/jadx-1.5.6/sources/p000X/C203097si.java:25-49`.
Observed callers use the result for secure cross-app/provider/broadcast identity and telemetry decisions.
The inspected call graph did not show this check terminating the Threads process at startup.

The Meta signer hash and full certificates appear in data tables, but embedded presence is not itself enforcement.
Re-signing the APK replaces Meta's signature outright: the rebuilt package is no longer Meta-signed, and nothing the mod does restores that.
Android's independent signature-continuity rule is definitive: a build signed with a personal key cannot update or replace the Meta-signed install.
See [AOSP APK signing](https://source.android.com/docs/security/features/apksigning).

## TLS pinning: two real layers (high confidence)

### Android network security configuration

The manifest selects `@xml/fb_network_security_config` at `decompiled/jadx-1.5.6/resources/AndroidManifest.xml:147`.

`decompiled/jadx-1.5.6/resources/res/xml/fb_network_security_config.xml` shows:

- Lines 3-10: base config permits cleartext and trusts system plus user CAs; user CAs have `overridePins=true`.
- Lines 11-81: listed Meta/Instagram domains forbid cleartext and use 18 SHA-256 pins expiring 2027-01-28.
- Lines 82-94: nested redirect domains permit cleartext and have an empty pin set.

### Native/Java certificate verifier

- `decompiled/jadx-1.5.6/sources/p000X/C0JA.java:50-95` installs system trust, the same pin set/expiry, hashes public keys, and throws a pinning error.
- `decompiled/jadx-1.5.6/sources/p000X/C09060Iw.java:21-25` shows this pinning path is conditional; it does not prove every host/request is pinned.
- `decompiled/jadx-1.5.6/sources/com/facebook/mobilenetwork/internal/certificateverifier/CertificateVerifier.java:168-193` selects the trust manager and verifies hostnames.
- Tigon MNS loads the verifier in `decompiled/jadx-1.5.6/sources/com/facebook/tigon/tigonmns/TigonMNSServiceHolder.java:77-80`.
- `decompiled/jadx-1.5.6/sources/com/instagram/api/client/bottomhttplayer/bcnbottomhttplayer/BCNBottomHttpLayer.java:104-195` consumes pin-verification events and builds the Tigon layer.

Do not patch or bypass this machinery.
Fetch the custom list from a non-Meta HTTPS hostname using a separate platform client under ordinary system trust.
Do not reuse a Meta hostname, Tigon authentication, Threads cookies, or Threads tokens.

## Play update path (high confidence)

- `decompiled/jadx-1.5.6/sources/p000X/Pcq.java:15-16` binds Play's update service.
- `decompiled/jadx-1.5.6/sources/p000X/C52521Rtm.java:21-80` sets the current package and validates the Play Store signer.
- `decompiled/jadx-1.5.6/sources/com/instagram/barcelona/mainactivity/BarcelonaActivity.java:1754-1759,1848-1853` invokes the update path behind a feature flag.
- `decompiled/jadx-1.5.6/sources/p000X/C51337Pcx.java:137-145` requests update info; `decompiled/jadx-1.5.6/sources/p000X/C55174iA5.java:60-98` registers the listener and launches Play's update pending intent.

A personal-signer build cannot install Meta's official update.
A prototype should test whether the prompt appears and whether it can be disabled through normal mod-owned UI logic; this audit does not recommend an integrity bypass.

## Split and dynamic delivery (high confidence on wiring)

- `decompiled/jadx-1.5.6/resources/AndroidManifest.xml:1929-1934` identifies fused `base,longtail` modules and vending split metadata.
- `decompiled/jadx-1.5.6/resources/assets/app_modules.json` marks `longtail` built-in and lists downloadable modules with expected SHA-256 hashes.
- `decompiled/jadx-1.5.6/sources/p000X/C128294up.java:16-73` binds SplitInstall, validates the Play Store signer, and enumerates modules.
- Real callers exist in the language downloader (`decompiled/jadx-1.5.6/sources/p000X/Qde.java:38-68`) and Helium flow (`decompiled/jadx-1.5.6/sources/p000X/C55126haN.java:164-203`).
- `decompiled/jadx-1.5.6/sources/p000X/C127034sn.java:270-421` accepts split intents, checks declared contents/hashes, and rejects unverifiable module contents.

The supplied base/longtail APK decoded and rebuilt together.
Optional Play-delivered modules may not be available to the re-signed/sideloaded package.
Exact impact is a runtime boundary.

## Root/hook telemetry, not a proven local kill

`decompiled/jadx-1.5.6/sources/p000X/AbstractC42249Jm0.java:207-259` checks common root, Magisk, Xposed, Dobby, and Riru artifacts and `/proc/self/maps`.
Lines 377-394 serialize flags and a risk score; lines 485-518 encrypt the result and install it as browser/auth risk data.
Real calls exist in browser/auth result paths.

No local deny/exit was found in that inspected path.
That does not rule out server-side use or behavior inside the packed native payload.
`assets/lib/libs.spo` contains compressed native code and `assets/lib/metadata.txt` records native file hashes.
Avoid modifying that archive or metadata.

## Consequences for the prototype

None of the items below has been answered by observation.
No published build has ever been installed on a device: runtime validation is `not-run` for every artifact this project has released, which proves no installation, device UI, login, account mutation, or live network behavior.

1. Expect Play Integrity to run eventually; a successful cold start is not sufficient evidence.
2. Test long enough for scheduled attestation and inspect account behavior without trying to bypass a verdict.
3. Keep custom networking separate from Meta's pinned Tigon stack.
4. Treat Play update UI and optional module downloads as likely degraded in a personal-signer build.
5. Do not rename the package casually: authorities, permissions, cross-app trust, class loading, store links, and backend assumptions use `com.instagram.barcelona`.
6. Do not infer enforcement from a certificate string or library alone, and do not infer safety from the absence of a Java kill branch while packed native code remains.

Consequence 5 was acted on, not ignored.
Clone Blocker ships as application ID `app.tree55.threads` with launcher label `Threads 55`, rebasing only clone-owned namespaces while keeping the original component class names such as `com.instagram.barcelona.mainactivity.BarcelonaActivity`.
[05-HISTORICAL-DEMO-BUILDS.md](05-HISTORICAL-DEMO-BUILDS.md) records how that mapping was built and what it deliberately leaves alone.
