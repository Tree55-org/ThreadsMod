# APK inventory and decompilation

This document owns two things: the identity of the source APKs the build starts from, and the provenance of the decompiled trees derived from them.
It says nothing about any published clone artifact.
Artifact names, sizes, hashes and release order live in [`CHANGELOG.md`](CHANGELOG.md); the build, signing and release gates live in [`03-BUILD-SIGN-TEST-PLAN.md`](03-BUILD-SIGN-TEST-PLAN.md).

## Current source: the exact Threads 444 split set

The current work starts from three APKs in `Threads-444.0.0.45.85/`.
That directory is Meta's signed upstream release, is not redistributable, and is not part of this repository; the hashes below are how a reader confirms they hold the same bytes.
The three files are one indivisible source set: the base carries the code, and the arm64-v8a and xhdpi configuration APKs carry the required native and density payloads.
The canonical APK-only tree aggregate is computed by `Get-PatchletTreeSha256 -Filter '*.apk'`.
A matching version name without these exact member bytes is not release authority.

| Role | File | Size | SHA-256 |
|---|---|---:|---|
| Base | `base.apk` | 60,119,977 bytes | `16c2e2c31f7f4481d3a7c4d3e754ceaaef1b22255dab5b8605ef4b7893401b24` |
| ABI configuration | `split_config.arm64_v8a.apk` | 65,743,557 bytes | `b1af0d13bcf22bd729e489399217c7c4c0549bdcb06e21ca5882c5085fb2eedb` |
| Density configuration | `split_config.xhdpi.apk` | 4,307,549 bytes | `11ba8380bd6595a8d4161da3ced7bfa31bae67da688e229d7a3ad42f6970b17c` |
| Exact APK-only set | all three files above | 130,171,083 bytes | `5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff` |

`aapt2` identifies the base as package `com.instagram.barcelona`, versionName `444.0.0.45.85`, versionCode `511407877`, minimum SDK 28, target SDK 36 and compile SDK 37.
The configuration members carry the same package and version code, no version name of their own, and the exact split names `config.arm64_v8a` and `config.xhdpi`.
`apksigner` verifies the base as exactly one Meta Platforms Inc. signer under APK Signature Scheme v3 and v3.1, together with a Google source stamp; it does not verify as v1, v2, v3.2 or v4.
The v3.0 block carries the same certificate as the historical 415 APK below, SHA-256 `5367570bad488d8da6a0fab78d9766a1a4c23c3c70fac0ad2e91c8f0bd58b432`, and the v3.1 block carries a rotated key for API 33 and above, SHA-256 `8f38da6b4dc34b1900353bde4630043198cbe3ef7214151f86679cd000c90500`.

## Clone identity produced from this source

The patchlet series rewrites that source into a separately installable clone.

| Property | Value |
|---|---|
| Application ID | `app.tree55.threads` |
| Launcher label | `Threads 55` |
| Version name | `444.0.0.45.85-threadsmod.1` |
| Version code | `511407878` |
| Mod build | `CURRENT_MOD_BUILD` = 1 |
| Minimum / target SDK | 28 / 36 |
| ABI | `arm64-v8a` |

`patchlets/resolutions/444.0.0.45.85/resolution.json` is the authority for every value in that table.

The earlier clone package `com.threadsmod.barcelona` is historical and is not the current target.
Android treats it as a different application, so a `com.threadsmod.barcelona` install sits side by side with `app.tree55.threads` instead of being replaced by it, and the in-app updater cannot bridge the two package names.

Patching and re-signing replace Meta's signature with a different key, which voids Meta's signature on the result.
The clone is an unofficial, self-signed application, and no build in this repository is endorsed by or affiliated with Meta.

## Patchlet 005 standalone derivation

Patchlet `005-split-source-universalization` snapshots and locks only the three resolution-listed APKs.
It verifies their leaf names, sizes, SHA-256 values, aggregate digest, package and version, and base/ABI/density roles.
It then invokes the SHA-pinned APKEditor 1.4.9 merge twice with the exact reviewed arguments:

