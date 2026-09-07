# 010 — Separate application identity

Revision 5 changes the clone's launcher label from `Threads Mod Demo` to `Threads 55`. Only the two label rewrites move: `manifest-labels` still replaces the same `android:label="@string/APKTOOL_RENAMED_0x7f13000d"` anchor twice, and `resource-app-label` still replaces the same `strings.xml` entry once, so every `before` anchor and expected count is unchanged and only the replacement text differs. The resolution's `target.label` carries the same value; `resolution.schema.json` requires that field, but no release gate reads it back, so the two rewrites' exact `after` values and counts are the only binding on the shipped label. The signed-APK identity gate compares `target.applicationId`, the required provider authorities, task affinities, custom permissions and authenticator account type, none of which this revision touches. The application ID is untouched, so this revision changes what the launcher shows and nothing about which package Android installs. The historical Threads 415 resolution keeps `Threads Mod Demo`; it documents already-published artifacts. Revision 5 was reviewed by the r60 `SignedReview` (candidate SHA-256 `f7a5ee38c07d050e34defa73d1c6737e8c340f7f7187327d6d13cafe40488f9e`), promoted (resolution SHA-256 `6014c9090e86c8ba7c8497addc47936ee8f9f73aa673e58f4f24c3b582d1f42b`), and published (released APK SHA-256 `ca53165cc8f511e17b5967b49aae0c4b0fb0629da7da6dd0c46718250f1b3e73`) on 2026-09-05.

Revision 4 renames the clone application ID from `com.threadsmod.barcelona` to `app.tree55.threads`. The rename covers the manifest package, all seven provider authorities, the dynamic-receiver permission, the task affinities, the account type and the self-package Smali references through the same 63 exact identity rewrites; every `before` anchor and every expected count is unchanged because only the replacement identity moved. The mod's own Java packages (`com.threadsmod.*`) and injected class descriptors (`Lthreadsmod/...`) are deliberately untouched: the old application ID is never a prefix of them, so the replacement is exact rather than a global rename. Android treats the new ID as a different package, so a build from this revision installs beside an existing `com.threadsmod.barcelona` clone instead of upgrading it, and patchlet 085 cannot bridge the two because it requires the downloaded archive's package to equal the clone ID. The historical Threads 415 resolution keeps the old identity; it documents already-published artifacts. `app.tree55.threads` does not contain the forbidden `tree55.com` needle, so the case-insensitive final-DEX forbidden-string gate is unaffected.

This patchlet turns the reviewed Threads package into the separate Android application ID `app.tree55.threads`. It is a selective identity conversion, not a global text replacement.

## Owned behavior

Revision 3 explicitly owns the union of every per-rule identity rewrite ID in
the historical exact 415 resolution and the current exact 444 resolution. The
catalog still requires every active rule to have exactly one owner, and it
requires every owned alternative to occur in at least one of those reviewed
resolution rewrite sets. An ID from one APK version therefore cannot silently
be treated as an active rewrite for the other version.

The APK-SHA-bound `identity-rewrites.json` controls every edit. Across the reviewed resolutions it covers:

- manifest package, app and launcher labels;
- app-declared permissions and their consumers;
- provider authorities;
- five explicit task affinities;
- AccountManager type and its reviewed DEX constants;
- clone-owned push categories, birthday action, shortcut permission, FileProvider consumers and lite-provider URIs;
- reviewed current-package checks used by Android/Play-facing code.

Real component class descriptors remain in their original namespaces. Intentional references to the official product, store listing, cross-app services and backend bundle identifiers are preserved unless a reviewed rule says otherwise.

## Deterministic application

Each rule declares one path, a before value or file, an after value or file, and an exact count. The engine permits only two states:

1. `before` occurs at the declared count and `after` does not: apply the rule.
2. `after` occurs at the declared count and `before` does not: record an idempotent no-op.

Both states present, neither state present, or a different count is drift. The engine stops without broadening a match, scanning-and-replacing the whole package name, or publishing an APK.

## Resolution and AI boundary

The rewrite set is valid only when the input APK SHA-256 exactly equals `resolution.source.sha256`. A similar version name or filename is insufficient.

For a future APK, AI may classify deterministic candidate occurrences and propose new exact rules with evidence. It may not edit the decoded production tree, rename component packages, accept ambiguous occurrences, or relax counts. The proposal must be reviewed and imported as a new SHA-bound resolution before application.

## Required gates

- Every rewrite reaches its exact after-count.
- No new identity occurrence remains unclassified.
- Manifest component class descriptors match the source APK.
- Declared provider authorities, app-owned permissions and explicit task affinities do not collide with the official APK.
- Authenticator type and proven current-package consumers use the clone ID.

This patchlet proves static Android namespace separation. It does not claim that Meta login, Play Integrity, SSO, verified links or backend services accept the re-signed clone.
