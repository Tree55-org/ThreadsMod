# 005 — split source universalization

## Purpose

Threads 444.0.0.45.85 is delivered as a base APK plus required ABI and density configuration APKs. The rest of this repository intentionally operates on one decoded APK and patchlet 085 updates one APK. This patchlet bridges those contracts by deterministically deriving one unsigned standalone patch input before patchlet 010 runs.

## Exact authority

The version resolution owns:

- the three ordered member roles, leaf names, byte sizes, and SHA-256 values;
- the APK-only aggregate source-set SHA-256;
- source package/version/SDK/ABI and payload counts;
- APKEditor 1.4.9, ARSCLib 1.3.9, the JAR SHA-256, and exact ordered merge arguments;
- the byte-identical derived APK SHA-256.

Patchlet 005 alone owns `split-set-to-standalone-apk` and `split-delivery-metadata-removal`. It owns no class, host hook, preference, database, or manifest component.

## Operation

The release wrapper copies only the resolution-listed APK members into a fresh snapshot and locks both the canonical and snapshotted sets. `Build-SplitSourceUniversalApk.ps1` validates each source archive and split manifest, then runs exactly:

```text
APKEditor 1.4.9 m -i {sourceSet} -o {outputApk} -clean-meta -validate-modules -extractNativeLibs false
```

It runs the merge twice into fresh files. Both hashes must equal each other and `/source/sha256`. The first file becomes the unchanged `SourceApk` supplied to existing decode, resolution, apply, idempotency, build, signed-candidate, updater, and publication logic. Reapplying patchlet 005 means deriving the same bytes again; there is no mutable decoded-tree operation.

## Blocking evidence

Release stops unless all of the following hold:

- exactly the three resolution members exist, with no nested or extra APK;
- package/version and base/ABI/density split roles match AAPT2 evidence;
- both merges are byte-identical and match the resolution;
- all source root DEX entries and selected-ABI native libraries are path-and-byte identical in the output;
- every selected-density `res/` payload remains path-and-byte identical and its configurations are present in the merged resource table;
- package, version, SDK and `extractNativeLibs=false` remain exact;
- `split`, `splitTypes`, `requiredSplitTypes`, and Play split-delivery metadata are absent;
- the derived artifact has no JAR signature entries and fails APK signer verification before the normal signing stage.

The intermediate merged APK is not required to be 16 KiB ZIP-aligned. The existing isolated Apktool build, zipalign `-P 16`, signature, signer, native-byte preservation, and final archive gates remain authoritative for the published APK.

## Rejected alternatives

An Apktool decode/rebuild of the xhdpi configuration split is not permitted because it rewrites the resource table and payload paths. A raw ZIP graft is also not permitted because it cannot semantically fold split resource configurations into the base table. A changed tool, option order, missing validation/metadata cleanup flag, `-f`, non-deterministic output, or relaxed preservation count requires a new reviewed patchlet revision and resolution.

## AI boundary

`RESOLVE-SPLIT-SOURCE-UNIVERSALIZATION.md` may inventory and propose exact evidence. It cannot choose an unreviewed split subset, edit canonical files, waive payload drift, promote a resolution, sign, install, or publish.