```text
APKEditor 1.4.9 m -i {sourceSet} -o {outputApk} -clean-meta -validate-modules -extractNativeLibs false
```

Both fresh outputs must be byte-identical to each other and to the resolution's recorded hash.
Root DEX, arm64 native-library and density-resource entry paths and bytes must survive the merge, while split-delivery metadata must be removed.

The observed deterministic standalone input is intentionally unsigned:

| Artifact | Size | SHA-256 |
|---|---:|---|
| derived universal unsigned APK (`work/pipeline-merge-smoke-444/merged.apk`) | 129,140,327 bytes | `156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec` |

Those bytes are the pristine APK that the ordinary patchlets decode and patch.
The derived APK reports package `com.instagram.barcelona`, versionCode `511407877`, versionName `444.0.0.45.85`, minimum SDK 28 and target SDK 36, and it carries 13 root DEX files, 69 arm64 native libraries and the xhdpi split's 6,364 density resource entries.
It is not itself a mod APK, is not signed, and is not a publishable artifact.
The path above is a local working directory that is not published with this repository.

No build produced from this source has been installed on a device.
`runtimeValidation` is `not-run` for every published release, so nothing in this document proves installability, startup or runtime behaviour.

## Current toolchain provenance

`patchlets/resolutions/444.0.0.45.85/resolution.json` pins the tools that touch the source set, by version and by JAR SHA-256.
A different version or a different jar stops the build rather than producing a differently derived source.

| Tool | Version | Pinned SHA-256 |
|---|---|---|
| APKEditor (with ARSCLib 1.3.9) | 1.4.9 | `a9cd40df818845456be6d696de6110c89edf4b0a0580cb83438ed6b25a366e67` |
| Apktool | 3.0.3 | `dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423` |
| Apktool framework APK | android platform 36 | `5dd984016ed5a5eb0eef866e2c6e8cd352e1427828ec23adb18005cf5648f3d7` |
| `d8` (Build-Tools 36.0.0) | 36.0.0 | `4097ff9c46c185c6e7214da7fe9b1befb5adeea5cc9ca349270e0249904f9240` |
| `apksigner` (Build-Tools 36.0.0) | 36.0.0 | `3716d9311e55d2b0918a2fd9d54ba9e406c5f6abeea700b287f11259bc163dec` |
| JADX | 1.5.6 | `fe3e12c45acf75f92369685fd02d1d7a7323385dc725680a9b98a0dac0ea554b` |

## Historical 415 monolithic-source evidence

*The rest of this document describes the superseded 415 monolithic input, not the 444 split source above.*

These sections preserve the earlier single-APK inventory.
They apply only to source SHA-256 `0f6b4515902f78ea194b1bc0563bfcab07f2559d8e80cf6f329d3d1ef786487e`, whose manifest reports Threads `415.0.0.26.77`.
They do not validate the current 444 split source or any 444 release.

That historical APK was inventoried, signature-verified, decompiled with two JADX strategies, decoded to smali and resources with Apktool, and rebuilt without source changes.
The no-change rebuild succeeded and passed 16 KiB alignment verification.
It remains historical evidence and was never installed or runtime-tested.
Like the 444 split set, that APK is Meta's signed upstream release and is not part of this repository.

### Historical input identity

| Property | Observed value |
|---|---|
| File | `com.instagram.barcelona-444-0-0-45-85-arm64-v8a-android60.apk` |
| Size | 77,021,381 bytes |
| SHA-256 | `0f6b4515902f78ea194b1bc0563bfcab07f2559d8e80cf6f329d3d1ef786487e` |
| Package | `com.instagram.barcelona` |
| App label | Threads |
| Manifest version | `415.0.0.26.77` |
| Version code | `508504469` |
| Minimum SDK | 28 (Android 9) |
| Target / compile SDK | 36 / 36 |
| Launcher | `com.instagram.barcelona.mainactivity.BarcelonaActivity` |
| Application | `com.instagram.barcelona.app.BarcelonaAppShell` |
| ABI | `arm64-v8a` only |

The historical filename's apparent version `444.0.0.45.85` did **not** match that APK's decoded manifest.
That mismatch is specific to the old monolithic file; the current three-member source set genuinely reports `444.0.0.45.85`.
All patch and version gates use manifest metadata and exact hashes, never filenames alone.

### Historical signature and archive inventory

Android Build-Tools 37.0.0 verifies one APK Signature Scheme v2 signer.
It does not verify as v1, v3, v3.1, v3.2, v4 or SourceStamp.

| Signing property | Observed value |
|---|---|
| Certificate subject/issuer | Meta Platforms Inc., Meta Mobile, Menlo Park, California, US |
| Certificate SHA-256 | `5367570bad488d8da6a0fab78d9766a1a4c23c3c70fac0ad2e91c8f0bd58b432` |
| Key/signature | 4096-bit RSA / SHA256withRSA |
| Validity | 2023-01-26 through 2053-01-25 |

Archive facts:

- 13,085 ZIP entries.
- 12 root DEX files (`classes.dex` through `classes12.dex`).
- An additional DEX payload exists at `assets/longtail/classes.dex`; Apktool `--all-src` is required to decode it.
- 102,246 root-DEX class definitions and 517,341 per-DEX method-ID entries in aggregate. These are table totals, not unique method counts.
- 11 arm64 native libraries. `libstartup.so` is the dominant native payload.
- The original APK passes `zipalign -c -P 16 -v 4`.

Primary `classes.dex` contains 60,847 method references.
That leaves 4,688 references below the 65,535 primary-DEX ceiling that the release gate enforces, but a patch must measure the rebuilt DEX rather than assume a helper fits.

### Historical toolchain provenance

| Tool | Version / location | Verification |
|---|---|---|
| Java | Temurin JDK/JRE 21.0.12+8 | Local installation |
| JADX | 1.5.6 | GitHub release asset SHA-256 `545ea2be9c242511bc145755cf4bda2485ade42966e096f8b4d3da2a230e8974` |
| Apktool | 3.0.3 | GitHub release asset SHA-256 `dbf930b076c6b9be08d57c449cacefc3bdd6b71ebd59b3066fc0e1f5b14f9423` |
| Android Build-Tools | 36.0.0, 37.0.0 | Local Android SDK |

JADX 1.5.5 was initially selected from a stale search result.
The run was stopped once JADX 1.5.6 and its security fixes were identified.
The APK contains no `..`, absolute or drive-qualified archive entry names, and only generated workspace files were observed.
Further work used 1.5.6 exclusively.
Relevant advisories are [GHSA-gpvc-ccw7-744v](https://github.com/skylot/jadx/security/advisories/GHSA-gpvc-ccw7-744v), [GHSA-w6f5-h4x4-rfpj](https://github.com/skylot/jadx/security/advisories/GHSA-w6f5-h4x4-rfpj) and [GHSA-jwv3-q635-w9m4](https://github.com/skylot/jadx/security/advisories/GHSA-jwv3-q635-w9m4).

The downloaded Apktool hash matched GitHub's release-asset digest.
A GitHub CLI attestation lookup returned HTTP 404 in this environment, so the attestation was not counted as verified provenance.

Official tool sources: [JADX 1.5.6](https://github.com/skylot/jadx/releases/tag/v1.5.6), [Apktool 3.0.3](https://github.com/iBotPeaches/Apktool/releases/tag/v3.0.3), [Apktool CLI](https://apktool.org/docs/cli-parameters/), [apksigner](https://developer.android.com/tools/apksigner) and [zipalign](https://developer.android.com/tools/zipalign).

### Historical decompiled outputs and quality

The three trees below live under `decompiled/`, a local evidence directory that is not published with this repository.

#### Structured JADX view

`decompiled/jadx-1.5.6/` contains 95,813 Java files and 13,255 decoded resource files.
The structured pass reached 76,208 of 76,477 progress units (99%) but spent several minutes CPU-active on 269 pathological obfuscated classes.
It was stopped rather than treated as complete.

This view is the easiest one to read, but it carries many JADX warnings and 1,073 Java files with a `Method not decompiled` marker.
It is not suitable for rebuilding.

#### Linear JADX fallback

`decompiled/jadx-1.5.6-simple-sources/` was generated with `--decompilation-mode simple`, no resource pass and reduced inlining.
It processed 66,589 of 66,590 progress units, then exited non-zero with 102 reported errors.
Use it to recover control flow that the structured pass omitted, not as authoritative bytecode.

#### Apktool smali and resources

`decompiled/apktool-3.0.3/` contains 102,248 smali files across:

- `smali/`
- `smali_classes2/` through `smali_classes12/`
- `smali_assets@longtail@classes/`

Decode completed successfully.
Apktool emitted unresolved-resource-reference warnings while generating resource XML, but a no-change build completed, so the tree is rebuildable for this toolchain.
Smali remains the source of truth wherever JADX disagrees or reports malformed control flow.

### Historical reproduction commands

Run from the repository root in PowerShell.
`.\.tools\`, `.\decompiled\` and `.\work\` are local directories that this repository does not ship; the commands create them.

```powershell
$Apk = (Resolve-Path '.\com.instagram.barcelona-444-0-0-45-85-arm64-v8a-android60.apk').Path
$Java = 'C:\Program Files\Eclipse Adoptium\jdk-21.0.12.8-hotspot\bin\java.exe'
$Jadx = '.\.tools\jadx-1.5.6\bin\jadx.bat'
$Apktool = '.\.tools\apktool\apktool_3.0.3.jar'
$Framework = '.\decompiled\apktool-framework'

Get-FileHash -Algorithm SHA256 -LiteralPath $Apk

& $Jadx `
  --output-dir '.\decompiled\jadx-1.5.6' `
  --threads-count 8 `
  --deobf `
  --comments-level warn `
  $Apk

& $Java -jar $Apktool d `
  --all-src `
  --jobs 8 `
  --frame-path $Framework `
  --output '.\decompiled\apktool-3.0.3' `
  $Apk

& $Java -jar $Apktool b `
  --frame-path $Framework `
  --output '.\work\validation\threads-apktool-roundtrip-unsigned.apk' `
  '.\decompiled\apktool-3.0.3'
```

### Historical no-change rebuild validation

Apktool produced `work/validation/threads-apktool-roundtrip-unsigned.apk`, then Android Build-Tools 36.0.0 produced and verified a 16 KiB-aligned copy.

| Artifact | SHA-256 | Size |
|---|---|---:|
| Rebuilt unsigned | `a07b3f0f9e2a0ced7bf218e41f3732f71451b2778cad70b2e8ab72b6598aa05d` | 81,140,669 bytes |
| Aligned unsigned | `103b6f3baeae9778d70226a4ae7399afe34aa61f26438b5c27f43afcfe6643de` | 81,146,773 bytes |

The aligned output retains package `com.instagram.barcelona`, version `415.0.0.26.77`, minimum SDK 28 and target SDK 36.
`apksigner verify` correctly fails because no signing step was performed (`Missing META-INF/MANIFEST.MF`).
That failure is expected and proves neither installability nor runtime behaviour.

### What the historical evidence does not prove

- No modified feature exists in that rebuild.
- No output of it was signed or installed.
- No login, block request, server fetch, account switch, rate-limit or challenge flow was exercised.
- A no-change rebuild does not prove a changed APK will start; method limits, verifier errors, resources, integrity checks and backend enforcement still need device validation.
- Bundled libraries or strings alone do not prove a particular integrity or anti-tamper path is enforced at runtime.
