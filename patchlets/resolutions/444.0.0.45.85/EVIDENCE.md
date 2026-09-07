# Threads 444.0.0.45.85 exact-resolution evidence

## Clone identity, always-on passive blocking, and activation statistics

The clone application ID is `app.tree55.threads` and the clone's launcher label is now
`Threads 55`. Patchlet 010 r5 moves the manifest package, all seven provider authorities, the
dynamic-receiver permission, task affinities, account type and self-package Smali references
through the same 63 identity rewrites; every `before` anchor and expected count is unchanged, and
`Test-Resolution` reports all 63 rules pristine against the pristine decoded tree. Two of those
rules carry the label rename and changed only their `after` value: `android:label` in
`AndroidManifest.xml` at expected count 2, and the `APKTOOL_RENAMED_0x7f13000d` string resource at
expected count 1, both now `Threads 55` where the 2026-09-05 `tree55` build wrote
`Threads Mod Demo`. The application ID is unchanged by the rename, so that revision was a label
change and not a second identity change. The mod Java packages `com.threadsmod.*` and descriptors
`Lthreadsmod/...` are unchanged, and `app.tree55.threads` does not contain the forbidden
`tree55.com` needle. Every paragraph below that names `com.threadsmod.barcelona` describes an
already-published artifact and keeps that identity as a fact; the historical Threads 415
resolution is untouched.

Passive blocking has been always enabled since patchlet 020 r21: it has no opt-in and no in-app
way to disable it. `AutoBlockSync.isEnabled(Context)` returns true for any non-null context and
reads no preference, `AutoBlockSync.disable(Context)` is deleted, patchlet 050 r16 replaced the
Settings switch with the static description `Always on. Refreshes the signed index every 10
minutes in the foreground, then blocks only listed profiles whose post or reply action row becomes
visible.`, and every `Enable & sync` button became `Sync now`. A null context is the only false
answer left, so the fail-closed path is intact; no user-facing state remains to read back or to
turn off.

The activation-statistics ping was gated on that same flag, so it is unconditional: it is sent on
the first eligible foreground resume of every installation instead of only after an opt-in.
`AGENTS.md` originally required explicit opt-in for both passive refresh and the ping; both rules
were rewritten on 2026-09-05 to require first-run disclosure instead, and rewritten again in the
revision 61 series so that the two sentences that named a first-run notice now point at the
Settings screen. Every other guarantee is unchanged: the closed 13-key payload, the HMAC install
identifier with no account, advertising or hardware input, at most one ping per installed build,
the 600,000 ms cadence, the persisted not-before guard, and the rule that a ping failure can never
affect Block, report, list, proxy or updater work. Through the 020 r22 series the first-run
`Threads Mod Auto Block` notice disclosed the full field list and reported
`Passive blocking: always on`; from 020 r23 that notice no longer exists, and the disclosure is the
Settings screen's Reports card, which names every field the ping carries, and its Passive blocking
card.

Patchlet 070 r10 owns the second reviewed write path `/v1/installs` on the existing AWS host for
one activation ping per installed build. Its install identifier is an HMAC of a local
random secret over the fixed tag `install:v1` with no account, advertising or hardware input, so
it is neither the reporting pseudonym nor linkable to a Threads account. The host gate proves the
closed 13-key payload, strict escape-free serialization, fail-closed validation, the absence of
every account field, and exactly two POST/output-stream paths bound to their own endpoint
accessors. No third-party analytics SDK is present. The backend route `POST /v1/installs` was
deployed to the origin on 2026-09-04 (migration `011_installs.sql`), and on that date the AWS relay
allowlist admitted exactly `/v1/installs` (Lambda code SHA-256
`3SCxLSR7srBGuYAfIjMu/CF6YHXyGkrQJVgjnBb7kL0=`), so a ping from this build is accepted end to end;
the relay Lambda was redeployed on 2026-09-06 for the chunked v3 blocklist paths (code SHA-256
`hOHq5WS6fN8yrNr/lBj14HDCymF0SdEYApCQ7LFBhoQ=`), as recorded in the revision 61 publication section
below. The `safeToken` forward-slash correction landed in the r59 revision set: the first draft
stripped the slash, and IANA time zones now survive intact.

The r60 `SignedReview`, the 2026-09-05 `Threads 55` human promotion checkpoint, and the
2026-09-05 default `Release` publication recorded below were the review, promotion, and publication
records for the 010 r5, 020 r21, 050 r16, 060 r14, 070 r10, and 090 r59 series; that publication,
SHA-256 `ca53165cc8f511e17b5967b49aae0c4b0fb0629da7da6dd0c46718250f1b3e73`, is superseded because on
a fresh install it displayed the status line `Disabled until you explicitly enable it.` while passive
blocking was running. The r61 `SignedReview`, the 2026-09-06 status-text human promotion checkpoint,
and the 2026-09-06 revision 60 default `Release` publication recorded below were the review,
promotion, and publication records for the 010 r5, 020 r22, 050 r17, 060 r14, 070 r10, 085 r1, and
090 r60 series; that publication,
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-b.apk`, SHA-256
`abcfb52fc23b1d819488789566c62189b5297183bf5e39652f17f132272d3bf8`, is superseded because it still
shows the first-run `Threads Mod Auto Block` dialog and, being bound to a 512 KiB mirror-response
cap, cannot refresh from a signed list larger than that.

The clone now opens with no mod dialog. Patchlet 020 r23 deletes `com.threadsmod.DemoDialog` from
the canonical tree and from its class prefixes, class descriptors and compiled sources;
`ModBootstrap.onResume` still hands every resume to `UpdateController.onResume`, and the no-update
continuation it passes is an empty, non-capturing `Runnable` that shows no UI. Patchlet 085 r2
changes only that continuation contract: the raw-DEX updater proof requires the `Runnable`'s
constructor to take no arguments, its `run()` body to be exactly one `return-void`, and the
`Lcom/threadsmod/DemoDialog;` descriptor to be absent from the primary DEX. Disclosure of always-on
passive blocking and of the activation ping lives in the Settings screen, in the Passive blocking
card and the Reports card.

In the revision 61 series, list refresh was repaired for the size the published whole-file
`blocklist.json` had reached: `AutoBlockSync.MAX_RESPONSE_BYTES` rose from 512 KiB to 4 MiB
(4,194,304 bytes), bounding each mirror response on both the declared Content-Length and the
streamed byte count, because on 2026-09-06 the signed list had grown to 545,168-548,306 bytes on
all three mirrors and every earlier build failed `too_large` on every mirror, showing
`List fetch: Failed — no valid index` and `Records: Unavailable`. From the revision 62 series that
4 MiB bound applies to the signed v3 root response, which is further capped at 524,288 characters
after decoding, and the whole-file read is retired from the client, as recorded below. Recovery
after a
failed attempt is now immediate and bounded: the next attempt follows after 15 s, 30 s, 60 s, 120 s
and 300 s, at most five ladder steps per foreground session and the ordinary 600,000 ms cadence
thereafter; the ladder resets on a successful attempt and on each background-to-foreground
transition, is installed through a three-argument `advanceListRefreshDeadline` overload whose
interval can never exceed `FETCH_INTERVAL_MS`, and a successful attempt still installs the exact
600,000 ms deadline. Once per foreground session, while no valid index exists and no sooner than
15 s after the last admitted start, the first ordinary request starts ahead of a pending deadline.
Within one attempt each mirror is retried exactly once, immediately, and only after an
`IOException` (timeout, DNS/connect, TLS, or a stream broken mid-body), never after an HTTP-status,
size, cookie, signature, schema, clock, stale, rollback or target-cap result. The retained-failure
status names one closed failure class per mirror in declared order from the set `too_large`,
`http_<status>` (or `http_other`), `timeout`, `unreachable`, `tls`, `io`, `signature`, `schema`,
`clock`, `stale`, `rollback`, `target_cap`, `cookie_refused` and `internal`, chosen by exception
type and never from a message, URL, header or body, for example `mirror 1 too_large`. The ladder
array is built element by element in the helper `listRefreshFailureLadderMs()` because the raw-DEX
bridge proof refuses a `fill-array-data` payload in the static initializer. Patchlet 090 r61 binds
all of this: the 48 bridge-flow negatives were rebased after uniform line deltas in
`AutoBlockSync.java`, the generated-D8 matrices stay at 328, 41, 13 and 96, the update-flow semantic
SHA-256 is rebound to `97b8947b803ef4dcdecefd315507bc1e5f9c27f89ab402639ab2646b46bde9f2`, and the
required class descriptor list drops the dialog, 53 to 52.

The r64 `SignedReview`, the 2026-09-06 no-dialog and list-refresh human promotion checkpoint, and
the 2026-09-06 revision 61 default `Release` publication recorded below were the review,
promotion, and publication records for the 010 r5, 020 r23, 050 r17, 060 r14, 070 r10, 085 r2, and
090 r61 series; that publication,
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-c.apk`, SHA-256
`da17a14814b73ca4e94c02fe9f8e7382a0747a07682a84002b6aa086e90ad4fb`, is superseded because it reads
the whole-file legacy `blocklist.json`, which the backend keeps fitted under 512 KiB until every
old install is replaced, so it still syncs but only the trimmed ranked slice of the list.

The client now reads the backend's chunked v3 index. Patchlet 020 r24 compiles three fixed v3
bases, GitHub raw, jsDelivr and the AWS relay, consulted in that order; the signed root is
`<base>blocklist/v3/manifest.json` and objects are `<base>blocklist/v3/objects/<name>`, where the
name must be exactly 64 lowercase hex characters followed by `.json` or `.ndjson.gz` and is
validated before any URL text is formed. Every object's SHA-256 is proven against its signed name
before it is parsed; only chunks whose signed name changed are downloaded; each fetched chunk is
stream-parsed row by row with a strict `JsonReader` into a staging table; and one transaction
replaces the affected hash buckets, measuring each replaced bucket's exact incoming-id set
difference before that bucket's rows are removed. `BlocklistStore` is SQLite schema v3: an `h32`
bucket column and index, a UNIQUE normalized-username index, the `blocklist_chunks`,
`blocklist_groups` and `blocklist_staging` tables, and `bucket_bits` in the metadata; the reviewed
v2-to-v3 migration retains the generation, both timestamps and both counts, and leaves the two
renamed v2 tables behind empty. The compiled caps are 524,288 characters per root, 65,536 bytes per
group table, 262,144 gzip bytes, 4,194,304 inflated bytes and 8,192 rows per chunk, 2,000,000 rows
per index (the constant `MAX_INDEX_ROWS`), 16 bucket bits and 8 group bits. Handle-only rows are
counted toward the signed total but never indexed, so `Records:` shows installed threads id rows.
The two new classes `threadsmod.autoblock.ObjectFetcher` and `threadsmod.autoblock.ChunkInstaller`
bring the required class descriptor list to 54 and the targeted-JADX class list to 40. Patchlet
090 r62 binds all of this against the host fixture tree
`patchlets/assets/tests/fixtures/blocklist-v3-2026-09-06` (root, threads group table and 16
chunks; 1,607 id rows and 26 handle rows; harness line
`PASS passive-fixture-v3 k=4 chunks=16 idRows=1607 handleRows=26 unique=1607`), replacing the
legacy `blocklist-signed-2026-08-30.json` fixture and its resolution key; the 48 bridge-flow
negatives were rebased after a uniform `.line` delta of 41, the generated-D8 matrices stay at 328,
41, 13 and 96, and the update-flow semantic SHA-256 is unchanged at
`97b8947b803ef4dcdecefd315507bc1e5f9c27f89ab402639ab2646b46bde9f2`. The `AGENTS.md` rules on list
reads, bounds, replacement, username uniqueness and metadata were revised the same day.

The r65 `SignedReview`, the 2026-09-06 chunked v3 client human promotion checkpoint, and the
2026-09-06 revision 62 default `Release` publication recorded immediately below are the current
review, promotion, and publication records; the promoted and published series is now 010 r5,
020 r24, 050 r17, 060 r14, 070 r10, 085 r2, and 090 r62, and the current artifact is
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-d.apk`, SHA-256
`e6ec4d70dacfa094659e31e09f2a890c537ba72b574767d62337a6a929c672a4`. It carries the same package
and version code as the `-c` build, so it updates that install in place, and the reviewed v2-to-v3
migration is the path an existing schema-v2 store takes on its first open. No ping, login, v3 root
fetch, chunk download, migration, or other device runtime behaviour has been exercised for the
published bytes.

## Patchlet 090 revision 62 successful r65 SignedReview

The fresh pristine replay at
`work/patchlet-444-r65-signed-review-20260906-a`
completed with `status: passed` in `SignedReview` mode at
`2026-09-06T18:44:17.0961996+07:00`. It produced one signed, work-local
review candidate at
`work/patchlet-444-r65-signed-review-20260906-a/release/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
135,150,120 bytes, SHA-256
`4a2af379085f3c8b55676067c876e8b82143f267cf198c12f0f18fb9780dd1b2`.
The build report deliberately records `reviewOnly: true`,
`releaseEligible: false`, `published: null`, and
`publicationRequested: null`; no matching candidate exists under `dist/`.
The review was bound to the review-time resolution file SHA-256
`09935bc711e078124b7a45051610bcf02e32caa1e53fd6edbb99a684c5fac676`
and to frozen canonical `patchlets/**` tree SHA-256
`5889b35ff05f66f5cf18d5e99b58a842e61bbbe3f624902cbda269d4fb4590f0`.

The reviewed series is 010 r5, 020 r24, 050 r17, 060 r14, 070 r10, 085 r2,
and 090 r62; only 020 and 090 moved from the revision 61 series published
earlier on 2026-09-06 (010 r5, 020 r23, 050 r17, 060 r14, 070 r10, 085 r2,
and 090 r61). One revision moves the Android client from the whole-file
signed `blocklist.json` to the backend's chunked v3 index, so that the
client scales to millions of records and downloads only what changed.

First, the read path. Patchlet 020 r24 compiles three fixed v3 bases,
GitHub raw, jsDelivr and the AWS relay, consulted in that order. The signed
root is `<base>blocklist/v3/manifest.json` and objects are
`<base>blocklist/v3/objects/<name>`, where `CloneBlockerEndpoints.objectUrl`
admits only 64 lowercase hex characters followed by `.json` or `.ndjson.gz`
before any URL text is formed. `parseAndVerify` keeps the envelope, Ed25519,
`updatedAt`, +24 h clock, 30-day stale and rollback checks verbatim and then
validates the root type-strictly (`v` 3, `hash` `sha256-hi32`,
`maxChunkRows` and `maxChunkBytes` within the compiled caps, and
`platforms.threads` with `k`, `g`, `total` and exactly `1 << g` 64-hex group
names); the whole-file target loop, `MAX_TARGETS` and the `idNames` /
`profiles` fallbacks are gone. `ObjectFetcher` GETs one object with the same
connection discipline as the root fetch plus a mandatory
`Accept-Encoding: identity`, bounds it by the caller's cap and the signed
byte count, proves `SHA-256(bytes)` against the signed name before
returning, and retries a mirror once only after an `IOException`; objects
are fetched from the winning root's mirror first and then from the other
allowlisted bases in declared order. The retired whole-file `blocklist.json`
URLs are not compiled.

Second, the install path. `ChunkInstaller` reuses committed group tables
whose signed name is unchanged, parses each fetched group table strictly
with `JsonReader`, marks every bucket whose chunk name differs (or every
bucket when the bucket bits changed or no valid generation exists), and
stages each replaced chunk one at a time through a capped `GZIPInputStream`
and a strict per-line `JsonReader` into `blocklist_staging`. A chunk is
rejected whole, and the install with it, for a non-object line, a malformed
`i`, an id row without a valid `u`, a duplicate id or conflicting normalized
username, a row outside the chunk's bucket, or a row or byte count that
differs from the signed group entry; a handle-only row (`u` without `i`) is
bucket-checked and counted toward the signed total but never indexed, so
`Records:` reports installed threads id rows. `BlocklistStore` is SQLite
schema v3: `blocklist_targets` gains an `h32` column and index, the
normalized-username index becomes UNIQUE, `blocklist_metadata` widens its
counts to 16,777,216 and records `bucket_bits`, and `blocklist_chunks`,
`blocklist_groups` and `blocklist_staging` are new.
`replaceVerified(Context, InstallPlan, ...)` measures each replaced bucket's
exact incoming-id set difference against the still-complete previous
generation before that bucket's range is deleted, copies the staged chunk in
with `INSERT ... SELECT`, records the chunk and group names, and commits the
next generation with `target_count` equal to the sum of installed id rows.
The reviewed v2-to-v3 migration renames the v2 tables, creates the v3
schema, copies every retained row with its recomputed hash, moves the
metadata row with `bucket_bits` 0 and the generation, both timestamps and
both counts preserved, and leaves `blocklist_targets_v2` and
`blocklist_metadata_v2` behind empty; a v1 store chains through the existing
v1-to-v2 stage first.

Third, the bounds and status. The compiled caps are `MAX_ROOT_BYTES` 524,288
(characters after decoding, inside the 4,194,304-byte response bound),
`MAX_GROUP_BYTES` 65,536, `MAX_CHUNK_GZ_BYTES` 262,144,
`MAX_CHUNK_INFLATED_BYTES` 4,194,304, `MAX_CHUNK_ROWS` 8,192,
`MAX_INDEX_ROWS` 2,000,000, `MAX_BUCKET_BITS` 16 and `MAX_GROUP_BITS` 8; the
row constant is named `MAX_INDEX_ROWS` because the host gate forbids the
retired `MAX_TOTAL_` prefix. Object-phase failures reach the retained-failure
status through the same closed per-mirror token grammar as the root: a
transport or HTTP failure names the mirror that failed, a hash mismatch is
`signature`, a malformed group or chunk is `schema` attributed to the mirror
that served it, and the other slots read `internal`.

Patchlet 090 r62 binds all of this. `Test-HostPatchletAssets.ps1` compiles
and runs the harnesses against the fixture tree
`patchlets/assets/tests/fixtures/blocklist-v3-2026-09-06` (root, threads
group table and its 16 chunks captured from GitHub raw on 2026-09-06), bound
as `assets.signedBlocklistV3FixtureTreeSha256`
`aa09d3ed9f1c03419ad434929f7130c0860ae4e702abf6fa092c3b04e50f0835`; the
legacy `blocklist-signed-2026-08-30.json` fixture and its resolution key are
removed. The fixture harness printed
`PASS passive-fixture-v3 k=4 chunks=16 idRows=1607 handleRows=26 unique=1607`
against the fixture root `manifest.json`, SHA-256
`35f2d2bdc93e21ba75b08c8aae6310b90fb2f50a1431d92f92fc4d2893436477`, with
`liveNetworkUsed: false`, and the host-assets report's `passiveBlocking`
block records `schemaVersion` 3, the `sha256-hi32` bucket function, the
`blocklist_targets_username_idx-unique` username index, the
`blocklist_targets_h32_idx` bucket index, the three chunk tables, and
`migratedV2NewCount: preserved`. The resolution's `requiredReadEndpoints`
are the three v3 manifest URLs, its required class descriptor list grows
from 52 to 54 with `Lthreadsmod/autoblock/ObjectFetcher;` and
`Lthreadsmod/autoblock/ChunkInstaller;` owned by 020, and the targeted-JADX
class list grows from 38 to 40; the catalog's `databaseSchemas` list for the
store carries fourteen v3 entries, including the two retired empty v2
tables. The 48 bridge-flow negatives were rebased onto the regenerated
carrier after a uniform `.line` delta of 41 and
`dexBridgeFlowFixtureTreeSha256` re-pinned to
`1bab4586f4d7466dbdada626b85328fbc4cb8d238dd2fad623c88dcf0ce5a68c`; the
inspector sources are unchanged, the generated-D8 matrices stay at 328, 41,
13 and 96, and the update-flow semantic SHA-256 is unchanged at
`97b8947b803ef4dcdecefd315507bc1e5f9c27f89ab402639ab2646b46bde9f2` because
patchlet 085 did not move. The `AGENTS.md` rules on list reads, bounds,
replacement, username uniqueness and metadata were revised the same day.

The frozen review records are:

| Record | SHA-256 |
|---|---|
| `work/patchlet-444-r65-signed-review-20260906-a/build-report.json` | `84fc477462b8ca603090748534b43d99c8be6fe5fd1f1e447873b6bbf40f92ed` |
| `work/patchlet-444-r65-signed-review-20260906-a/release-check.json` | `90a3a15f5002095adc868faf9f071f6491fe6557b52c212201b2025d1b6e4cb7` |
| `work/patchlet-444-r65-signed-review-20260906-a/activity-ui-review.json` | `d49de81908b2bb951ca1eed3d13382689375a83080b181a2ff65d4127bb0582e` |
| `work/patchlet-444-r65-signed-review-20260906-a/idempotency-check.json` | `537040e9987d8a22738e9c5296258f1b3aed68158248bcfb6bafb9cb52e8a8b3` |
| `work/patchlet-444-r65-signed-review-20260906-a/catalog-check.json` | `8b5aa0c4170d2d0dfc6be4cbaa5023a231421930a35d85bc9ff5efa0e43397df` |
| `work/patchlet-444-r65-signed-review-20260906-a/resolution-check.json` | `aeb67ce72caf94b92b589ae03c4bfa99d79d6e4505e8fd8670805823084a7558` |

The source freeze matched the exact three-member split set at SHA-256
`5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`
and its deterministic universal source at SHA-256
`156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`.
The pre-report lock (`2026-09-06T18:42:27.8194303+07:00`) observed zero
tree-monitor events and all 41 canonical assets remained bound. Reapplying
the complete series was a content-identical no-op across 124,329 files,
8,163 directories, and 132,492 entries, eight files and eight entries more
than the revision 61 replay; the decoded tree SHA-256 remained
`61de5750321c917ccb395e40430c6667e84b2e948cecdb742585fd03a038f858`
before and after, with no exclusions.

The final archive gate passed for clone package `app.tree55.threads`,
version code `511407878`, version name
`444.0.0.45.85-threadsmod.1`, minimum SDK 28, and target SDK 36. The archive
has 13 root DEX files and 14 DEX files in total. Primary DEX contains 61,821
method references, 75 more than the revision 61 candidate and below the
resolution-bound 65,535 ceiling. Archive shape, 16 KiB alignment, and
signing checks passed with exactly one signer, v2 only, certificate SHA-256
`317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
All 69 source native libraries were preserved; the sole reviewed addition is
`lib/arm64-v8a/libhev-socks5-tunnel.so`, SHA-256
`3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`,
whose three AArch64 LOAD segments each have 16 KiB alignment and whose JNI
contract passed.

Generated-D8 positive and bypass-negative suites passed their exact frozen
counts: Block bridge 328, report permalink 41, proxy bootstrap 13, and
updater 96, with no fixture whose `observedPass` differed from its
`expectedPass`. Direct inspection of the signed candidate also passed the
raw-Dex Block bridge, report-permalink, and updater contracts in
`classes.dex` and the proxy bootstrap contract in `classes6.dex`. The signed
candidate's update-flow inspection and the updater positive fixture both
bound the update-flow semantic SHA-256
`97b8947b803ef4dcdecefd315507bc1e5f9c27f89ab402639ab2646b46bde9f2`, which
the exact resolution still pins as `expectedSemanticSha256`. Targeted JADX
1.5.6 recovery passed all 40 reviewed classes; the two new classes hashed to
`0e63d71e2c1daa3a47555d6b88feda430598e857bb64fdf4d180cf856a095ca6`
(`threadsmod.autoblock.ObjectFetcher`) and
`624bbca4c1d76e7f8fb413676fd54c11c80ac66a435d329f052f8d2533a7e226`
(`threadsmod.autoblock.ChunkInstaller`), and the rewritten store to
`9276d03f49f8ba5e7dd94389514ed6ab49db1767f9ac99b116b3a8e426478f7c`
(`threadsmod.autoblock.BlocklistStore`). Raw DEX remains authoritative over
readable JADX output.

The candidate's DEX was also checked directly for the new and retired text.
In the candidate's `classes.dex`, SHA-256
`a91c942c51de51e8ff754c2a4c9d8c3f22600531c459942eed03430e0857c9b8`, the
substring `blocklist/v3/manifest.json` occurs six times (three URLs and
three paths) and `blocklist/v3/objects/` six times; the descriptors
`Lthreadsmod/autoblock/ChunkInstaller;` and
`Lthreadsmod/autoblock/ObjectFetcher;`, the DDL
`CREATE UNIQUE INDEX blocklist_targets_username_idx` and the rejection
literal `signed root is not v3` are present; and the retired whole-file URL
tails `published/blocklist.json`, `@published/blocklist.json` and
`amazonaws.com/blocklist.json`, the removed `Threads Mod Auto Block`, the
forbidden `tree55.com` and the retired `MAX_TOTAL_` prefix are absent. That
is a substring check of the signed candidate's own bytes, not of canonical
Java, generated Smali, or JADX output; it establishes which strings the
candidate carries and is not itself a fetch, parse, or rendering result.

The isolated no-permission Activity probe used an APK whose primary DEX is
byte-identical to the candidate primary DEX, SHA-256
`a91c942c51de51e8ff754c2a4c9d8c3f22600531c459942eed03430e0857c9b8`.
On the API 37 `sdk_gphone16k_x86_64` emulator it cold-launched and visibly
rendered `CloneBlockerActivity`, `CloneBlockerSettingsActivity`, and
`ProxySettingsActivity`; all three resumed with an empty crash log. The probe
requested no permissions and recorded
`networkOrAccountActionAttempted: false`, and the build report records
`runtimeValidation: isolated-activity-ui-probe-passed`.

The matcher contract is unchanged from r64. `CloneBlockerSettingsActivity`
required the exact viewport-intersecting node text `Sync now`, and the
recorded `visibleExactText` for that Activity is `Settings`, `Activity`,
`Current status`, and `Sync now`. The five dynamic fields `List fetch:`,
`Records:`, `New this refresh:`, `Database index:`, and `Inline control:`
matched as one contiguous ordered multiline sequence, and the contract still
carried its one positive and nine bypass fixtures with exact visible node
text, ordered multiline status, non-zero bounds, viewport intersection, and
non-empty status values all required. Separately, on the recorded dumps: the
`CloneBlockerSettingsActivity` dump carries the `Passive blocking` card with
its `Always on.` description and the line
`Enabled; waiting for a signed-in foreground session.`; both status dumps
read `List fetch: Waiting for first verified refresh`,
`Records: Unavailable`, `New this refresh: Unavailable` and
`Database index: Missing` on that fresh, account-less, network-less install;
and none of the three dumps contains `Threads Mod Auto Block` or
`Disabled until you explicitly enable it`. Those are observations on the
recorded dumps, not gate requirements. The probe performs no mirror fetch
and its store was created fresh, so the v3 root fetch, object-name
validation, object hash proof, chunk staging, per-bucket replacement, and
the v2-to-v3 migration have not run on any device. Matching `Sync now`
establishes only that the rendered control is labelled `Sync now`; it does
not exercise the sync action, a list refresh, or any blocking work.

This was successful signed-review evidence, not publication or promotion. At
that checkpoint the exact resolution remained `review-required` at
resolution-file SHA-256
`09935bc711e078124b7a45051610bcf02e32caa1e53fd6edbb99a684c5fac676`
with `release.updateSignedDexReviewRequired: true`; the promotion below is
the separate reviewed state transition. The isolated probe does not
establish full candidate installation or startup, login, live post/reply
scrolling, native Block success, report or activation-ping delivery, mirror
reachability, a v3 refresh against the live index, SOCKS
endpoint/authentication or packet coverage, update download/install, or
account-changing behavior. A fresh default `Release` replay remained
mandatory before any APK could be published to `dist/`.

## 2026-09-06 chunked v3 client human promotion checkpoint

The owner authorized this work on 2026-09-06: `refactor, upgrade app and
backend, mirror, etc to handle million of records, use better format and
chunking or something`, the instruction under which the backend's chunked
v3 index recorded in the revision 61 publication section below was also
built. The promotion applies to the exact r65 `SignedReview` candidate
SHA-256 `4a2af379085f3c8b55676067c876e8b82143f267cf198c12f0f18fb9780dd1b2`
recorded above.

Returning this resolution to `review-required` for revision 62, at
`2026-09-06T17:59:07+07:00`, had again required re-arming
`release.updateSignedDexReviewRequired` to `true`:
`patchlets/schemas/resolution.schema.json` couples the two fields for any
resolution whose `patchlets` list contains `085-in-app-update`, requiring
`updateSignedDexReviewRequired: true` while `status` is `review-required` and
`false` while `status` is `verified-current`. Re-arming that flag re-blocked
release until the updater contracts were proved again from raw signed DEX,
and the r65 `SignedReview` above is that proof: its signed-candidate
update-flow inspection and its 96 generated-D8 updater fixtures both bound
the unchanged semantic SHA-256
`97b8947b803ef4dcdecefd315507bc1e5f9c27f89ab402639ab2646b46bde9f2`.

The exact resolution was therefore promoted at
`2026-09-06T18:45:02+07:00` by changing only `status` to `verified-current`,
`resolvedAt` to that timestamp, and `release.updateSignedDexReviewRequired`
to `false`. The promoted resolution file SHA-256 is
`9b96cce9134d207264ed42b9ecd4e92d10f3c630c58d9908cff755b00eeb9371`; the
review-time file it replaced was
`09935bc711e078124b7a45051610bcf02e32caa1e53fd6edbb99a684c5fac676`.
No runtime Java, rendered Smali, rewrite, semantic proof, patchlet asset, or
review candidate was altered by promotion.

Promotion itself is not a release or publication result. A fresh default
`Release` replay from the pristine exact split set must independently
rebuild, sign, rerun the signed-DEX/archive release gates, and
transactionally publish a new candidate before a final APK can be claimed.
The approved exact-primary-DEX Activity probe remains the separate r65
`SignedReview` promotion prerequisite recorded above; default `Release` does
not rerun that probe.

## 2026-09-06 revision 62 default Release publication

This is a **post-publication documentary append**. The successful pipeline
froze its canonical inputs before this evidence note and the other release
documents were updated. The recorded frozen inputs remain authoritative; the
current documentation-containing tree must not be substituted for them.

Fresh run
`work/patchlet-444-r65-release-20260906-a`
replayed the complete series from split-set SHA-256
`5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`
and deterministic universal source SHA-256
`156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`
against promoted resolution SHA-256
`9b96cce9134d207264ed42b9ecd4e92d10f3c630c58d9908cff755b00eeb9371`.
Its frozen canonical `patchlets/**` tree SHA-256 is
`0665a733a29b60f195c4f9f53f28462fd938d4cefded6a535d623d4556c83cfc`;
the r65 `SignedReview` above had frozen
`5889b35ff05f66f5cf18d5e99b58a842e61bbbe3f624902cbda269d4fb4590f0`
against the review-time resolution. The run completed at
`2026-09-06T19:28:00.0944447+07:00`.

The default `Release` transaction published
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-d.apk`,
135,150,120 bytes, SHA-256
`e6ec4d70dacfa094659e31e09f2a890c537ba72b574767d62337a6a929c672a4`.
The run-local signed candidate, published file, build binding, and release
report all contain that exact digest. No `.publishing-*.tmp` residue remains.
The immutable release records are:

| Record | SHA-256 |
|---|---|
| `work/patchlet-444-r65-release-20260906-a/build-report.json` | `3f22ee05cbd61cf8d76c03b0653289c5b655f2a07afe16cb7bb81aeac6e92c13` |
| `work/patchlet-444-r65-release-20260906-a/release-check.json` | `0f3fab6208190df119c1290a904fe1d6107b29e006c5a955c6145e1fb7bdf54f` |
| `work/patchlet-444-r65-release-20260906-a/idempotency-check.json` | `5c49e7af678f2b352a832b4aa6a15f26de5ca5269e261dfce83d7ae9964582a3` |
| `work/patchlet-444-r65-release-20260906-a/catalog-check.json` | `d16bfde599c1e3e7f54496eb50bd210f0b33ecbf63a2271742e41a9636703975` |
| `work/patchlet-444-r65-release-20260906-a/resolution-check.json` | `5e0df81015116c66e9cc8fdfaaac82ba6da0251bbe978342caa92261b598c5c6` |

Both reports record `status: passed`, `validationMode: Release`,
`reviewOnly: false`, `releaseEligible: true`, and `artifactProduced: true`.
The pre-report (`2026-09-06T19:26:13.1548380+07:00`), pre-publish
(`2026-09-06T19:28:02.4786371+07:00`), and post-publish
(`2026-09-06T19:29:50.8562475+07:00`) source/resolution/canonical-asset
freeze checks all matched with zero tree-monitor events and all 41 canonical
assets bound. Complete-series reapplication was content-identical with no
exclusions across 124,329 files, 8,163 directories, and 132,492 entries;
decoded-tree SHA-256 remained
`d6e9c44afb84fc053c29a6b0d652fbce0edc1fd67ecaa45c97b83eb434d20057`
before and after.

The published clone is package `app.tree55.threads` with launcher label
`Threads 55`, version code `511407878`, version name
`444.0.0.45.85-threadsmod.1`, minimum SDK 28, target SDK 36, arm64-v8a, and
mod build 1. Archive and 16 KiB alignment checks passed. It contains 13 root
DEX files and 14 DEX files in total; primary DEX has 61,821 method references
under the 65,535 ceiling. Signing is v2 only with exactly one signer whose
certificate SHA-256 is
`317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
All 69 source native libraries were preserved and the sole reviewed addition
remains `lib/arm64-v8a/libhev-socks5-tunnel.so`, SHA-256
`3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`,
with three 16 KiB AArch64 LOAD segments and passing JNI evidence.

Generated-D8 fixture matrices passed at their exact frozen counts: Block
bridge 328/328, report permalink 41/41, proxy bootstrap 13/13, and updater
96/96, the Block bridge matrix including the 48 rebased negatives at
`observedPass: false` and no fixture whose observed result differed from its
expectation. Direct inspection of the signed production DEX passed the Block
bridge, permalink, and updater contracts in `classes.dex` and the
proxy-bootstrap contract in `classes6.dex`; the signed update-flow
inspection again bound semantic SHA-256
`97b8947b803ef4dcdecefd315507bc1e5f9c27f89ab402639ab2646b46bde9f2`.
Targeted JADX 1.5.6 recovered and hash-bound all 40 reviewed classes;
`threadsmod.autoblock.ObjectFetcher`, `threadsmod.autoblock.ChunkInstaller`
and `threadsmod.autoblock.BlocklistStore` recovered to the same SHA-256
values as in the r65 `SignedReview` above. The release check's required DEX
strings include the three v3 manifest URLs and both new descriptors, and
`tree55.com` remains among its forbidden strings; the run's host-assets
report again printed
`PASS passive-fixture-v3 k=4 chunks=16 idRows=1607 handleRows=26 unique=1607`
against the same fixture root with `liveNetworkUsed: false`.

The published bytes were also checked directly for the new and retired text.
In the published APK's `classes.dex` the substring
`blocklist/v3/manifest.json` occurs six times and `blocklist/v3/objects/`
six times; `Lthreadsmod/autoblock/ChunkInstaller;`,
`Lthreadsmod/autoblock/ObjectFetcher;`,
`CREATE UNIQUE INDEX blocklist_targets_username_idx` and
`signed root is not v3` are present; and `published/blocklist.json`,
`@published/blocklist.json`, `amazonaws.com/blocklist.json`,
`Threads Mod Auto Block`, `tree55.com` and `MAX_TOTAL_` are absent, the same
results as the candidate check above. That `classes.dex` hashes to SHA-256
`a91c942c51de51e8ff754c2a4c9d8c3f22600531c459942eed03430e0857c9b8`, the same
primary DEX as the r65 `SignedReview` candidate and its Activity probe. That
is a substring check and a hash of the published file itself, SHA-256
`e6ec4d70dacfa094659e31e09f2a890c537ba72b574767d62337a6a929c672a4`, not of
the review candidate, a decoded tree, or canonical source; it establishes
which strings the published DEX carries and is not a fetch, parse,
rendering, or device result.

Default `Release` correctly records `runtimeValidation: not-run` and has no
`activityUiReview`: the r65 `SignedReview` exact-primary-DEX Activity probe
above is the separate promotion prerequisite and was not rerun. The
published bytes have not been installed or run on any device. The only
device evidence for this revision is the r65 `SignedReview` candidate,
SHA-256 `4a2af379085f3c8b55676067c876e8b82143f267cf198c12f0f18fb9780dd1b2`
and not this artifact, which passed the isolated no-permission Activity UI
probe on an emulator. No login, feed scrolling, Block, report,
activation-ping delivery, list refresh, update, or VPN behaviour has been
exercised for either; no v3 root fetch, object download, hash verification,
chunk staging, per-bucket replacement, or v2-to-v3 migration has run on any
device, and the closed per-mirror failure-class status for the object phase
is static proof only. Neither the static release gates nor the review probe
establish full-app installation/startup, login, live post/reply scrolling,
native Block success, report or mirror delivery, SOCKS
endpoint/authentication or packet coverage, update download/install, or any
real account-changing behavior.

This artifact supersedes the 2026-09-06 revision 61 build
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-c.apk`,
SHA-256
`da17a14814b73ca4e94c02fe9f8e7382a0747a07682a84002b6aa086e90ad4fb`, and
that build should be replaced by this one. It reads the whole-file legacy
`blocklist.json` through its 4 MiB bound, not the chunked v3 index; the
backend keeps that legacy file published and fitted under 512 KiB by
trimming the oldest ranked `targets` entries until every old install is
replaced, so a `-c` install still syncs, but only the trimmed ranked slice
of the list rather than the full index. Because the application ID and
version code `511407878` are unchanged, this artifact updates a `da17a148`
install in place rather than sitting beside it, and on that install the
existing schema-v2 SQLite store takes the reviewed v2-to-v3 migration on its
first open, retaining its generation, timestamps and counts; that migration
has not been exercised on a device. The same in-place update holds for the
2026-09-06 revision 60 build
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-b.apk`,
SHA-256
`abcfb52fc23b1d819488789566c62189b5297183bf5e39652f17f132272d3bf8`
(superseded for its first-run dialog and its 512 KiB response cap), the
2026-09-05 `threads55` build, SHA-256
`ca53165cc8f511e17b5967b49aae0c4b0fb0629da7da6dd0c46718250f1b3e73`, and
the 2026-09-05 `tree55` build, SHA-256
`7a8850ef96fe1f973358b1b07989090e3f94ec9ce0a30addb38e304ea8d3a1e6`; those
older artifacts remain historical facts described by their own sections
below. It still installs side by side with any `com.threadsmod.barcelona`
clone, including the r53 artifact, SHA-256
`85124df5d5995af7ca3efd80b1a16f14b0e8fd380fc61e1bfe303b4037708ec4`.

`dist/` now holds `SHA256SUMS.txt`, the superseded `threads55-mod1-b` and
`threads55-mod1-c` files, and this `threads55-mod1-d` file.
`dist/SHA256SUMS.txt` lists all six 444 artifacts, this one as its last
line, as it still lists the ten 415 artifacts and the three older 444
artifacts removed from `dist/` earlier; those three lines verify only
against the run-local copies named in the revision 61 section below. The
in-app updater cannot bridge package names and `adb install -r` cannot
update across them. No update metadata was published by this APK
transaction; the release check records `metadataDeployed: false` and
`runtimeInstallTested: false` for the in-app update channel.

For activation statistics, the backend route `POST /v1/installs` remains
deployed at the origin. That backend state is outside this APK transaction
and is unchanged by it; no ping from the published bytes has been sent or
observed.

The block-list backend is likewise outside this APK transaction and was not
changed by it. The chunked v3 index recorded in the revision 61 section
below has been live on the origin, the AWS relay, GitHub raw and jsDelivr
since `2026-09-06T07:14:05.577Z`, and this artifact is the first published
Android client that reads it. The legacy whole-file `blocklist.json` is
still published and still fitted under 524,288 bytes for the superseded
builds. The Chrome extension still reads the legacy file; its v3 port is the
next phase.

## Patchlet 090 revision 61 successful r64 SignedReview

The fresh pristine replay at
`work/patchlet-444-r64-signed-review-20260906-a`
completed with `status: passed` in `SignedReview` mode at
`2026-09-06T15:13:09.2192012+07:00`. It produced one signed, work-local
review candidate at
`work/patchlet-444-r64-signed-review-20260906-a/release/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
135,133,736 bytes, SHA-256
`888130a25938b9c7fe06ecb0e0e62056839e322f7498b317c5f0a20ce20861a5`.
The build report deliberately records `reviewOnly: true`,
`releaseEligible: false`, `published: null`, and
`publicationRequested: null`; no matching candidate exists under `dist/`.
The review was bound to the review-time resolution file SHA-256
`65146501defd019fa813666b87fd1d9d4e1927682423909978aa08cf657a5089`
and to frozen canonical `patchlets/**` tree SHA-256
`d93abba4c6395b872514385b9a038199a32edb8b999bdf75a7c7d97f4ca2f944`.

The reviewed series is 010 r5, 020 r23, 050 r17, 060 r14, 070 r10, 085 r2,
and 090 r61; only 020, 085, and 090 moved from the revision 60 series
published earlier on 2026-09-06 (010 r5, 020 r22, 050 r17, 060 r14, 070 r10,
085 r1, and 090 r60). One revision folds three changes.

First, the first-run `Threads Mod Auto Block` dialog is removed. Patchlet 020
r23 deletes `com.threadsmod.DemoDialog` from the canonical tree and from its
class prefixes, class descriptors and compiled sources. `ModBootstrap.onResume`
still hands every resume to `UpdateController.onResume`, and the no-update
continuation it passes is now an empty, non-capturing `Runnable` that shows no
UI. Patchlet 085 r2 changes only that continuation contract: `proveBootstrap`
in `DexUpdateFlowInspector.java` no longer proves a `DemoDialog.showOnce`
caller; it proves that the continuation's constructor takes no arguments, that
its `run()` body is exactly one `return-void` (`bootstrap_fallback_not_empty`),
and that the `Lcom/threadsmod/DemoDialog;` descriptor is absent from the
primary DEX (`bootstrap_demo_dialog_present`), while the arbitration-first,
dominance and three-caller checks are unchanged. The two retired dialog
negatives were replaced one for one by `bootstrap-continuation-not-empty`,
`bootstrap-continuation-captures-activity` and
`bootstrap-demo-dialog-class-reintroduced`, each recorded with
`expectedPass: false` and `observedPass: false`, so the updater matrix stays
at 96 fixtures with 95 negatives. The resolution's targeted-JADX entry for
`threadsmod.bootstrap.ModBootstrap` drops the dialog call from its required
and ordered strings, still requires `AutoBlockSync.onResume(`,
`UpdateController.onResume(`, `UpdateController.onPause(` and
`AutoBlockSync.onPause(`, and forbids the `DemoDialog` token; the signed
recovery of that class hashed to
`532958e9380d693b9c8f6e17654849b4ad55ec7c369ba903b8fe60c3d5aee275`. The
resolution's required class descriptor list drops the dialog, 53 to 52, and
its `expectedSemanticSha256` for the update flow is rebound from
`d0e8d1ab489ab6241779cb18c21621f3ebd7f17310b36a18d49d6081d7d4d1ed` to
`97b8947b803ef4dcdecefd315507bc1e5f9c27f89ab402639ab2646b46bde9f2`.
Disclosure of always-on passive blocking and of the activation ping lives in
the Settings screen, in the Passive blocking card and the Reports card, and
the two `AGENTS.md` sentences that named a first-run notice now point there.

Second, list refresh is repaired for the published list size.
`AutoBlockSync.MAX_RESPONSE_BYTES` rose from 512 KiB to 4 MiB (4,194,304
bytes) because the signed list had grown to 545,168-548,306 bytes on all
three mirrors on 2026-09-06, so every earlier build failed `too_large` on
every mirror and showed `List fetch: Failed — no valid index` and
`Records: Unavailable`.

Third, recovery after a failed attempt is immediate and bounded. The next
attempt follows after 15 s, 30 s, 60 s, 120 s and 300 s, at most five ladder
steps per foreground session and the ordinary 600,000 ms cadence thereafter;
the ladder resets on a successful attempt and on each
background-to-foreground transition, and is installed through a
three-argument `advanceListRefreshDeadline` overload whose interval can never
exceed `FETCH_INTERVAL_MS`, while a successful attempt still installs the
exact 600,000 ms deadline. Once per foreground session, while no valid index
exists and no sooner than 15 s after the last admitted start, the first
ordinary request starts ahead of a pending deadline. Within one attempt each
mirror is retried exactly once, immediately, and only after an `IOException`
(timeout, DNS/connect, TLS, or a stream broken mid-body), never after an
HTTP-status, size, cookie, signature, schema, clock, stale, rollback or
target-cap result. The retained-failure status names one closed failure class
per mirror in declared order from the set `too_large`, `http_<status>` (or
`http_other`), `timeout`, `unreachable`, `tls`, `io`, `signature`, `schema`,
`clock`, `stale`, `rollback`, `target_cap`, `cookie_refused` and `internal`,
chosen by exception type and never from a message, URL, header or body, for
example `mirror 1 too_large`. The ladder array is built element by element in
the helper `listRefreshFailureLadderMs()` because the raw-DEX bridge proof
refuses a `fill-array-data` payload in the static initializer. The 48
bridge-flow negatives were rebased after uniform line deltas in
`AutoBlockSync.java`; no gate expectation moved and the generated-D8 matrices
stay at 328, 41, 13 and 96.

The frozen review records are:

| Record | SHA-256 |
|---|---|
| `work/patchlet-444-r64-signed-review-20260906-a/build-report.json` | `fae2d43f044a8f592082970dba875b13c4cb2f04812548ffec67c8eab545762b` |
| `work/patchlet-444-r64-signed-review-20260906-a/release-check.json` | `f05434e3e671a4292b123cc629e51566986b620af00f1ef8c640eefa2053bfbb` |
| `work/patchlet-444-r64-signed-review-20260906-a/activity-ui-review.json` | `6a39465b817e96056bfc077f1d2fbd9e28a2f3e7175bdfb979a6c4a3ec17c224` |
| `work/patchlet-444-r64-signed-review-20260906-a/idempotency-check.json` | `1bc882ae7f0a737568903c548c2bbcbb783e39b5c7d5fb63bf41de76fe17005b` |
| `work/patchlet-444-r64-signed-review-20260906-a/catalog-check.json` | `26688f042629ba9fb14f8c236a2d5a9c5fc6b0957b29335884440235d94b4cd0` |
| `work/patchlet-444-r64-signed-review-20260906-a/resolution-check.json` | `aaefc029012287427f271ccb7aca254874df75c4a453627fbee416a1651e0bbe` |

The source freeze matched the exact three-member split set at SHA-256
`5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`
and its deterministic universal source at SHA-256
`156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`.
The pre-report lock observed zero tree-monitor events and all 41 canonical
assets remained bound. Reapplying the complete series was a content-identical
no-op across 124,321 files, 8,163 directories, and 132,484 entries, two files
and two entries fewer than the revision 60 replay; the decoded tree SHA-256
remained
`f8e7ccac3b21ddf12ce7e57db215243197b2dc6377073389e03b70b96c0602ed`
before and after, with no exclusions.

The final archive gate passed for clone package `app.tree55.threads`,
version code `511407878`, version name
`444.0.0.45.85-threadsmod.1`, minimum SDK 28, and target SDK 36. The archive
has 13 root DEX files and 14 DEX files in total. Primary DEX contains 61,746
method references, below the resolution-bound 65,535 ceiling. Archive shape,
16 KiB alignment, and signing checks passed with exactly one signer, v2 only,
certificate SHA-256
`317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
All 69 source native libraries were preserved; the sole reviewed addition is
`lib/arm64-v8a/libhev-socks5-tunnel.so`, SHA-256
`3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`,
whose three AArch64 LOAD segments each have 16 KiB alignment and whose JNI
contract passed.

Generated-D8 positive and bypass-negative suites passed their exact frozen
counts: Block bridge 328, report permalink 41, proxy bootstrap 13, and updater
96. Direct inspection of the signed candidate also passed the raw-Dex Block
bridge, report-permalink, and updater contracts in `classes.dex` and the proxy
bootstrap contract in `classes6.dex`. The signed candidate's update-flow
inspection and the updater positive fixture both bound the update-flow semantic
SHA-256
`97b8947b803ef4dcdecefd315507bc1e5f9c27f89ab402639ab2646b46bde9f2`, which the
exact resolution now pins as `expectedSemanticSha256`. Targeted JADX 1.5.6
recovery passed all 38 reviewed classes; the deleted dialog was never one of
them. Raw DEX remains authoritative over readable JADX output.

The candidate's DEX was also checked directly for the removed and repaired
text. In the candidate's `classes.dex`, SHA-256
`74175bd78ead913a3243609ddaab4ef8304ab574fdfda5a2350a7c998157acf4`, the
strings `Threads Mod Auto Block`, `Lcom/threadsmod/DemoDialog;` and
`Disabled until you explicitly enable it` are absent, and the strings
`too_large` and `Enabled; waiting for a signed-in foreground session` are
present; `Passive blocking: always on`, which only the removed notice carried,
is absent as well. That is a substring check of the signed candidate's own
bytes, not of canonical Java, generated Smali, or JADX output; it establishes
which sentences the candidate carries and is not itself a rendering result.

The isolated no-permission Activity probe used an APK whose primary DEX is
byte-identical to the candidate primary DEX, SHA-256
`74175bd78ead913a3243609ddaab4ef8304ab574fdfda5a2350a7c998157acf4`.
On the API 37 `sdk_gphone16k_x86_64` emulator it cold-launched and visibly
rendered `CloneBlockerActivity`, `CloneBlockerSettingsActivity`, and
`ProxySettingsActivity`; all three resumed with an empty crash log. The probe
requested no permissions and recorded
`networkOrAccountActionAttempted: false`, and the build report records
`runtimeValidation: isolated-activity-ui-probe-passed`.

The matcher contract is unchanged from r61. `CloneBlockerSettingsActivity`
required the exact viewport-intersecting node text `Sync now`, and the
recorded `visibleExactText` for that Activity is `Settings`, `Activity`,
`Current status`, and `Sync now`. The five dynamic fields `List fetch:`,
`Records:`, `New this refresh:`, `Database index:`, and `Inline control:`
matched as one contiguous ordered multiline sequence, and the contract still
carried its one positive and nine bypass fixtures with exact visible node
text, ordered multiline status, non-zero bounds, viewport intersection, and
non-empty status values all required. Separately, on the recorded dumps: the
`CloneBlockerSettingsActivity` dump carries the `Passive blocking` card with
its `Always on.` description and the line
`Enabled; waiting for a signed-in foreground session.`; none of the three
dumps contains `Threads Mod Auto Block` or
`Disabled until you explicitly enable it`; and the recorded `List fetch:`
value on that fresh, account-less, network-less install is
`Waiting for first verified refresh`. Those are observations on the recorded
dumps, not gate requirements. The probe launches the mod Activities directly
and never runs the host resume hook, so it is not evidence about the removed
dialog path; the absence of the class from the DEX is that evidence. It
performs no mirror fetch, so the 4 MiB bound, the transport-only retry, the
failure ladder and the closed failure-class status have not run on any
device. Matching `Sync now` establishes only that the rendered control is
labelled `Sync now`; it does not exercise the sync action, a list refresh, or
any blocking work.

This was successful signed-review evidence, not publication or promotion. At
that checkpoint the exact resolution remained `review-required` at
resolution-file SHA-256
`65146501defd019fa813666b87fd1d9d4e1927682423909978aa08cf657a5089`
with `release.updateSignedDexReviewRequired: true`; the promotion below is the
separate reviewed state transition. The isolated probe does not establish full
candidate installation or startup, login, live post/reply scrolling, native
Block success, report or activation-ping delivery, mirror reachability, list
refresh against the published list size, SOCKS endpoint/authentication or
packet coverage, update download/install, or account-changing behavior. A
fresh default `Release` replay remained mandatory before any APK could be
published to `dist/`.

## 2026-09-06 no-dialog and list-refresh human promotion checkpoint

The owner authorized this work on 2026-09-06: `continue` after the fix plan,
and `refactor, upgrade app and backend, mirror, etc to handle million of
records`, the instruction under which the backend changes recorded in the
publication section below were also made. The promotion applies to the exact
r64 `SignedReview` candidate SHA-256
`888130a25938b9c7fe06ecb0e0e62056839e322f7498b317c5f0a20ce20861a5`
recorded above.

Returning this resolution to `review-required` for revision 61 had again
required re-arming `release.updateSignedDexReviewRequired` to `true`:
`patchlets/schemas/resolution.schema.json` couples the two fields for any
resolution whose `patchlets` list contains `085-in-app-update`, requiring
`updateSignedDexReviewRequired: true` while `status` is `review-required` and
`false` while `status` is `verified-current`. Re-arming that flag re-blocked
release until the updater contracts were proved again from raw signed DEX, and
the r64 `SignedReview` above is that proof: its signed-candidate update-flow
inspection and its 96 generated-D8 updater fixtures, including the three new
bootstrap-continuation negatives, both bound the rebound semantic SHA-256
`97b8947b803ef4dcdecefd315507bc1e5f9c27f89ab402639ab2646b46bde9f2`.

The exact resolution was therefore promoted at
`2026-09-06T15:13:52+07:00` by changing only `status` to `verified-current`,
`resolvedAt` to that timestamp, and `release.updateSignedDexReviewRequired`
to `false`. The promoted resolution file SHA-256 is
`6a34bfa8ce869ee36bef4e57805cf8a03850839028412fd425eda77444526193`; the
review-time file it replaced was
`65146501defd019fa813666b87fd1d9d4e1927682423909978aa08cf657a5089`.
No runtime Java, rendered Smali, rewrite, semantic proof, patchlet asset, or
review candidate was altered by promotion.

Promotion itself is not a release or publication result. A fresh default
`Release` replay from the pristine exact split set must independently rebuild,
sign, rerun the signed-DEX/archive release gates, and transactionally publish a
new candidate before a final APK can be claimed. The approved
exact-primary-DEX Activity probe remains the separate r64 `SignedReview`
promotion prerequisite recorded above; default `Release` does not rerun that
probe.

## 2026-09-06 revision 61 default Release publication

**Superseded on 2026-09-06.** The artifact this section records,
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-c.apk`,
SHA-256 `da17a14814b73ca4e94c02fe9f8e7382a0747a07682a84002b6aa086e90ad4fb`,
is superseded by the revision 62 publication recorded above,
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-d.apk`,
SHA-256 `e6ec4d70dacfa094659e31e09f2a890c537ba72b574767d62337a6a929c672a4`.
It reads the whole-file legacy `blocklist.json`, which the backend keeps
fitted under 512 KiB until every old install is replaced, so it still syncs
but only the trimmed ranked slice of the list; the revision 62 build reads
the chunked v3 index instead and updates a `-c` install in place. Every
sentence below that calls this artifact current, describes the whole-file
read as the client's present behaviour, names v3 client support as the next
revision, or inventories `dist/`, is historical fact as of this publication
at `2026-09-06T16:02:13.4195710+07:00`.

This is a **post-publication documentary append**. The successful pipeline
froze its canonical inputs before this evidence note and the other release
documents were updated. The recorded frozen inputs remain authoritative; the
current documentation-containing tree must not be substituted for them.

Fresh run
`work/patchlet-444-r64-release-20260906-a`
replayed the complete series from split-set SHA-256
`5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`
and deterministic universal source SHA-256
`156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`
against promoted resolution SHA-256
`6a34bfa8ce869ee36bef4e57805cf8a03850839028412fd425eda77444526193`.
Its frozen canonical `patchlets/**` tree SHA-256 is
`0b9123df0e297a194c0193183040b2d33fced155f1fafe9e0e81366d527c875d`;
the r64 `SignedReview` above had frozen
`d93abba4c6395b872514385b9a038199a32edb8b999bdf75a7c7d97f4ca2f944`
against the review-time resolution. The run completed at
`2026-09-06T16:02:13.4195710+07:00`.

The default `Release` transaction published
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-c.apk`,
135,133,736 bytes, SHA-256
`da17a14814b73ca4e94c02fe9f8e7382a0747a07682a84002b6aa086e90ad4fb`.
The run-local signed candidate, published file, build binding, and release
report all contain that exact digest. No `.publishing-*.tmp` residue remains.
The immutable release records are:

| Record | SHA-256 |
|---|---|
| `work/patchlet-444-r64-release-20260906-a/build-report.json` | `2e6530c642de91d0255c9abd361e8ed92c4d86845e8e93daaa510fc81b15ee5a` |
| `work/patchlet-444-r64-release-20260906-a/release-check.json` | `dc914aa4ab08106d1c623ec3d58e3b7e70d9f09e15eb6e51853fb599afaa247f` |
| `work/patchlet-444-r64-release-20260906-a/idempotency-check.json` | `97b7a93269408c742fcad500a59725e552e1c373f01d466beae95ed774e50d53` |
| `work/patchlet-444-r64-release-20260906-a/catalog-check.json` | `50f854e525a58c7eb8d91d8d944e98fc8ddec2bdda2c2c5a646f068621cd80f3` |
| `work/patchlet-444-r64-release-20260906-a/resolution-check.json` | `5777bb82788e97de8cef068112d0e4dfc720e086d9328b81ae447f992d6f0dda` |

Both reports record `status: passed`, `validationMode: Release`,
`reviewOnly: false`, `releaseEligible: true`, and `artifactProduced: true`.
The pre-report (`2026-09-06T15:59:13.5956522+07:00`), pre-publish
(`2026-09-06T16:02:15.9415803+07:00`), and post-publish
(`2026-09-06T16:04:27.7641657+07:00`) source/resolution/canonical-asset
freeze checks all matched with zero tree-monitor events and all 41 canonical
assets bound. Complete-series reapplication was content-identical with no
exclusions across 124,321 files, 8,163 directories, and 132,484 entries;
decoded-tree SHA-256 remained
`8d47fa9d2145beb92a550ee816a1df861af7916d1d6b64a099090a9f56c242ee`
before and after.

The published clone is package `app.tree55.threads` with launcher label
`Threads 55`, version code `511407878`, version name
`444.0.0.45.85-threadsmod.1`, minimum SDK 28, target SDK 36, arm64-v8a, and mod
build 1. Archive and 16 KiB alignment checks passed. It contains 13 root DEX
files and 14 DEX files in total; primary DEX has 61,746 method references under
the 65,535 ceiling. Signing is v2 only with exactly one signer whose
certificate SHA-256 is
`317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
All 69 source native libraries were preserved and the sole reviewed addition
remains `lib/arm64-v8a/libhev-socks5-tunnel.so`, SHA-256
`3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`,
with three 16 KiB AArch64 LOAD segments and passing JNI evidence.

Generated-D8 fixture matrices passed at their exact frozen counts: Block
bridge 328/328, report permalink 41/41, proxy bootstrap 13/13, and updater
96/96, the updater matrix including the `bootstrap-continuation-not-empty`,
`bootstrap-continuation-captures-activity` and
`bootstrap-demo-dialog-class-reintroduced` negatives at `observedPass: false`.
Direct inspection of the signed production DEX passed the Block bridge,
permalink, and updater contracts in `classes.dex` and the proxy-bootstrap
contract in `classes6.dex`; the signed update-flow inspection again bound
semantic SHA-256
`97b8947b803ef4dcdecefd315507bc1e5f9c27f89ab402639ab2646b46bde9f2`.
Targeted JADX 1.5.6 recovered and hash-bound all 38 reviewed classes, and the
`threadsmod.bootstrap.ModBootstrap` recovery forbade the `DemoDialog` token.

The published bytes were also checked directly for the removed and repaired
text. In the published APK's `classes.dex` the strings
`Threads Mod Auto Block`, `Lcom/threadsmod/DemoDialog;` and
`Disabled until you explicitly enable it` are absent, and the strings
`too_large` and `Enabled; waiting for a signed-in foreground session` are
present; `Passive blocking: always on`, which only the removed notice carried,
is absent as well. That `classes.dex` hashes to SHA-256
`74175bd78ead913a3243609ddaab4ef8304ab574fdfda5a2350a7c998157acf4`, the same
primary DEX as the r64 `SignedReview` candidate and its Activity probe. That
is a substring check and a hash of the published file itself, SHA-256
`da17a14814b73ca4e94c02fe9f8e7382a0747a07682a84002b6aa086e90ad4fb`, not of
the review candidate, a decoded tree, or canonical source; it establishes
which sentences the published DEX carries and is not a rendering or device
result.

Default `Release` correctly records `runtimeValidation: not-run` and has no
`activityUiReview`: the r64 `SignedReview` exact-primary-DEX Activity probe
above is the separate promotion prerequisite and was not rerun. The published
bytes have not been installed or run on any device. The only device evidence
for this revision is the r64 `SignedReview` candidate, SHA-256
`888130a25938b9c7fe06ecb0e0e62056839e322f7498b317c5f0a20ce20861a5` and not
this artifact, which passed the isolated no-permission Activity UI probe on an
emulator. No login, feed scrolling, Block, report, activation-ping delivery,
list refresh, update, or VPN behaviour has been exercised for either; the
4 MiB response bound, the transport-only retry, the failure ladder and the
closed failure-class status are static proof only. Neither the static release
gates nor the review probe establish full-app installation/startup, login,
live post/reply scrolling, native Block success, report or mirror delivery,
SOCKS endpoint/authentication or packet coverage, update download/install, or
any real account-changing behavior.

This artifact supersedes the 2026-09-06 revision 60 build
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-b.apk`,
SHA-256
`abcfb52fc23b1d819488789566c62189b5297183bf5e39652f17f132272d3bf8`, and
that build should not be installed. It still shows the first-run
`Threads Mod Auto Block` dialog; its `classes.dex`, SHA-256
`9acb9d8efe96102ddf50147b0bf9c85bb568a1bc0bf555a1d3290d0bfa3079a4`, carries
`Threads Mod Auto Block` and `Lcom/threadsmod/DemoDialog;` by the same direct
substring check. It is bound to a 512 KiB mirror-response cap, so it cannot
refresh from a signed list larger than that: on 2026-09-06 the signed list
measured 545,168-548,306 bytes on all three mirrors and that build failed
`too_large` on every mirror. It syncs again only because the backend now fits
the legacy `blocklist.json` under 524,288 bytes, as recorded below. Because
the application ID and version code `511407878` are unchanged, this artifact
updates an `abcfb52f` install in place rather than sitting beside it; the
same holds for the 2026-09-05 `threads55` build
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1.apk`,
SHA-256
`ca53165cc8f511e17b5967b49aae0c4b0fb0629da7da6dd0c46718250f1b3e73`
(superseded for its misleading `Disabled until you explicitly enable it.`
status line), and for the 2026-09-05 `tree55` build
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-tree55-mod1.apk`,
SHA-256
`7a8850ef96fe1f973358b1b07989090e3f94ec9ce0a30addb38e304ea8d3a1e6`, which
carried the launcher label `Threads Mod Demo`. It still installs side by side
with any `com.threadsmod.barcelona` clone, including the r53 artifact
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
SHA-256
`85124df5d5995af7ca3efd80b1a16f14b0e8fd380fc61e1bfe303b4037708ec4`.

`dist/` now holds `SHA256SUMS.txt`, the superseded `threads55-mod1-b` file and
this `threads55-mod1-c` file. The three older 444 artifacts remain historical
facts described by their own sections below, but on 2026-09-06 at 12:30 local
time they were removed from `dist/` by a shell deletion outside the pipeline
and outside the documentation append, as recorded in the revision 60 section
below; byte-identical copies survive only as the run-local Release outputs
`work/patchlet-444-r60-release-20260905-a/release/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`
(`ca53165c`),
`work/patchlet-444-r59-release-20260905-b/release/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`
(`7a8850ef`), and
`work/patchlet-444-release-20260904-b/release/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`
(`85124df5`). `dist/SHA256SUMS.txt` lists all five 444 artifacts, including
this one, as it still lists the ten 415 artifacts removed from `dist/`
earlier; its three lines for the removed 444 files verify only against those
run-local copies. The in-app updater cannot bridge package names and
`adb install -r` cannot update across them. No `threadsmod-update.json` has
been published for `app.tree55.threads`. Since 2026-09-06 the backend
app-update channel is bound to `app.tree55.threads` with bootstrap version
code `511407878`, so the channel no longer blocks one, but no update metadata
was published by this APK transaction and the in-app updater cannot serve
this build until one is.

For activation statistics, the backend route `POST /v1/installs` remains
deployed at the origin. That backend state is outside this APK transaction
and is unchanged by it; no ping from the published bytes has been sent or
observed.

The following block-list backend state is likewise outside this APK
transaction and was changed on the same day, not by it. First, the backend
now fits the legacy `blocklist.json` under 524,288 bytes by trimming only the
oldest ranked `targets` entries: the first fitted publish was 520,358 bytes
with 1,654 ranked targets, every one of the 1,784 ids still listed in `ids`,
`idTags` and `idNames`; it was deployed at 2026-09-06 06:44Z and mirrored at
06:50Z, so every earlier build syncs again from the trimmed file. Second, the
backend also publishes the chunked v3 format beside the legacy file: a signed
root `/blocklist/v3/manifest.json` (same key and envelope) names
content-addressed objects `/blocklist/v3/objects/<sha256>.json` (group tables,
extras) and `<sha256>.ndjson.gz` (gzip NDJSON chunks; rows `{i,u,d,t}` or
`{u,t}`; bucket = high k bits of `sha256(platform:id)`, k never decreases).
The first production build, `2026-09-06T07:14:05.577Z`, carried threads 1,633
rows and facebook 862 rows in 16 chunks each (k=4), 35 objects, 427,821 bytes,
and was verified byte-for-byte from origin, from the AWS relay (base64 gzip
path), from GitHub raw and from jsDelivr. The mirror cron copies the tree,
verifies the hash chain on its host copy and refuses a tick on a miss; the
relay allowlist admits exactly the root and the object-name shape (Lambda
code SHA-256 `hOHq5WS6fN8yrNr/lBj14HDCymF0SdEYApCQ7LFBhoQ=`); the pointer
gained a `v3Mirrors` field that old clients ignore; 200 backend tests pass.
The Android client in this artifact does not read v3; it still reads the
legacy file through the 4 MiB bound, and v3 client support followed in the
revision 62 publication recorded above. The Chrome extension still reads
the legacy file.

## Patchlet 090 revision 60 successful r61 SignedReview

The fresh pristine replay at
`work/patchlet-444-r61-signed-review-20260906-a`
completed with `status: passed` in `SignedReview` mode at
`2026-09-06T11:10:44.6515857+07:00`. It produced one signed, work-local
review candidate at
`work/patchlet-444-r61-signed-review-20260906-a/release/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
135,133,736 bytes, SHA-256
`7252940817521e93455b040d355bbd8e35951cb917a6b36bb16bf5d9f45fe23a`.
The build report deliberately records `reviewOnly: true`,
`releaseEligible: false`, `published: null`, and
`publicationRequested: null`; no matching candidate exists under `dist/`.
The review was bound to the review-time resolution file SHA-256
`fbb43500fb04af0791796e067db697875ef49a68135501305ceaec5efa737e79`
and to frozen canonical `patchlets/**` tree SHA-256
`a80cad31f642b64f7428995a188a88c940afcf36e4d387f7827e6535d0bc2970`.

The reviewed series is 010 r5, 020 r22, 050 r17, 060 r14, 070 r10, and 090
r60; only 020, 050, and 090 moved from the series published on 2026-09-05.
The revision corrects a user-visible text defect in that published build,
SHA-256
`ca53165cc8f511e17b5967b49aae0c4b0fb0629da7da6dd0c46718250f1b3e73`.
There, passive blocking was always on and working, but
`AutoBlockSync.getStatus(Context, String)` read the stored `enabled`
preference directly instead of through `isEnabled`, defaulting it to false,
so on a fresh install the status line displayed
`Disabled until you explicitly enable it.` while blocking was running; the
Settings reports disclosure also still said
`enabling passive blocking sends one activation ping`. Both sentences shipped
in that APK's DEX. The defect is misleading text, not behaviour, and it was
found by the documentation verifier sweep after publication. In this revision
the `getStatus` fallback is the single sentence
`Enabled; waiting for a signed-in foreground session.` and the preference is
never read for any decision: `KEY_ENABLED` is still written by a manual sync
but has no reader. The reports disclosure now reads
`this build sends one activation ping per installed build`, and the
`InstallStats` Javadoc no longer describes the ping as requiring a
caller-confirmed opt-in. No gate expectation moved; the bridge-flow negatives
were rebased after a net one-line shift in `AutoBlockSync.java`. No other
string, control, or behaviour changed.

The frozen review records are:

| Record | SHA-256 |
|---|---|
| `work/patchlet-444-r61-signed-review-20260906-a/build-report.json` | `af539b9763600b22994312446f741507e4e0bab7800c0f3bca7e749d87a31e77` |
| `work/patchlet-444-r61-signed-review-20260906-a/release-check.json` | `b274dd22e4cc83f34cd2d7451e1c018c4100e42ded90367ac87d6b0877dc6c25` |
| `work/patchlet-444-r61-signed-review-20260906-a/activity-ui-review.json` | `2556d99682672cf07b6e826fa136dd3a5cb9cb4adeee5e11731d331b6a17a3a6` |
| `work/patchlet-444-r61-signed-review-20260906-a/idempotency-check.json` | `a23dfeb288e6b4a0aa7b5455b3de00993e40cdbe3f2dc0460cb63d4b1f6a508d` |
| `work/patchlet-444-r61-signed-review-20260906-a/catalog-check.json` | `7125aad309053770487331c631e88e8b2c77f807e289db4e3a65461d836741e0` |
| `work/patchlet-444-r61-signed-review-20260906-a/resolution-check.json` | `86c81f33fcc7a4f5b271d978c29f3d276775c47dac3b8e2c97452ec2a3e9cea5` |

The source freeze matched the exact three-member split set at SHA-256
`5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`
and its deterministic universal source at SHA-256
`156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`.
The pre-report lock observed zero tree-monitor events and all 41 canonical
assets remained bound. Reapplying the complete series was a content-identical
no-op across 124,323 files, 8,163 directories, and 132,486 entries; the decoded
tree SHA-256 remained
`410b59d099fa2a792068cc7dd275fac8e0a72c9918e2642b1ab65ef83adc9368`
before and after, with no exclusions.

The final archive gate passed for clone package `app.tree55.threads`,
version code `511407878`, version name
`444.0.0.45.85-threadsmod.1`, minimum SDK 28, and target SDK 36. The archive
has 13 root DEX files and 14 DEX files in total. Primary DEX contains 61,739
method references, below the resolution-bound 65,535 ceiling. Archive shape,
16 KiB alignment, and signing checks passed with exactly one signer, v2 only,
certificate SHA-256
`317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
All 69 source native libraries were preserved; the sole reviewed addition is
`lib/arm64-v8a/libhev-socks5-tunnel.so`, SHA-256
`3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`,
whose three AArch64 LOAD segments each have 16 KiB alignment and whose JNI
contract passed.

Generated-D8 positive and bypass-negative suites passed their exact frozen
counts: Block bridge 328, report permalink 41, proxy bootstrap 13, and updater
96. Direct inspection of the signed candidate also passed the raw-Dex Block
bridge, report-permalink, and updater contracts in `classes.dex` and the proxy
bootstrap contract in `classes6.dex`. The signed candidate's update-flow
inspection and the updater positive fixture both bound the update-flow semantic
SHA-256
`d0e8d1ab489ab6241779cb18c21621f3ebd7f17310b36a18d49d6081d7d4d1ed`, which the
exact resolution pins as `expectedSemanticSha256`. Targeted JADX 1.5.6
recovery passed all 38 reviewed classes. Raw DEX remains authoritative over
readable JADX output.

The candidate's DEX was also checked directly for the corrected text. In the
candidate's `classes.dex` the string
`Disabled until you explicitly enable it` is absent, and the strings
`Enabled; waiting for a signed-in foreground session` and
`Passive blocking: always on` are present. That is a substring check of the
signed candidate's own bytes, not of canonical Java, generated Smali, or JADX
output; it establishes which sentences the candidate carries and is not itself
a rendering result.

The isolated no-permission Activity probe used an APK whose primary DEX is
byte-identical to the candidate primary DEX, SHA-256
`9acb9d8efe96102ddf50147b0bf9c85bb568a1bc0bf555a1d3290d0bfa3079a4`.
On the API 37 `sdk_gphone16k_x86_64` emulator it cold-launched and visibly
rendered `CloneBlockerActivity`, `CloneBlockerSettingsActivity`, and
`ProxySettingsActivity`; all three resumed with an empty crash log. The probe
requested no permissions and recorded
`networkOrAccountActionAttempted: false`, and the build report records
`runtimeValidation: isolated-activity-ui-probe-passed`.

The matcher contract is unchanged from r60. `CloneBlockerSettingsActivity`
required the exact viewport-intersecting node text `Sync now`, and the
recorded `visibleExactText` for that Activity is `Settings`, `Activity`,
`Current status`, and `Sync now`. The five dynamic fields `List fetch:`,
`Records:`, `New this refresh:`, `Database index:`, and `Inline control:`
matched as one contiguous ordered multiline sequence, and the contract still
carried its one positive and nine bypass fixtures with exact visible node
text, ordered multiline status, non-zero bounds, viewport intersection, and
non-empty status values all required. The matcher does not require the
`getStatus` fallback sentence, so passing it is not proof of which status line
is rendered. Separately, the UI hierarchy dumps the probe recorded for
`CloneBlockerActivity` and `CloneBlockerSettingsActivity` on that fresh,
account-less emulator install carry
`Enabled; waiting for a signed-in foreground session.` as node text and do
not contain `Disabled until you explicitly enable it`; that is an observation
on the recorded dumps, not a gate requirement. Matching `Sync now` establishes
only that the rendered control is labelled `Sync now`; it does not exercise
the sync action, a list refresh, or any blocking work.

This was successful signed-review evidence, not publication or promotion. At
that checkpoint the exact resolution remained `review-required` at
resolution-file SHA-256
`fbb43500fb04af0791796e067db697875ef49a68135501305ceaec5efa737e79`
with `release.updateSignedDexReviewRequired: true`; the promotion below is the
separate reviewed state transition. The isolated probe does not establish full
candidate installation or startup, login, live post/reply scrolling, native
Block success, report or activation-ping delivery, mirror reachability, SOCKS
endpoint/authentication or packet coverage, update download/install, or
account-changing behavior. A fresh default `Release` replay remained mandatory
before any APK could be published to `dist/`.

## 2026-09-06 status-text human promotion checkpoint

The owner explicitly reviewed and approved the exact r61 `SignedReview`
candidate SHA-256
`7252940817521e93455b040d355bbd8e35951cb917a6b36bb16bf5d9f45fe23a`
and authorized promotion and Release with `continue` on 2026-09-06.

Returning this resolution to `review-required` for revision 60 had again
required re-arming `release.updateSignedDexReviewRequired` to `true`:
`patchlets/schemas/resolution.schema.json` couples the two fields for any
resolution whose `patchlets` list contains `085-in-app-update`, requiring
`updateSignedDexReviewRequired: true` while `status` is `review-required` and
`false` while `status` is `verified-current`. Re-arming that flag re-blocked
release until the updater contracts were proved again from raw signed DEX, and
the r61 `SignedReview` above is that proof: its signed-candidate update-flow
inspection and its 96 generated-D8 updater fixtures both bound semantic SHA-256
`d0e8d1ab489ab6241779cb18c21621f3ebd7f17310b36a18d49d6081d7d4d1ed`.

The exact resolution was therefore promoted at
`2026-09-06T11:11:21+07:00` by changing only `status` to `verified-current`,
`resolvedAt` to that timestamp, and `release.updateSignedDexReviewRequired`
to `false`. The promoted resolution file SHA-256 is
`04e92a63eedd051b6c471607d929ab9737290b7664b0a13dbfa06d8653bfc9e5`.
No runtime Java, rendered Smali, rewrite, semantic proof, patchlet asset, or
review candidate was altered by promotion.

Promotion itself is not a release or publication result. A fresh default
`Release` replay from the pristine exact split set must independently rebuild,
sign, rerun the signed-DEX/archive release gates, and transactionally publish a
new candidate before a final APK can be claimed. The approved
exact-primary-DEX Activity probe remains the separate r61 `SignedReview`
promotion prerequisite recorded above; default `Release` does not rerun that
probe.

## 2026-09-06 revision 60 default Release publication

**Superseded on 2026-09-06.** The artifact this section describes, SHA-256
`abcfb52fc23b1d819488789566c62189b5297183bf5e39652f17f132272d3bf8`, still
shows the first-run `Threads Mod Auto Block` dialog (its `classes.dex`
carries `Threads Mod Auto Block` and `Lcom/threadsmod/DemoDialog;`) and is
bound to a 512 KiB mirror-response cap, so it cannot refresh from a signed
list larger than that: on 2026-09-06 the signed list measured
545,168-548,306 bytes on all three mirrors and this build failed `too_large`
on every mirror, showing `List fetch: Failed — no valid index` and
`Records: Unavailable`. It syncs again only because the backend now fits the
legacy `blocklist.json` under 524,288 bytes. It is superseded by the
2026-09-06 revision 61 publication recorded above, SHA-256
`da17a14814b73ca4e94c02fe9f8e7382a0747a07682a84002b6aa086e90ad4fb`, and
should not be installed. The rest of this section is unchanged and remains
the historical record of the 2026-09-06 revision 60 transaction.

This is a **post-publication documentary append**. The successful pipeline
froze its canonical inputs before this evidence note and the other release
documents were updated. The recorded frozen inputs remain authoritative; the
current documentation-containing tree must not be substituted for them.

Fresh run
`work/patchlet-444-r61-release-20260906-a`
replayed the complete series from split-set SHA-256
`5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`
and deterministic universal source SHA-256
`156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`
against promoted resolution SHA-256
`04e92a63eedd051b6c471607d929ab9737290b7664b0a13dbfa06d8653bfc9e5`.
Its frozen canonical `patchlets/**` tree SHA-256 is
`5f1172d805d7e589a931047413d1d9816ea697c899868b73c177f031dd6d7fc5`;
the r61 `SignedReview` above had frozen
`a80cad31f642b64f7428995a188a88c940afcf36e4d387f7827e6535d0bc2970`
against the review-time resolution. The run completed at
`2026-09-06T11:56:06.1981061+07:00`.

The default `Release` transaction published
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1-b.apk`,
135,133,736 bytes, SHA-256
`abcfb52fc23b1d819488789566c62189b5297183bf5e39652f17f132272d3bf8`.
The run-local signed candidate, published file, build binding, and release
report all contain that exact digest. No `.publishing-*.tmp` residue remains.
The immutable release records are:

| Record | SHA-256 |
|---|---|
| `work/patchlet-444-r61-release-20260906-a/build-report.json` | `51838e1728866c19934a3c4fc9805d0165bfacb4ff76df3d62f2dbb25c9c3793` |
| `work/patchlet-444-r61-release-20260906-a/release-check.json` | `110da11e18212b1673ecf4c2d525b7f09e891ad691f64eedf3420d05cc8822a2` |
| `work/patchlet-444-r61-release-20260906-a/idempotency-check.json` | `1d79190844edb92b387da4976169df6053b219d93966477f924b81c771442182` |
| `work/patchlet-444-r61-release-20260906-a/catalog-check.json` | `5f86835c71914b2951e509bfb457b8971a4dd8e16c8d8a1e08c464a3ee973d67` |
| `work/patchlet-444-r61-release-20260906-a/resolution-check.json` | `e53ddc3e32045e804bb508a5a278cf0ad912e67bfb672617c719757d9d86c32d` |

Both reports record `status: passed`, `validationMode: Release`,
`reviewOnly: false`, `releaseEligible: true`, and `artifactProduced: true`.
The pre-report, pre-publish, and post-publish source/resolution/canonical-asset
freeze checks all matched with zero tree-monitor events and all 41 canonical
assets bound. Complete-series reapplication was content-identical with no
exclusions across 124,323 files, 8,163 directories, and 132,486 entries;
decoded-tree SHA-256 remained
`b1517af1c293dd2a84e4155112e22e0283ac9fc437fee3db1aaef6f425df30d2`
before and after.

The published clone is package `app.tree55.threads` with launcher label
`Threads 55`, version code `511407878`, version name
`444.0.0.45.85-threadsmod.1`, minimum SDK 28, target SDK 36, arm64-v8a, and mod
build 1. Archive and 16 KiB alignment checks passed. It contains 13 root DEX
files and 14 DEX files in total; primary DEX has 61,739 method references under
the 65,535 ceiling. Signing is v2 only with exactly one signer whose
certificate SHA-256 is
`317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
All 69 source native libraries were preserved and the sole reviewed addition
remains `lib/arm64-v8a/libhev-socks5-tunnel.so`, SHA-256
`3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`,
with three 16 KiB AArch64 LOAD segments and passing JNI evidence.

Generated-D8 fixture matrices passed at their exact frozen counts: Block
bridge 328/328, report permalink 41/41, proxy bootstrap 13/13, and updater
96/96. Direct inspection of the signed production DEX passed the Block bridge,
permalink, and updater contracts in `classes.dex` and the proxy-bootstrap
contract in `classes6.dex`; the signed update-flow inspection again bound
semantic SHA-256
`d0e8d1ab489ab6241779cb18c21621f3ebd7f17310b36a18d49d6081d7d4d1ed`.
Targeted JADX 1.5.6 recovered and hash-bound all 38 reviewed classes.

The published bytes were also checked directly for the corrected text. In the
published APK's `classes.dex` the stale string
`Disabled until you explicitly enable it` is absent, and the always-on
fallback `Enabled; waiting for a signed-in foreground session` is present, as
is `Passive blocking: always on`. That is a substring check of the published
file itself, SHA-256
`abcfb52fc23b1d819488789566c62189b5297183bf5e39652f17f132272d3bf8`, not of
the review candidate, a decoded tree, or canonical source; it establishes
which sentences the published DEX carries and is not a rendering result.

Default `Release` correctly records `runtimeValidation: not-run` and has no
`activityUiReview`: the r61 `SignedReview` exact-primary-DEX Activity probe
above is the separate promotion prerequisite and was not rerun. The published
bytes have not been installed or run on any device. The only device evidence
for this revision is the r61 `SignedReview` candidate, SHA-256
`7252940817521e93455b040d355bbd8e35951cb917a6b36bb16bf5d9f45fe23a` and not
this artifact, which passed the isolated no-permission Activity UI probe on an
emulator. No login, feed scrolling, Block, report, activation-ping delivery,
update, or VPN behaviour has been exercised for either. Neither the static
release gates nor the review probe establish full-app installation/startup,
login, live post/reply scrolling, native Block success, report or mirror
delivery, SOCKS endpoint/authentication or packet coverage, update
download/install, or any real account-changing behavior.

This artifact supersedes the 2026-09-05 `threads55` build
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1.apk`,
SHA-256
`ca53165cc8f511e17b5967b49aae0c4b0fb0629da7da6dd0c46718250f1b3e73`, and
that build should not be installed. Its passive blocking was always on and
working, but its `AutoBlockSync.getStatus(Context, String)` read the stored
`enabled` preference directly instead of through `isEnabled`, defaulting it
to false, so on a fresh install its status line displayed
`Disabled until you explicitly enable it.` while blocking was running, and
its Settings reports disclosure still said
`enabling passive blocking sends one activation ping`. Both sentences are in
that APK's DEX. The defect is misleading text, not behaviour, and it was found
by the documentation verifier sweep after publication. That build was removed
from `dist/` on 2026-09-06 after this record was first written, as recorded
below, and remains the historical fact described by its own section below.
Because the application ID and version code `511407878` are unchanged, this
artifact updates a `ca53165c` install in place rather than sitting beside it;
the same holds for the 2026-09-05 `tree55` build
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-tree55-mod1.apk`,
SHA-256
`7a8850ef96fe1f973358b1b07989090e3f94ec9ce0a30addb38e304ea8d3a1e6`, which
carried the launcher label `Threads Mod Demo`. It still installs side by side
with any `com.threadsmod.barcelona` clone, including the r53 artifact
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
SHA-256
`85124df5d5995af7ca3efd80b1a16f14b0e8fd380fc61e1bfe303b4037708ec4`.
All three earlier artifacts remain historical facts described by their own
sections below, but they were removed from `dist/` on 2026-09-06: the `dist/`
directory's modification time is `2026-09-06T12:30:14+07:00`, after this
record was first written and after the `2026-09-06T11:56:06.1981061+07:00`
publication; no pipeline run started after that publication (the newest
`work/` entry is the r61 Release directory itself), and on 2026-09-06 the
three files were observed in the Windows Recycle Bin with original path
`dist/` and a deletion time of 12:30, so the removal was a shell deletion
outside the pipeline and outside the documentation append. Byte-identical
copies survive only as the run-local Release outputs
`work/patchlet-444-r60-release-20260905-a/release/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
SHA-256
`ca53165cc8f511e17b5967b49aae0c4b0fb0629da7da6dd0c46718250f1b3e73` (the
superseded `threads55-mod1` build);
`work/patchlet-444-r59-release-20260905-b/release/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
SHA-256
`7a8850ef96fe1f973358b1b07989090e3f94ec9ce0a30addb38e304ea8d3a1e6` (the
`tree55-mod1` build); and
`work/patchlet-444-release-20260904-b/release/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
SHA-256
`85124df5d5995af7ca3efd80b1a16f14b0e8fd380fc61e1bfe303b4037708ec4` (the r53
`update-mod1` build), each 135,133,736 bytes, verified with `sha256sum` on
2026-09-06. All three run-local files carry the Release run's internal
`update-mod1` name, so only the hash identifies which published artifact each
one is. `dist/SHA256SUMS.txt` is unchanged and still lists all four 444
artifacts, as it still lists the ten 415 artifacts removed from `dist/`
earlier; its three lines for the removed 444 files verify only against those
run-local copies. The in-app updater cannot bridge package names and
`adb install -r` cannot update across them. No `threadsmod-update.json` has
been published for `app.tree55.threads`; the backend app-update channel was at
that time still bound to `com.threadsmod.barcelona` (since 2026-09-06 it is
bound to `app.tree55.threads` with bootstrap version code `511407878`), so
the in-app updater could not serve this build. No update metadata was
published by this APK transaction.

For activation statistics, the backend route `POST /v1/installs` remains
deployed at the origin and the AWS relay allowlist still admits exactly
`/v1/installs`, so a ping from this build is accepted end to end. That backend
state is outside this APK transaction and is unchanged by it; no ping from the
published bytes has been sent or observed.

## Patchlet 090 revision 59 successful r60 SignedReview

The fresh pristine replay at
`work/patchlet-444-r60-signed-review-20260905-b`
completed with `status: passed` in `SignedReview` mode at
`2026-09-05T14:47:12.4411601+07:00`. It produced one signed, work-local
review candidate at
`work/patchlet-444-r60-signed-review-20260905-b/release/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
135,133,736 bytes, SHA-256
`f7a5ee38c07d050e34defa73d1c6737e8c340f7f7187327d6d13cafe40488f9e`.
The build report deliberately records `reviewOnly: true`,
`releaseEligible: false`, `published: null`, and
`publicationRequested: null`; no matching candidate exists under `dist/`.
The review was bound to the review-time resolution file SHA-256
`7a5440a9b7df136207ba8032fe43e7be957c2ff5cca918c71873bb7d040689ee`
and to frozen canonical `patchlets/**` tree SHA-256
`5b97e238fd2a3bddf3d7c2b2914fa0d3e2cc2c68c3b1e9280209337f58d0fac3`.

An earlier attempt at
`work/patchlet-444-r60-signed-review-20260905-a`
stopped after the pristine decode and its baseline round-trip. It snapshotted
the same review-time resolution SHA-256
`7a5440a9b7df136207ba8032fe43e7be957c2ff5cca918c71873bb7d040689ee`
but wrote no `build-report.json`, produced no `release/` directory, signed
candidate, `release-check.json`, or Activity UI result, and published nothing.
The directory is retained as an aborted run whose name cannot be reused; it is
not evidence about the candidate.

The frozen review records are:

| Record | SHA-256 |
|---|---|
| `work/patchlet-444-r60-signed-review-20260905-b/build-report.json` | `4e0452954bd88c096f3ec4dfe9381f9ec6e40c1b727878a27ee13fbe0611fb58` |
| `work/patchlet-444-r60-signed-review-20260905-b/release-check.json` | `e91b1937feff7fc2deb9f7b422570c9b2de75cffa2f57caa9a6fb6de477aa13d` |
| `work/patchlet-444-r60-signed-review-20260905-b/activity-ui-review.json` | `43ae91cfa04360f7e30d170a353e615cda23ca284f1651926eff3a7c92766da9` |
| `work/patchlet-444-r60-signed-review-20260905-b/idempotency-check.json` | `f38b11da723c99642e2fb30ed57ceb8cf190c7078029ca875cb66816d7bfa360` |
| `work/patchlet-444-r60-signed-review-20260905-b/catalog-check.json` | `946b0ea555e30aec044eaab71aaf69e3f332b953bf6800e805ca80efe709c09c` |
| `work/patchlet-444-r60-signed-review-20260905-b/resolution-check.json` | `64f498e276d73c22c3202e0111dda456f3751e2dda2c29895374b7f66c8d5e70` |

The source freeze matched the exact three-member split set at SHA-256
`5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`
and its deterministic universal source at SHA-256
`156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`.
The pre-report lock observed zero tree-monitor events and all 41 canonical
assets remained bound. Reapplying the complete series was a content-identical
no-op across 124,323 files, 8,163 directories, and 132,486 entries; the decoded
tree SHA-256 remained
`62f5cbbbd957c9f8c407b7c24064f2365c717ab1f81f72f225df687cfe7ab089`
before and after, with no exclusions.

The final archive gate passed for clone package `app.tree55.threads`,
version code `511407878`, version name
`444.0.0.45.85-threadsmod.1`, minimum SDK 28, and target SDK 36. The archive
has 13 root DEX files and 14 DEX files in total. Primary DEX contains 61,739
method references, below the resolution-bound 65,535 ceiling. Archive shape,
16 KiB alignment, and signing checks passed with exactly one signer, v2 only,
certificate SHA-256
`317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
All 69 source native libraries were preserved; the sole reviewed addition is
`lib/arm64-v8a/libhev-socks5-tunnel.so`, SHA-256
`3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`,
whose three AArch64 LOAD segments each have 16 KiB alignment and whose JNI
contract passed.

Generated-D8 positive and bypass-negative suites passed their exact frozen
counts: Block bridge 328, report permalink 41, proxy bootstrap 13, and updater
96. Direct inspection of the signed candidate also passed the raw-Dex Block
bridge, report-permalink, and updater contracts in `classes.dex` and the proxy
bootstrap contract in `classes6.dex`. The signed candidate's update-flow
inspection and the updater positive fixture both bound the update-flow semantic
SHA-256
`d0e8d1ab489ab6241779cb18c21621f3ebd7f17310b36a18d49d6081d7d4d1ed`, which the
exact resolution pins as `expectedSemanticSha256`. Targeted JADX 1.5.6
recovery passed all 38 reviewed classes. Raw DEX remains authoritative over
readable JADX output.

The isolated no-permission Activity probe used an APK whose primary DEX is
byte-identical to the candidate primary DEX, SHA-256
`5cbb3ae55211a0efa883725f9d3868b9058e95014d2ae8a6fcd387f4931c9137`.
On the API 37 `sdk_gphone16k_x86_64` emulator it cold-launched and visibly
rendered `CloneBlockerActivity`, `CloneBlockerSettingsActivity`, and
`ProxySettingsActivity`; all three resumed with an empty crash log. The probe
requested no permissions and recorded
`networkOrAccountActionAttempted: false`, and the build report records
`runtimeValidation: isolated-activity-ui-probe-passed`.

That probe is this revision's only evidence about the rendered UI, and it is
what shows the passive-blocking switch is gone from it. The
`CloneBlockerSettingsActivity` matcher required the exact viewport-intersecting
node text `Sync now` where the r59 probe had required `Enable & sync`; the
recorded `visibleExactText` for that Activity is `Settings`, `Activity`,
`Current status`, and `Sync now`. The five dynamic fields `List fetch:`,
`Records:`, `New this refresh:`, `Database index:`, and `Inline control:` still
matched as one contiguous ordered multiline sequence, and the matcher contract
still carried its one positive and nine bypass fixtures with exact visible node
text, ordered multiline status, non-zero bounds, viewport intersection, and
non-empty status values all required. Matching that node text establishes only
that the rendered control is labelled `Sync now`; it does not exercise the sync
action, a list refresh, or any blocking work.

This was successful signed-review evidence, not publication or promotion. At
that checkpoint the exact resolution remained `review-required` at
resolution-file SHA-256
`7a5440a9b7df136207ba8032fe43e7be957c2ff5cca918c71873bb7d040689ee`
with `release.updateSignedDexReviewRequired: true`; the promotion below is the
separate reviewed state transition. The isolated probe does not establish full
candidate installation or startup, login, live post/reply scrolling, native
Block success, report or activation-ping delivery, mirror reachability, SOCKS
endpoint/authentication or packet coverage, update download/install, or
account-changing behavior. A fresh default `Release` replay remained mandatory
before any APK could be published to `dist/`.

## 2026-09-05 Threads 55 human promotion checkpoint

The owner explicitly reviewed and approved the exact r60 `SignedReview`
candidate SHA-256
`f7a5ee38c07d050e34defa73d1c6737e8c340f7f7187327d6d13cafe40488f9e`
and authorized promotion and Release on 2026-09-05.

Returning this resolution to `review-required` for revision 59 had also
required re-arming `release.updateSignedDexReviewRequired` to `true`:
`patchlets/schemas/resolution.schema.json` couples the two fields for any
resolution whose `patchlets` list contains `085-in-app-update`, requiring
`updateSignedDexReviewRequired: true` while `status` is `review-required` and
`false` while `status` is `verified-current`. Re-arming that flag re-blocked
release until the updater contracts were proved again from raw signed DEX, and
the r60 `SignedReview` above is that proof: its signed-candidate update-flow
inspection and its 96 generated-D8 updater fixtures both bound semantic SHA-256
`d0e8d1ab489ab6241779cb18c21621f3ebd7f17310b36a18d49d6081d7d4d1ed`.

The exact resolution was therefore promoted at
`2026-09-05T17:05:44+07:00` by changing only `status` to `verified-current`,
`resolvedAt` to that timestamp, and `release.updateSignedDexReviewRequired`
to `false`. The promoted resolution file SHA-256 is
`6014c9090e86c8ba7c8497addc47936ee8f9f73aa673e58f4f24c3b582d1f42b`.
No runtime Java, rendered Smali, rewrite, semantic proof, patchlet asset, or
review candidate was altered by promotion.

Promotion itself is not a release or publication result. A fresh default
`Release` replay from the pristine exact split set must independently rebuild,
sign, rerun the signed-DEX/archive release gates, and transactionally publish a
new candidate before a final APK can be claimed. The approved
exact-primary-DEX Activity probe remains the separate r60 `SignedReview`
promotion prerequisite recorded above; default `Release` does not rerun that
probe.

## 2026-09-05 revision 59 default Release publication

**Superseded on 2026-09-06.** The artifact this section describes, SHA-256
`ca53165cc8f511e17b5967b49aae0c4b0fb0629da7da6dd0c46718250f1b3e73`, was later
found to display the status line `Disabled until you explicitly enable it.`
on a fresh install while passive blocking was running, because
`AutoBlockSync.getStatus(Context, String)` read the stored `enabled`
preference directly instead of through `isEnabled`; its Settings reports
disclosure also still said
`enabling passive blocking sends one activation ping`. The text was
misleading; blocking worked. It is superseded by the 2026-09-06 revision 60
publication recorded above, SHA-256
`abcfb52fc23b1d819488789566c62189b5297183bf5e39652f17f132272d3bf8`, and
should not be installed. The rest of this section is unchanged and remains
the historical record of the 2026-09-05 transaction.

This is a **post-publication documentary append**. The successful pipeline
froze its canonical inputs before this evidence note and the other release
documents were updated. The recorded frozen inputs remain authoritative; the
current documentation-containing tree must not be substituted for them.

Fresh run
`work/patchlet-444-r60-release-20260905-a`
replayed the complete series from split-set SHA-256
`5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`
and deterministic universal source SHA-256
`156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`
against promoted resolution SHA-256
`6014c9090e86c8ba7c8497addc47936ee8f9f73aa673e58f4f24c3b582d1f42b`.
Its frozen canonical `patchlets/**` tree SHA-256 is
`5a5fc6266877865184b137c2e248289bb8a4d2e4354111787c286ebb4d8a2764`;
the r60 `SignedReview` above had frozen
`5b97e238fd2a3bddf3d7c2b2914fa0d3e2cc2c68c3b1e9280209337f58d0fac3`
against the review-time resolution. The run completed at
`2026-09-05T17:44:26.5907587+07:00`.

The default `Release` transaction published
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-threads55-mod1.apk`,
135,133,736 bytes, SHA-256
`ca53165cc8f511e17b5967b49aae0c4b0fb0629da7da6dd0c46718250f1b3e73`.
The run-local signed candidate, published file, build binding, and release
report all contain that exact digest. No `.publishing-*.tmp` residue remains.
The immutable release records are:

| Record | SHA-256 |
|---|---|
| `work/patchlet-444-r60-release-20260905-a/build-report.json` | `e41a250d61ec52033a74678a2a117f72ecf74910f12621b7f98ffbfb46ffa329` |
| `work/patchlet-444-r60-release-20260905-a/release-check.json` | `41cc0c2c4e821b49cadf70aba5949b7ca88ed1af784a4e5defb46f09963fd9e4` |
| `work/patchlet-444-r60-release-20260905-a/idempotency-check.json` | `1a926582c45bc11f813574400263409c5977cf757aef08afc8f2810ffe0c367b` |
| `work/patchlet-444-r60-release-20260905-a/catalog-check.json` | `f43c7ee20e02919edfc8780c7d2d292f73417ce7544f05cf2bef093c89c38f1c` |
| `work/patchlet-444-r60-release-20260905-a/resolution-check.json` | `8cb37bf75aa759173242d31bca426ac4c47f6d22d2aa0fecc6a80098e49b8dd9` |

Both reports record `status: passed`, `validationMode: Release`,
`reviewOnly: false`, `releaseEligible: true`, and `artifactProduced: true`.
The pre-report, pre-publish, and post-publish source/resolution/canonical-asset
freeze checks all matched with zero tree-monitor events and all 41 canonical
assets bound. Complete-series reapplication was content-identical with no
exclusions across 124,323 files, 8,163 directories, and 132,486 entries;
decoded-tree SHA-256 remained
`23794fead5fa4705929c604a257ae437adeba58b0a447b8e6fc1c57ee979ef2a`
before and after.

The published clone is package `app.tree55.threads` with launcher label
`Threads 55`, version code `511407878`, version name
`444.0.0.45.85-threadsmod.1`, minimum SDK 28, target SDK 36, arm64-v8a, and mod
build 1. Archive and 16 KiB alignment checks passed. It contains 13 root DEX
files and 14 DEX files in total; primary DEX has 61,739 method references under
the 65,535 ceiling. Signing is v2 only with exactly one signer whose
certificate SHA-256 is
`317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
All 69 source native libraries were preserved and the sole reviewed addition
remains `lib/arm64-v8a/libhev-socks5-tunnel.so`, SHA-256
`3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`,
with three 16 KiB AArch64 LOAD segments and passing JNI evidence.

Generated-D8 fixture matrices passed at their exact frozen counts: Block
bridge 328/328, report permalink 41/41, proxy bootstrap 13/13, and updater
96/96. Direct inspection of the signed production DEX passed the Block bridge,
permalink, and updater contracts in `classes.dex` and the proxy-bootstrap
contract in `classes6.dex`; the signed update-flow inspection again bound
semantic SHA-256
`d0e8d1ab489ab6241779cb18c21621f3ebd7f17310b36a18d49d6081d7d4d1ed`.
Targeted JADX 1.5.6 recovered and hash-bound all 38 reviewed classes.

Default `Release` correctly records `runtimeValidation: not-run` and has no
`activityUiReview`: the r60 `SignedReview` exact-primary-DEX Activity probe
above is the separate promotion prerequisite and was not rerun. The published
bytes have not been installed or run on any device. The only device evidence
for this revision is the r60 `SignedReview` candidate, SHA-256
`f7a5ee38c07d050e34defa73d1c6737e8c340f7f7187327d6d13cafe40488f9e` and not
this artifact, which passed the isolated no-permission Activity UI probe on an
emulator. No login, feed scrolling, Block, report, activation-ping delivery,
update, or VPN behaviour has been exercised for either. Neither the static
release gates nor the review probe establish full-app installation/startup,
login, live post/reply scrolling, native Block success, report or mirror
delivery, SOCKS endpoint/authentication or packet coverage, update
download/install, or any real account-changing behavior.

Because the version code and application ID are unchanged from the 2026-09-05
`tree55` build
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-tree55-mod1.apk`,
SHA-256
`7a8850ef96fe1f973358b1b07989090e3f94ec9ce0a30addb38e304ea8d3a1e6`,
this artifact updates that install rather than sitting beside it; that build
carried the launcher label `Threads Mod Demo`. It still installs side by side
with any `com.threadsmod.barcelona` clone, including the r53 artifact
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
SHA-256
`85124df5d5995af7ca3efd80b1a16f14b0e8fd380fc61e1bfe303b4037708ec4`.
Both earlier artifacts stay in `dist/` untouched and remain historical facts
described by their own sections below; `dist/SHA256SUMS.txt` lists all three.
The in-app updater cannot bridge package names and `adb install -r` cannot
update across them. No `threadsmod-update.json` has been published for
`app.tree55.threads`; the backend app-update channel was at that time still
bound to `com.threadsmod.barcelona` (since 2026-09-06 it is bound to
`app.tree55.threads` with bootstrap version code `511407878`), so the in-app
updater could not serve this build. No update metadata was published by this
APK transaction.

For activation statistics, the backend route `POST /v1/installs` remains
deployed at the origin and the AWS relay allowlist still admits exactly
`/v1/installs`, so a ping from this build is accepted end to end. That backend
state is outside this APK transaction and is unchanged by it; no ping from the
published bytes has been sent or observed.

## Patchlet 090 revision 58 successful r59 SignedReview

The fresh pristine replay at
`work/patchlet-444-r59-signed-review-20260904-a`
completed with `status: passed` in `SignedReview` mode at
`2026-09-05T00:23:06.7721632+07:00`. It produced one signed, work-local
review candidate at
`work/patchlet-444-r59-signed-review-20260904-a/release/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
135,133,736 bytes, SHA-256
`280fa71d00315dbadcece0de5b3fcf19dffd542ee95a8052f979c2dbe86cf9b8`.
The build report deliberately records `reviewOnly: true`,
`releaseEligible: false`, `published: null`, and
`publicationRequested: null`; no matching candidate exists under `dist/`.
The review was bound to the review-time resolution file SHA-256
`d475da9d2688be4924899bcd11e7e1916f97eb6d0f38724e4a5ec2884941a8d8`
and to frozen canonical `patchlets/**` tree SHA-256
`23f6439ac4b056dfeb8c9f6085d1ba438fb2258796dea06a75ac872af059c8e9`.

The frozen review records are:

| Record | SHA-256 |
|---|---|
| `work/patchlet-444-r59-signed-review-20260904-a/build-report.json` | `6f97a9b1590eb1ace739dfc1ec7bbced3fd427af6bc49911b4e2bfa8c2d5c5e2` |
| `work/patchlet-444-r59-signed-review-20260904-a/release-check.json` | `60d861a1b400163e2c68248c3bcfac74fccf4a2f34343e925b3e10b33f52aae1` |
| `work/patchlet-444-r59-signed-review-20260904-a/activity-ui-review.json` | `2053c1fde7d41c5b98a67023be522e804f2545d5f4e4c3b2f3c147e118694cad` |
| `work/patchlet-444-r59-signed-review-20260904-a/idempotency-check.json` | `e9d340b290f070b943b18a4aa8229885473762e1642e6aa21ae9d5684ff2de3d` |
| `work/patchlet-444-r59-signed-review-20260904-a/catalog-check.json` | `7742eb897409541f5bdd6b6904ce6c657dd1023888c2a213ed036bfd5d1c989e` |
| `work/patchlet-444-r59-signed-review-20260904-a/resolution-check.json` | `59cb133c033f19755f1c7cc464a95e3972dd52a25470552c65e826d172119941` |

The source freeze matched the exact three-member split set at SHA-256
`5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`
and its deterministic universal source at SHA-256
`156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`.
The pre-report lock observed zero tree-monitor events and all 41 canonical
assets remained bound. Reapplying the complete series was a content-identical
no-op across 124,325 files, 8,163 directories, and 132,488 entries; the decoded
tree SHA-256 remained
`b3483baf338717b30ac4a5ab883a519c3b5f0dfd7249ad028522a352331f7e1f`
before and after, with no exclusions.

The final archive gate passed for clone package `app.tree55.threads`,
version code `511407878`, version name
`444.0.0.45.85-threadsmod.1`, minimum SDK 28, and target SDK 36. The archive
has 13 root DEX files and 14 DEX files in total. Primary DEX contains 61,744
method references, below the resolution-bound 65,535 ceiling. Archive shape,
16 KiB alignment, and signing checks passed with exactly one signer, v2 only,
certificate SHA-256
`317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
All 69 source native libraries were preserved; the sole reviewed addition is
`lib/arm64-v8a/libhev-socks5-tunnel.so`, SHA-256
`3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`,
whose three AArch64 LOAD segments each have 16 KiB alignment and whose JNI
contract passed.

Generated-D8 positive and bypass-negative suites passed their exact frozen
counts: Block bridge 328, report permalink 41, proxy bootstrap 13, and updater
96. Direct inspection of the signed candidate also passed the raw-Dex Block
bridge, report-permalink, and updater contracts in `classes.dex` and the proxy
bootstrap contract in `classes6.dex`. The signed candidate's update-flow
inspection and the updater positive fixture both bound the rebound update-flow
semantic SHA-256
`d0e8d1ab489ab6241779cb18c21621f3ebd7f17310b36a18d49d6081d7d4d1ed`, which the
exact resolution pins as `expectedSemanticSha256`. Targeted JADX 1.5.6
recovery passed all 38 reviewed classes. Raw DEX remains authoritative over
readable JADX output.

The isolated no-permission Activity probe used an APK whose primary DEX is
byte-identical to the candidate primary DEX, SHA-256
`54f79f7fcb32c31ff71e29ef9e49492210f91e2d9519c5c12d84ee6b88da8e99`.
On the API 37 `sdk_gphone16k_x86_64` emulator it cold-launched and visibly
rendered `CloneBlockerActivity`, `CloneBlockerSettingsActivity`, and
`ProxySettingsActivity`; all three resumed with an empty crash log. The probe
requested no permissions and attempted no account or network action, and the
build report records `runtimeValidation: isolated-activity-ui-probe-passed`.

This was successful signed-review evidence, not publication or promotion. At
that checkpoint the exact resolution remained `review-required` at
resolution-file SHA-256
`d475da9d2688be4924899bcd11e7e1916f97eb6d0f38724e4a5ec2884941a8d8`
with `release.updateSignedDexReviewRequired: true`; the promotion below is the
separate reviewed state transition. The isolated probe does not establish full
candidate installation or startup, login, live post/reply scrolling, native
Block success, report or activation-ping delivery, mirror reachability, SOCKS
endpoint/authentication or packet coverage, update download/install, or
account-changing behavior. A fresh default `Release` replay remained mandatory
before any APK could be published to `dist/`.

## 2026-09-05 human promotion checkpoint

The user explicitly approved the exact r59 `SignedReview` candidate SHA-256
`280fa71d00315dbadcece0de5b3fcf19dffd542ee95a8052f979c2dbe86cf9b8`
and authorized promotion and production of the final release APK on
2026-09-05. An independent four-reviewer workflow found no blocker in the
frozen signed-review reports or candidate bytes. It found two `AGENTS.md`
wording mismatches, which the promoter fixed before the Release: the closed
activation-statistics field set now names the constant schema-version key `v`
as its 13th member, and the recovered `report_request_unavailable` literal
count is stated as 2. Both are rule-text reconciliations outside the frozen
canonical `patchlets/**` tree. The exact resolution was therefore promoted at
`2026-09-05T10:48:38+07:00` by changing only `status` to `verified-current`,
`resolvedAt` to that timestamp, and `release.updateSignedDexReviewRequired`
to `false`. The promoted resolution file SHA-256 is
`7ac5954964677708c827057faf98e13da40b06adb68dba110c72c13185954784`.
No runtime Java, rendered Smali, rewrite, semantic proof, patchlet asset, or
review candidate was altered by promotion.

Promotion itself is not a release or publication result. A fresh default
`Release` replay from the pristine exact split set must independently rebuild,
sign, rerun the signed-DEX/archive release gates, and transactionally publish a
new candidate before a final APK can be claimed. The approved
exact-primary-DEX Activity probe remains the separate r59 `SignedReview`
promotion prerequisite recorded above; default `Release` does not rerun that
probe.

## 2026-09-05 revision 58 default Release publication

This is a **post-publication documentary append**. The successful pipeline
froze its canonical inputs before this evidence note and the other release
documents were updated. The recorded frozen inputs remain authoritative; the
current documentation-containing tree must not be substituted for them.

An earlier default `Release` attempt at
`work/patchlet-444-r59-release-20260905-a`
was an aborted external interruption: the host terminated it during the smali
rebuild because the machine ran low on memory while a headless emulator was
resident. It wrote no `build-report.json`, published nothing, left no
`.publishing-*.tmp` residue in `dist/`, and did not alter the resolution, whose
SHA-256 was re-verified afterwards as
`7ac5954964677708c827057faf98e13da40b06adb68dba110c72c13185954784`. The
directory is retained as an aborted run and its name cannot be reused; it is
not evidence about the candidate.

Fresh run
`work/patchlet-444-r59-release-20260905-b`
replayed the complete series from split-set SHA-256
`5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`
and deterministic universal source SHA-256
`156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`
against promoted resolution SHA-256
`7ac5954964677708c827057faf98e13da40b06adb68dba110c72c13185954784`.
Its frozen canonical `patchlets/**` tree SHA-256 is
`b3cb3bd58366f32edcb35cb9646281ef93b0e020d7a3259ba13e21ea631c8cd7`;
the r59 `SignedReview` above had frozen
`23f6439ac4b056dfeb8c9f6085d1ba438fb2258796dea06a75ac872af059c8e9`
against the review-time resolution. The run completed at
`2026-09-05T12:31:28.9580718+07:00`.

The default `Release` transaction published
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-tree55-mod1.apk`,
135,133,736 bytes, SHA-256
`7a8850ef96fe1f973358b1b07989090e3f94ec9ce0a30addb38e304ea8d3a1e6`.
The run-local signed candidate, published file, build binding, and release
report all contain that exact digest. No `.publishing-*.tmp` residue remains.
The immutable release records are:

| Record | SHA-256 |
|---|---|
| `work/patchlet-444-r59-release-20260905-b/build-report.json` | `4e3a5a00f2839004a5d215b443f4cd3a72294855d61011094ce455da49db287f` |
| `work/patchlet-444-r59-release-20260905-b/release-check.json` | `703d17e39e1dbea107191939f5c57b59d82eb08bb724a0ef7cd692c7819407d4` |
| `work/patchlet-444-r59-release-20260905-b/idempotency-check.json` | `738e3d674bdd6d11507d9f6d602072808e9073c96068b69d2f96615323a010cf` |
| `work/patchlet-444-r59-release-20260905-b/catalog-check.json` | `14254876d43d28ffacdce4ac58a72d64d279a9de2007fe2ed4fa1f5ad270a8b5` |
| `work/patchlet-444-r59-release-20260905-b/resolution-check.json` | `495cc0c48bab0b8b3f56a0e2a16c87b5a463f7e2982854b9fe704e1c270fb31b` |

Both reports record `status: passed`, `validationMode: Release`,
`reviewOnly: false`, `releaseEligible: true`, and `artifactProduced: true`.
The pre-report, pre-publish, and post-publish source/resolution/canonical-asset
freeze checks all matched with zero tree-monitor events and all 41 canonical
assets bound. Complete-series reapplication was content-identical with no
exclusions across 124,325 files, 8,163 directories, and 132,488 entries;
decoded-tree SHA-256 remained
`73545eeafc37f3dd25c0a6e622a760c31917ca3deacf52d4ede6e7ddaaa97300`
before and after.

The published clone is package `app.tree55.threads`, version code
`511407878`, version name `444.0.0.45.85-threadsmod.1`, minimum SDK 28, target
SDK 36, arm64-v8a, and mod build 1. Archive and 16 KiB alignment checks passed.
It contains 13 root DEX files and 14 DEX files in total; primary DEX has 61,744
method references under the 65,535 ceiling. Signing is v2 only with exactly one
signer whose certificate SHA-256 is
`317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
All 69 source native libraries were preserved and the sole reviewed addition
remains `lib/arm64-v8a/libhev-socks5-tunnel.so`, SHA-256
`3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`,
with three 16 KiB AArch64 LOAD segments and passing JNI evidence.

Generated-D8 fixture matrices passed at their exact frozen counts: Block
bridge 328/328, report permalink 41/41, proxy bootstrap 13/13, and updater
96/96. Direct inspection of the signed production DEX passed the Block bridge,
permalink, and updater contracts in `classes.dex` and the proxy-bootstrap
contract in `classes6.dex`; the signed update-flow inspection again bound
semantic SHA-256
`d0e8d1ab489ab6241779cb18c21621f3ebd7f17310b36a18d49d6081d7d4d1ed`.
Targeted JADX 1.5.6 recovered and hash-bound all 38 reviewed classes.

Default `Release` correctly records `runtimeValidation: not-run` and has no
`activityUiReview`: the r59 `SignedReview` exact-primary-DEX Activity probe
above is the separate promotion prerequisite and was not rerun. The published
APK has not yet been installed on any device. The earlier r59 `SignedReview`
candidate, SHA-256
`280fa71d00315dbadcece0de5b3fcf19dffd542ee95a8052f979c2dbe86cf9b8` and not
this artifact, launched to the login screen on an arm64-capable emulator
without a crash; two `adb install` attempts of the published artifact onto the
Xiaomi 2310FPCA4G test phone were cancelled by the device's USB-install
confirmation (`INSTALL_FAILED_USER_RESTRICTED`). No runtime fact exists for
the published bytes: no login, scrolling, Block, report, activation-ping
delivery, update, or VPN behaviour was exercised on a device. Neither the
static release gates nor the review probe establish full-app
installation/startup, login, live post/reply scrolling, native Block success,
report or mirror delivery, SOCKS endpoint/authentication or packet coverage,
update download/install, or any real account-changing behavior.

Because the application ID changed, this artifact installs side by side with
any existing `com.threadsmod.barcelona` clone, including the r53 artifact
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
SHA-256
`85124df5d5995af7ca3efd80b1a16f14b0e8fd380fc61e1bfe303b4037708ec4`,
which stays in `dist/` untouched and remains a historical fact described by
the 2026-09-04 revision 53 sections below. The in-app updater cannot bridge
package names and `adb install -r` cannot update across them. No
`threadsmod-update.json` has been published for `app.tree55.threads`; the
backend app-update channel was at that time still bound to
`com.threadsmod.barcelona`; since 2026-09-06 it is bound to `app.tree55.threads`
with bootstrap version code `511407878`. No update metadata was published by
this APK transaction.

For activation statistics, the backend route `POST /v1/installs` was deployed
to the origin on 2026-09-04 (migration `011_installs.sql`) and the AWS relay
allowlist admits exactly `/v1/installs` (Lambda code SHA-256
`3SCxLSR7srBGuYAfIjMu/CF6YHXyGkrQJVgjnBb7kL0=`), so a ping from this build is
accepted end to end. The payload is the closed 13-key set including the
constant schema-version key `v`, and `safeToken` admits the forward slash so
IANA time zones survive intact. That deployment is backend state outside this
APK transaction; no ping from the published bytes has been sent or observed.

## Patchlet 090 revision 57 icon-size, freshest-mirror, and already-completed corrections

Device observation (Threads 444, r56 SignedReview candidate SHA-256
`4ccaec692f2de4c758725ed6e57314a74d384a61b1e7a3dc3cb2cdfdaed707a2` installed
on an arm64 phone, 2026-09-04): the accessibility tree of every post/reply row
contained a `Block user` button node immediately after `Share`, but no pixels
were drawn and a tap produced no modal, diagnostic, or log line. Pristine
`smali_classes2/X/03hH.smali` shows the 444 helper signature
`A00(LX/09jq;LX/09dm;LX/08ub;Ljava/lang/String;Ljava/lang/String;Lkotlin/jvm/functions/Function0;Lkotlin/jvm/functions/Function0;FIIIIIJJZZZZZ)V`
with a float icon-size parameter (`p7`) that the 415 helper lacked; default-mask
bit `0x100` (`and-int/lit16 v6, v3, 0x100`) selects
`const/high16 v24, 0x41900000    # 18.0f`, and the native row passes the same
value from `LX/03gT;->A00:F`. The r13 template passed `const/4 v7, 0x0` with
mask `0xf600`, so the control composed at zero size. Revision 060 r14 uses
`0xf700`; proofs `inline-ufi-icon-size-default-mask-bit` and
`inline-ufi-icon-size-default-value` bind that evidence to this exact source
SHA. A work-local diagnostic rebuild of the r56 tree with only that literal
changed (`work/exp-icon-size-20260904-a`, SHA-256
`804dad7b85f0ca081695a4e9339be56df881a68d57bfe073dca6131a7e3bcfbe`) is
experiment evidence only, not a candidate.

Mirror observation (2026-09-04): GitHub raw and jsDelivr served the same signed
payload dated 2026-08-27 with 511 targets (507 Threads rows); the AWS relay
served 2026-09-03 with 1,592 targets (1,419 Threads rows); the mirror
repository's last automated `publish` commit is 2026-08-27T11:40Z. The r18
first-success loop and the single URL-bound ETag returned before consulting
AWS, which is why Settings showed `Records: 507`. Revision 020 r19 consults
every mirror and installs only the strictly newest verified candidate.

The persisted Activity alert `CB-SCH-105 … bridge=r5` predates the 444 builds:
every 444 candidate's primary DEX contains only `bridge=r6`, and alert text is
rendered once at creation and stored verbatim, so it is a leftover of a Threads
415 build and is cleared with **Activity > Clear notices**. Revision 020 r19
additionally maps a locally completed target to `already_completed` /
`CB-SCH-107` before enqueue, and 060 r14 keeps the scheduler's specific
synchronous refusal stage.

Revision 57's own 2026-09-04 `SignedReview` at
`work/patchlet-444-r57-signed-review-20260904-a`
remains historical evidence about its own frozen inputs. The successful r60
`SignedReview`, the 2026-09-05 `Threads 55` human promotion checkpoint, and the
2026-09-05 revision 59 default `Release` publication recorded above supersede
this checkpoint; the promoted and published series is 010 r5, 020 r21, 050 r16,
060 r14, 070 r10, and 090 r59. The earlier 010 r4 / 020 r20 / 050 r15 / 060 r14
/ 070 r10 / 090 r58 series, and 090 r53 / `SignedReview-i` / `Release-b`, are
historical.

## Patchlet 090 revision 56 Activity UI matcher correction

Revision 56 changes release evidence only; canonical runtime Java, rendered
Smali, host rewrites, and APK behavior are unchanged. Revision 55's
`SignedReview-a` (`work/patchlet-444-r55-signed-review-20260904-a`)
produced a 135,133,736-byte signed work-local candidate with SHA-256
`8678f65c9b7c5368f4a1711117748f6f87be99190a0bdf14f42880ec3ab069a2`.
Its signed-APK `release-check.json`, SHA-256
`64b1403cfb5dde825fec96037a88818050f460d5c2de5d4818daa340b034af48`,
passed. The outer pipeline then failed at `signed-review-activity-ui`; its
`build-report.json`, SHA-256
`1a3baef9d67339e3092594ca5f11d5b249fddddf126f509bd318c152addfc49a`,
records `artifactProduced: false`, verified publication rollback, and runtime
`not-run`. Those bytes and reports are failure-only evidence.

The captured Activity hierarchy contained all five status fields in one
visible multiline node. The r55 probe incorrectly searched for every dynamic
line as an exact raw XML attribute, so it rejected that valid rendering.
Revision 56 replaces only this stale evidence matcher. It accepts at most
1 MiB of DTD-free UI XML with external resolution disabled, derives a nonzero
root viewport, requires every matched node to have nonzero bounds intersecting
that viewport, and matches fixed labels by exact visible node text. Dynamic
status is accepted only when `List fetch:`, `Records:`, `New this refresh:`,
`Database index:`, and `Inline control:` form one contiguous ordered multiline
sequence with a nonempty value after every prefix.

The executable matcher contract contains one positive fixture and nine bypass
negatives: content-description-only, mid-line prefix, wrong prefix order,
missing prefix, malformed XML, zero bounds, offscreen bounds, empty status
value, and split status nodes. Focused report
`work/r56-activity-probe-focused-b.json`,
SHA-256 `c1d7bc800140c64c489e675b6b193a195da222d6699f37e56e0aeade5da9bdc7`,
passed all three probe Activities, exact primary-DEX equality, and the 1/9
fixture contract. This is focused tool evidence only. A fresh complete r56
`SignedReview` remains pending and is the only canonical replay that can
advance promotion or release authority.

Revision 56 otherwise preserves the current exact 328-case signed bridge
matrix: 279 legacy fixtures plus 49 current `single-target` fixtures, one
positive and 48 negatives. The matcher correction neither changes nor waives
that independent release contract.

## Patchlet 090 revision 55 targeted-JADX diagnostic-count correction

Revision 55 changes release evidence only; canonical runtime Java, rendered
Smali, host rewrites, and APK behavior are unchanged. The fresh r54
`SignedReview-a` (`work/patchlet-444-r54-signed-review-20260904-a`)
replayed the exact split set and produced a signed work-local candidate, then
failed closed at the targeted-JADX gate. Pinned JADX 1.5.6 duplicated the shared
`report_request_unavailable` block at two recovered predecessors, so its
readable `InlineActionRowAdapter` contains five
`AutoBlockSync.recordInlineRenderStage(` expressions and two copies of the
unavailable literal. The exact rendered Smali still contains four raw invokes
and exactly one of each of the four fixed diagnostic literals. Revision 55
binds the deterministic recovered counts to 5 and 2 while retaining the raw
4-and-1 source/template proof; readable decompiler duplication is not raw
callsite authority.

The failed run froze source-set SHA-256
`5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`,
derived source SHA-256
`156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`,
resolution SHA-256
`32c268313d72b07a90d8a570907b2c045ee72e1bc09e1d527d4a4bf1996c2efd`,
and canonical patchlet-tree SHA-256
`ce0341a4dedc98410e3cc2e2a62cce876352a28ab79306f8465faafdb608b703`.
Its `work/patchlet-444-r54-signed-review-20260904-a/build-report.json`
has SHA-256
`120b044a9da170c654975514aa3ac5bea0806792f3a0a6d69e901b519e41937c`
and records `artifactProduced: false`, failure at `release-gates`, verified
publication rollback, and runtime `not-run`. The retained 135,133,736-byte
candidate has SHA-256
`6cc3dfc597edb91a23a84b2b4cc4c2c6eebcd324f6d4f8804d25ffb0007e0580`;
it is failure evidence only and is not an installable release claim. A fresh
complete SignedReview is required for the corrected canonical inputs.

## 2026-09-04 revision 53 default Release-b publication

This is a **post-publication documentary append**. The successful pipeline
froze its canonical inputs before this evidence note and the other release
documents were updated. The recorded frozen inputs remain authoritative; the
current documentation-containing tree must not be substituted for them.

Fresh run
`work/patchlet-444-release-20260904-b`
replayed the complete series from split-set SHA-256
`5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`
and deterministic universal source SHA-256
`156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`
against promoted resolution SHA-256
`df092cc0d63e5ca6fb91d24ad9878a520360f1872ed3477182e173e3b3e92221`.
Its frozen canonical `patchlets/**` tree SHA-256 is
`939c0540c5db9d0128a3469ae91a1bd2c512ff4c1a4927f167333e1aa620ecee`.

The default `Release` transaction published
`dist/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
135,133,736 bytes, SHA-256
`85124df5d5995af7ca3efd80b1a16f14b0e8fd380fc61e1bfe303b4037708ec4`.
The run-local signed candidate, published file, build binding, and release
report all contain that exact digest. No `.publishing-*.tmp` residue remains.
The immutable release records are:

| Record | SHA-256 |
|---|---|
| `work/patchlet-444-release-20260904-b/build-report.json` | `8455057b849a6330a98cac0b8db997c7b2ac111e1fcab9ec50b7c4d9653300ad` |
| `work/patchlet-444-release-20260904-b/release-check.json` | `82fc0cd317703a5716a1b64ab572be9d02ca7a7be1487d73ee887982f43626d9` |
| `work/patchlet-444-release-20260904-b/idempotency-check.json` | `abaee7a17ac79e95200f9ddf282f8a426ace09fe100cdffaea26181c76b67ea6` |
| `work/patchlet-444-release-20260904-b/catalog-check.json` | `029299ad23a6b3f087070fd080385c5ec7c6ab625c3ce22618b130ef2ac309bf` |
| `work/patchlet-444-release-20260904-b/resolution-check.json` | `36f9a8d0d94c13f6f4081581ef70cf64ba63f44ca3126212c35f1ccb1f0490ba` |

Both reports record `status: passed`, `validationMode: Release`,
`reviewOnly: false`, `releaseEligible: true`, and `artifactProduced: true`.
The pre-report, pre-publish, and post-publish source/resolution/canonical-asset
freeze checks all matched with zero tree-monitor events. Complete-series
reapplication was content-identical with no exclusions across 124,320 files,
8,163 directories, and 132,483 entries; decoded-tree SHA-256 remained
`6d81d3eef21603cd78314e0555c27ac5127b7892fd2a66eee99cd1d09e92bb55`
before and after.

The published clone is package `com.threadsmod.barcelona`, version code
`511407878`, version name `444.0.0.45.85-threadsmod.1`, minimum SDK 28, target
SDK 36, and arm64-v8a. Archive and 16 KiB alignment checks passed. It contains
13 root DEX files and 14 DEX files in total; primary DEX has 61,693 method
references under the 65,535 ceiling. Signing is v2 only with exactly one signer
whose certificate SHA-256 is
`317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
All 69 source native libraries were preserved byte-identically and the sole
reviewed addition remains
`lib/arm64-v8a/libhev-socks5-tunnel.so`, SHA-256
`3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`,
with three 16 KiB AArch64 LOAD segments and passing JNI evidence.

Generated-D8 fixture matrices passed at their exact frozen counts: Block
bridge 325/325, report permalink 20/20, proxy bootstrap 13/13, and updater
96/96. Direct inspection of the signed production DEX passed the Block bridge,
permalink, proxy-bootstrap, and updater contracts with no false required check.
Targeted JADX 1.5.6 recovered and hash-bound all 38 reviewed classes without a
required/count/order/forbidden mismatch.

Default `Release` correctly records `runtimeValidation: not-run` and has no
`activityUiReview`: the approved SignedReview-i exact-primary-Dex Activity
probe below is the separate promotion prerequisite and was not rerun. Neither
static release establishes full-app installation/startup, login, live
post/reply scrolling, native Block success, report or mirror delivery, SOCKS
endpoint/authentication or packet coverage, update download/install, or any
real account-changing behavior. No update metadata or backend state was
published by this APK transaction.

## 2026-09-04 human promotion checkpoint

The user explicitly approved the exact `SignedReview-i` candidate SHA-256
`abf03f6d37cc7a5ea7dd3406c8d427b985914cec6d3390a3ca21f950fd20800b`
and authorized production of the final release APK. Independent review found no
discrepancy in the frozen signed-review reports or candidate bytes. The exact
resolution was therefore promoted at `2026-09-04T06:22:27+07:00` by changing
only `status` to `verified-current`, `resolvedAt` to that timestamp, and
`release.updateSignedDexReviewRequired` to `false`. The promoted resolution
file SHA-256 is
`df092cc0d63e5ca6fb91d24ad9878a520360f1872ed3477182e173e3b3e92221`.
No runtime Java, rendered Smali, rewrite, semantic proof, patchlet asset, or
review candidate was altered by promotion.

Promotion itself is not a release or publication result. A fresh default
`Release` replay from the pristine exact split set must independently rebuild,
sign, rerun the signed-DEX/archive release gates, and transactionally publish a
new candidate before a final APK can be claimed. The approved
exact-primary-DEX Activity probe remains the separate SignedReview-i promotion
prerequisite recorded below; default `Release` does not rerun that probe.

## Patchlet 090 revision 53 successful SignedReview-i

The fresh pristine replay at
`work/patchlet-444-signed-review-20260904-i`
completed with `status: passed` in `SignedReview` mode. It produced one signed,
work-local review candidate at
`work/patchlet-444-signed-review-20260904-i/release/ThreadsMod-CloneBlocker-444.0.0.45.85-arm64-v8a-update-mod1.apk`,
135,133,736 bytes, SHA-256
`abf03f6d37cc7a5ea7dd3406c8d427b985914cec6d3390a3ca21f950fd20800b`.
The build report deliberately records `reviewOnly: true`,
`releaseEligible: false`, `published: null`, and
`publicationRequested: null`; no matching candidate exists under `dist/`.

The frozen review records are:

| Record | SHA-256 |
|---|---|
| `work/patchlet-444-signed-review-20260904-i/build-report.json` | `b38f6e5cac37ebaad40de4256f0b0cbf2a03a90745fa20e94872a96c83ab1439` |
| `work/patchlet-444-signed-review-20260904-i/release-check.json` | `77ee179e0fb0e18b279210bc65fdb11f8d25ec6aba901ab55d9c4a70d0f7cabc` |
| `work/patchlet-444-signed-review-20260904-i/activity-ui-review.json` | `43c4560996b015eb415709b4256f13d6a9fd46d6757b272403e5f8fe69941821` |
| `work/patchlet-444-signed-review-20260904-i/idempotency-check.json` | `55e8d40328aa55d4bf56ddf8ca5dbb51e7b9c7c68dcd452296a7ad7c2c1b0fde` |
| `work/patchlet-444-signed-review-20260904-i/catalog-check.json` | `c7801a531175b6a1ae4474afdd712a9fb821dd46be953c5caa1f4b8ccafcdbca` |
| `work/patchlet-444-signed-review-20260904-i/resolution-check.json` | `79f9f095ad48e99d2078105228d0709851dea07fbce6f1bf0ece77ad4bbd7e10` |

The source freeze matched the exact three-member split set at SHA-256
`5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff`
and its deterministic universal source at SHA-256
`156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`.
The pre-report lock observed zero tree-monitor events and all 41 canonical
assets remained bound. Reapplying the complete series was a content-identical
no-op across 124,320 files, 8,163 directories, and 132,483 entries; the decoded
tree SHA-256 remained
`6da67dbae226345520569b01cd0ae0f2aea29693a7b335108caa25206e1d3b5c`
before and after, with no exclusions.

The final archive gate passed for clone package `com.threadsmod.barcelona`,
version code `511407878`, version name
`444.0.0.45.85-threadsmod.1`, minimum SDK 28, and target SDK 36. The archive
has 13 root DEX files and 14 DEX files in total. Primary DEX contains 61,693
method references, below the resolution-bound 65,535 ceiling. Archive shape,
16 KiB alignment, and signing checks passed with exactly one signer, v2 only,
certificate SHA-256
`317e3f3813f3b1ec324717faf1bb78f954f49a12122181a85b42338ca10dd079`.
All 69 source native libraries were preserved; the sole reviewed addition is
`lib/arm64-v8a/libhev-socks5-tunnel.so`, SHA-256
`3e46332a5ab97d5e14db869c5dd5945429c6345c80e78d326baa9a14da466099`,
whose three AArch64 LOAD segments each have 16 KiB alignment and whose JNI
contract passed.

Generated-D8 positive and bypass-negative suites passed their exact frozen
counts: Block bridge 325, report permalink 20, proxy bootstrap 13, and updater
96. Direct inspection of the signed candidate also passed the raw-Dex Block
bridge and report-permalink contracts in `classes.dex`, the proxy bootstrap
contract in `classes6.dex`, and the updater contract in `classes.dex`; none of
their required checks was false. Targeted JADX 1.5.6 recovery passed all 38
reviewed classes. The recovered `AutoBlockSync` contains
`currentPassiveMatch(` exactly five times and contains the retired
`isCurrentPassiveMatch(` token zero times. Raw DEX remains authoritative over
readable JADX output.

The isolated no-permission Activity probe used an APK whose primary DEX is
byte-identical to the candidate primary DEX, SHA-256
`9ccf7441e567405f947037267e5fc1c4e779e2e2c3f369a9d3edd9ccfe677caa`.
On the API 37 16 KiB emulator it cold-launched and visibly rendered
`CloneBlockerActivity`, `CloneBlockerSettingsActivity`, and
`ProxySettingsActivity`; all three resumed without a captured crash. The probe
requested no permissions and attempted no account or network action.

This was successful signed-review evidence, not publication or promotion. At
that checkpoint the exact resolution remained `review-required` at
resolution-file SHA-256
`1f98ff27f27456fe915eda71e1519c2a27f8ec4a2890051f0ae771db7125ce57`
with `release.updateSignedDexReviewRequired: true`; the promotion above is the
separate reviewed state transition. The isolated probe does not establish full
candidate installation or startup, login, live
post/reply scrolling, native Block success, report delivery, mirror
reachability, SOCKS endpoint/authentication or packet coverage, update
download/install, or account-changing behavior. A fresh default `Release`
replay remains mandatory before any APK may be published to `dist/`.

## Patchlet 090 revision 53 passive JADX wrapper parity

Revision 53 changes release proof only. Canonical runtime Java, rendered Smali, host rewrites, and APK behavior are unchanged. The exact resolution schema now owns the ordered eleven-string `AutoBlockSync` wrapper baseline ending in `currentPassiveMatch(`. The signed-APK wrapper must contain an AST-proven identical literal array; focused release-contract fixtures reject stale `isCurrentPassiveMatch(`, missing, duplicate, and nonliteral variants before signed evidence can count.

`SignedReview-h` (`work/patchlet-444-signed-review-20260904-h`) is failure-only evidence. Its build report (`work/patchlet-444-signed-review-20260904-h/build-report.json`), SHA-256 `0e12ad3b901b60138be0b7f21ba1cd7131d0eb0481b0ab1765664a4056a658ea`, records `failedStage: release-gates`, `artifactProduced: false`, verified rollback, null output binding, no publication, and runtime `not-run`. The frozen 325-case bridge report passed with SHA-256 `3c5c67893aae7a5db9d76a5a562f55ee9d698d6e60e9f4331e635ef85a972746`; all 38 targeted recoveries had zero required/count/order/forbidden mismatches, and `target-14.java` contains `currentPassiveMatch(` five times. The enclosing wrapper nevertheless required stale `isCurrentPassiveMatch(` and stopped the run. These failed bytes cannot authorize release, installation, or runtime claims. At that checkpoint the resolution remained `review-required` with `updateSignedDexReviewRequired: true` pending a fresh complete r53 `SignedReview`, explicit human promotion, and a fresh default `Release` replay.

## Patchlet 090 revision 52 raw invalid-generation proof

Revision 52 changes release evidence only; it does not change canonical runtime Java, rendered host rewrites, or APK behavior. The three resolution-bound `AutoBlockSync` invalid-generation expressions recovered by JADX 1.5.6 remain secondary readable evidence at exact count one each. Decompiler local names and its rendered exceptional generation of `0L` are not semantic authority and must not override raw signed-primary-DEX registers or handler control flow.

The authoritative bridge gate now proves the actual observed generation from both producers through the shared `IdMatch` callees to all three fail-closed consumers. Direct `loadTarget` and direct `currentPassiveMatch` must pass the lookup result's generation to `latchPassiveStorePause` without clobber. `PassiveLookupWorker` must do the same through one structurally resolved, two-instruction, parameter-preserving synthetic accessor. `BlocklistStore.lookupId` and `isCurrentIdMatch` must preserve their observed wide generation register across the reviewed normal, typed-handler, and catch-all routes rather than synthesize zero. Shared `IdMatch.access$200` must forward its `String` and wide arguments unchanged, and `IdMatch.invalid(String,J)` must store `max(0, observedGeneration)` in the constructed result's generation field.

Ten then-current generated-D8 negatives enforce that path: four consumer call/accessor clobbers, four producer register-clobber/zero-route mutations, and two shared-callee forwarding/clamping mutations. The exact r52 bridge matrix was therefore 325 cases: 279 unchanged legacy regression fixtures plus 46 then-current `single-target` fixtures, comprising one positive and 45 negatives. The frozen r47-r51 315-case reports below remain facts about their exact earlier inputs and do not satisfy that expanded historical gate; the current r56 matrix is the separately governed 328-case contract recorded above.

SignedReview-f remains failure-only evidence. Its build report, `work/patchlet-444-signed-review-20260904-f/build-report.json`, has SHA-256 `e0c59de39d180deb61b4d49424527661747f8961e0f33bf7d7f44ca5b256631c` and records `artifactProduced: false`, failure at `release-gates`, verified publication rollback, and runtime `not-run`. The exact failure was the stale source-local invalid-generation targeted-JADX expectation after the frozen 315-case bridge suite passed. Its retained 135,133,736-byte signed work-only APK has SHA-256 `c9ec5928912d896a7b52147d5be9a4409f143946bcb6218416d524742c79b870`. Those bytes may be replayed only as bounded raw-Dex failure evidence for the new consumer, producer-handler, and shared-callee checks; they cannot validate the revised canonical tools or 325-case matrix and cannot authorize a release, publication, installation, or runtime claim. At that checkpoint this resolution remained `review-required` pending a fresh complete r52 `SignedReview`, human promotion, and fresh default `Release` replay.

## Patchlet 090 revision 51 targeted-JADX visibility-count correction

Revision 51 changes release evidence only; it does not change the visibility callback or APK behavior. The exact resolution-selected Threads 444 template contains three intentional `AutoBlockSync.unregisterVisibleControl(this)` callsites: one guarded lifecycle `release()` path plus unconditional off-main revocation in the geometry and remember entries. The catalog now binds the complete targeted-JADX visibility API tuple to the selected template and reviewed source version: register/update/unregister is `2 / 1 / 3` for Threads 444 and remains `2 / 1 / 1` for historical Threads 415. A dedicated count-drift fixture must fail closed before another signed replay.

The focused r51 resolution report `work/r51-resolution-e-a.json`, SHA-256 `18ff2221618657e3387270287d56a5d4065fce0f0789c17aa22d6c460eba341d`, and catalog report `work/r51-catalog-444-a.json`, SHA-256 `1b2b16fc0e05cf1cc707dc14be5bf7b18c140617c4d0d42f8f234b6289d0b92b`, pass. The complete focused release-contract report `work/r51-release-contract-a.json`, SHA-256 `c30db0d9d52a0cc04a1428b4b520e72475ff372fc8c4dc265bd76f7ec98ec497`, records release-gate revision 51, the Threads 444 `2 / 1 / 3` tuple, and `countDriftRejected: true`. These focused/static checks are not a SignedReview or runtime result.

SignedReview-e remains failure-only evidence. Its build report, `work/patchlet-444-signed-review-20260903-e/build-report.json`, has SHA-256 `b6814ed2a821bfb1e75d5ea8d3519605fe6bf9215fc01f7e61c479b04e0e5ef6` and records `artifactProduced: false`, failure at `release-gates`, and verified publication rollback. The exact failure was `Targeted JADX recovery for 'threadsmod.inlinecontrol.InlineVisibilityCallback' has 3 occurrences of 'AutoBlockSync.unregisterVisibleControl(this)'; expected 1.` Complete-tree idempotency passed across 124,320 files, 8,163 directories, and 132,483 entries at SHA-256 `57d65ee12d2efd3825c43e0ddf09d27076c3a6310711192c5df698a68c1fca26`. The generated-D8 bridge, report-permalink, proxy-bootstrap, and updater fixture reports passed their exact 315, 20, 13, and 96 cases before the mismatch.

The retained 135,133,736-byte work-only APK has SHA-256 `dabb138503beaeb83cab778c29b107ffb6371d51f9e82c653b5a54c3de5592f2`; its 11,623,852-byte primary `classes.dex` has SHA-256 `9ccf7441e567405f947037267e5fc1c4e779e2e2c3f369a9d3edd9ccfe677caa`. No `release-check.json`, Activity UI result, publication move, `dist` artifact, installation, or runtime proof resulted. The resolution remains `review-required`; focused r51 resolution, catalog, and release-contract checks cannot replace a fresh complete r51 `SignedReview`.

## Patchlet 090 revision 50 fixture-absence proof

Revision 50 changes only the release-contract fixture and stable core missing-file diagnostic. PowerShell string binding had converted null fixture content to an empty string, so the earlier `missing-candidate` case created an empty `smali/X/02ja.1.smali` and failed later at class-declaration validation. The helper now preserves null, proves that path is absent before evaluation, and requires the exact missing-file rejection. Both descriptor arrangements, the other ten negatives, and ordinary-path compatibility remain unchanged. No APK, bridge, scheduler, account, or network behavior changes.

The final r50 reports pass against both retained decode arrangements: `work/r50-resolution-c-final-b.json`, SHA-256 `083f39b3da68c45409059d8974a90e547b6eb2f81fb8c62898e9ec0c1c4cee1f`, and `work/r50-resolution-d-final-b.json`, SHA-256 `941acf3951c895e9c12fdae55a21736ddfd7310dbdb701e694d7914c1ea0b86c`. The rebound 444 catalog report `work/r50-catalog-444-final-b.json`, SHA-256 `a84af1aaeffa3720e27bdfa52e3694b0e4874244772b832d07b2c1a57cdee0cd`, passes. The complete release-contract report `work/r50-release-contract-final-b.json`, SHA-256 `6a013fe93b5f3b5e3ca80a04d8daf93e4a4776fd901dfa82dc5170f0d75773bd`, records release-gate revision 50 and proves two positives, 11 negatives, `absentPathVerified: true`, `failureMessageVerified: true`, and ordinary-path compatibility. These are static contract results; status remains `review-required` and a fresh complete SignedReview is still required.

## Patchlet 090 revision 49 descriptor-bound Smali collision proof

SignedReview-d is failure-only evidence. Its build report, `work/patchlet-444-signed-review-20260903-d/build-report.json`, is SHA-256 `512be6e8a96915ccd2da6cd73e4117f04c7a76e353d19d265ee372c02bbea990` and records `artifactProduced: false`, failure at `resolution-check`, and verified publication rollback. The exact split set and deterministic universal APK hashes remained `5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff` and `156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec`. No patch application, signed candidate, release check, publication, or runtime validation followed.

The failure was decoded-filename nondeterminism, not a private-seam change. Apktool 3.0.3 decoded with eight jobs on case-insensitive Windows storage. In SignedReview-c, `LX/02ja;` occupied `smali/X/02ja.smali` and unrelated `LX/02jA;` occupied `02jA.1.smali`; in SignedReview-d the identical class bytes received the opposite suffix assignment, placing `LX/02ja;` in `02ja.1.smali`. Revision 49 names exactly those two candidate paths, selects exactly one target by the exact `.class` descriptor, proves exactly one sibling descriptor, and counts the existing callsite only in the selected target. Focused evaluation passes both retained decoded trees, selecting the unsuffixed path for c and the suffixed path for d with count one. This repairs only the proof mapping and does not turn either failed SignedReview into release evidence.

The final r49 resolution reports for retained decodes c and d are `work/r49-resolution-c-final.json`, SHA-256 `37ccbf429c01d700ad6be696fabb69459a0c366c8dbff405aaf7d51662dd99ce`, and `work/r49-resolution-d-final.json`, SHA-256 `90a1932da1231383a4a665ba402cae9980729c66230f2b9279ca3743d0a7a51f`; both pass all 73 semantic proofs and select the correct target descriptor with count one. The final 444 catalog report `work/r49-catalog-444-final.json`, SHA-256 `276367f354222a8b4ce7fe3cee10dc2f011000769f6fa2593f0b82a6b56ae05a`, passes with executable pins for the proof evaluator, schemas, catalog gate, and release harness. The final release-contract report `work/r49-release-contract-final.json`, SHA-256 `0735adbcfe276da017949b861b25f917581f0444655ac980f50a649cb1aaeb7d`, passes both suffix arrangements, 11 collision bypass negatives, ordinary-path compatibility, and the retained 315 bridge, 20 permalink, 13 proxy-bootstrap, and 96 updater fixture lanes. These are focused static contract results, not a complete fresh `SignedReview`, publication, installation, or runtime result.

## Patchlet 090 revision 48 bridge-evidence rebinding

SignedReview-b stopped earlier in `signed-build` while invoking the Java signing command, which returned exit code 2. Its build report, `work/patchlet-444-signed-review-20260903-b/build-report.json`, is SHA-256 `7dbde98d05e48ad499cf07b8b779f3017a28aaa3916b36c05620eb161d9b1fbe` and records `artifactProduced: false` with publication rollback verified. The retained unsigned APK is 134,536,566 bytes with SHA-256 `8743193af63a238b64a0047961f3c08410228d1ecf7c8a84de5539a17522104d`; the aligned unsigned APK is 135,096,790 bytes with SHA-256 `362a11a195ec9972d066fe46be86acb05342a3beab000b7b51fcf17379ca0c1c`. No signed candidate, release check, publication, or installable artifact resulted. The report intentionally retains no credential value and no more detailed signing diagnostic.

SignedReview-c remains failure-only evidence. Its build report, `work/patchlet-444-signed-review-20260903-c/build-report.json`, is SHA-256 `b22345b03688ff6fd25ba1de1fc908281fde1f0d80c97f0ef87a3bf7e32a4714` and records `artifactProduced: false`, rollback verified, and the failed release-gate message `DEX bridge-flow contract 'threads-block-bridge-flow-v1' returned incomplete evidence.` The retained 135,133,736-byte work-only APK has SHA-256 `001f2328ce10e85026cfaa567ebd846bb68e92edc248149c55340bb689110322`; its primary DEX remains SHA-256 `9ccf7441e567405f947037267e5fc1c4e779e2e2c3f369a9d3edd9ccfe677caa`. There is no release check, publication, or installable artifact from that run.

After the r48 correction, a fresh exact 28-argument replay of the inspector over those same failure-only bytes passes and reports `prepareModel = 2`, `passivePreflight = 1`, and cache lookup/factory/placeholder `2 / 2 / 2`. The focused generated-D8 suite `work/r48-bridge-suite-a-report.json`, SHA-256 `07086ef71b3707038281016b790f875c567799ac06b3c46f6a3b03204d2ca9e2`, passes 315/315. The release-contract preflight `work/r48-release-contract-a-report.json`, SHA-256 `debe38dc412fb3381d3fc71328ed7f7ae26c49787f3bf64b4ea84e2860216b86`, passes with 56 evidence expectations and 27 evidence-negative cases. The focused catalog and resolution reports are SHA-256 `37aaa14ec5f85e64d37552cdde3f7f8a671bb92ab02bd90f74a1ea89f98517c4` and `7bea182a1ea7abf3dc7ce9073fa454d76471006bfd0d35c3cfacd7e0bdd78fb2`. These focused results do not convert SignedReview-c into a passing review; a fresh complete SignedReview is still required.

The retained `work/patchlet-444-signed-review-20260903-c` candidate passed the raw bridge inspector but exposed a stale signed-wrapper mapping: the wrapper expected one bridge-owned `prepareModel` call and one call through each cache lookup/factory/placeholder seam, while the inspector correctly reported two. The ordinary Block path and callback-free passive preflight each traverse the reviewed preparation/cache chain. Revision 48 therefore pins `expectedCacheLookupInvokeCount`, `expectedCacheFactoryInvokeCount`, and `expectedCachePlaceholderInvokeCount` to `2`, retains `expectedPrepareModelInvokeCount = 2` and `expectedPassivePreflightInvokeCount = 1`, and requires the signed wrapper plus current and legacy generated carriers to agree on those counts. It also makes the already-exposed passive-preflight raw, definition, caller-provenance, native-preflight, and fail-closed-match evidence mandatory. This is a release-gate correction, not a relaxation or a new runtime claim; a fresh complete SignedReview is still required.

## Status and review boundary

This resolution is bound to the deterministic universal APK derived from the
three supplied Threads 444 split APKs. Its status is deliberately
`review-required`. The evidence below establishes the split input inventory,
universalization/decode compatibility, exact host symbols, semantic anchors,
template rendering and Smali assembly, and fail-closed rewrite replay. It does
not establish a signed release, installation, login, live scrolling, native
account mutation, report delivery, update download/install, VPN packet
coverage, or device runtime behavior.

Full-project JADX was stopped after it became memory-bound. Private host seams
were instead recovered from the exact decoded Smali and small targeted
readable projections. Raw Smali is authoritative for this resolution.

## Bound split set and universal source

| Input | Bytes | SHA-256 |
|---|---:|---|
| `Threads-444.0.0.45.85/base.apk` | 60,119,977 | `16c2e2c31f7f4481d3a7c4d3e754ceaaef1b22255dab5b8605ef4b7893401b24` |
| `Threads-444.0.0.45.85/split_config.arm64_v8a.apk` | 65,743,557 | `b1af0d13bcf22bd729e489399217c7c4c0549bdcb06e21ca5882c5085fb2eedb` |
| `Threads-444.0.0.45.85/split_config.xhdpi.apk` | 4,307,549 | `11ba8380bd6595a8d4161da3ced7bfa31bae67da688e229d7a3ad42f6970b17c` |
| split-set tree | - | `5c1f06bdda17d5b58677d8941b0264c51135344cc257d93818e6f19d63504bff` |
| deterministic universal unsigned APK | 129,140,327 | `156ae30cef15a2de7ce9bec2637a68a51f0ab2547ae7b7e7ff9541853d9670ec` |

The universal artifact is
`work/split-universalization-probe-444-a/Threads-444.0.0.45.85-merged-unsigned.apk`.
Package metadata is `com.instagram.barcelona`, version code `511407877`,
version name `444.0.0.45.85`, minimum SDK 28, and target SDK 36. It contains
13 root DEX files and 69 arm64 native libraries. The xhdpi split contributes
6,364 resource entries. The source split files were never modified.

The exact decode used for proof is
`work/recon-split-444-merged-20260903-a`. Apktool 3.0.3 rebuilt that pristine
decode as `work/recon-split-444-merged-roundtrip-20260903-a.apk`, SHA-256
`330ff149e581eb04e441f6b3a1bf1692258563f5a906cf34580a75570fe95324`.
The round-trip retained package/version/minimum/target metadata and all 13 DEX
and 69 native libraries with matching uncompressed size and CRC. Apktool added
32 bookkeeping/unknown archive entries; this is a combined-resource archive
shape difference, not byte identity, and remains subject to the normal final
archive/alignment gates.

## DEX inventory and method budget

The method-ID counts below were read directly from offset `0x58` of each DEX
header in the bound universal APK.

| DEX | Bytes | Method IDs | Remaining to 65,535 |
|---|---:|---:|---:|
| `classes.dex` | 9,572,168 | 59,787 | 5,748 |
| `classes2.dex` | 6,014,388 | 41,791 | 23,744 |
| `classes3.dex` | 4,305,744 | 34,594 | 30,941 |
| `classes4.dex` | 7,259,420 | 37,441 | 28,094 |
| `classes5.dex` | 8,866,504 | 28,512 | 37,023 |
| `classes6.dex` | 6,920,084 | 39,300 | 26,235 |
| `classes7.dex` | 6,760,264 | 47,559 | 17,976 |
| `classes8.dex` | 9,770,600 | 54,891 | 10,644 |
| `classes9.dex` | 8,691,572 | 53,110 | 12,425 |
| `classes10.dex` | 4,281,016 | 61,567 | 3,968 |
| `classes11.dex` | 9,642,040 | 61,994 | 3,541 |
| `classes12.dex` | 6,570,620 | 50,362 | 15,173 |
| `classes13.dex` | 39,476 | 461 | 65,074 |

The primary DEX has 5,748 method-reference slots before injection. This is an
inventory, not a final budget pass; the release pipeline must recount the
final primary DEX and enforce the resolution's 65,535 ceiling.

## 415 to 444 private-seam map

| Role | Threads 415 | Threads 444 exact resolution |
|---|---|---|
| Activity session | `BarcelonaActivity.A01` | `BarcelonaActivity.A03` (live in `v6` at the resume hook) |
| Drawer host | `smali_classes3/X/0MO.smali` | `smali_classes3/X/02Gf.smali` and `smali_classes4/X/00sD.smali` |
| Drawer composer/modifier | `LX/8qj;`, `LX/8eh;` | `LX/09dm;`, `LX/08ub;` |
| Drawer row | `LX/0M9.A01` | `LX/02Gc.A02(LX/09dm;LX/08ub;String;Function0;LX/0SBF;IIZ)` |
| User model | `LX/2fp;` | `Lcom/instagram/user/model/User;` |
| Cache lookup | `LX/023.A0f` | `LX/0036.A0a(UserSession,String)` |
| Cache factory/get-or-put | `LX/2gx.A00` / `LX/2gy.A02` | `UserCache.A00` / `UserCache.A05(LX/02ft;,String)` |
| Already blocked | `LX/2gb.A0M` | `UserExtKt.A0I(User)` |
| Mutation callback | `LX/Mwt;` (`DFF`, `DKv`, `Dg7`) | `LX/0LnI;` (`DWP`, `Dan`, `DtY`) |
| Mutation helper | `LX/DNo.A00`, 12 arguments, session before model | `LX/0AND.A00`, 13 arguments, model before session |
| Inline carrier/action row | `LX/0rU;` / `X/0sC` | `LX/03gT;` / `X/03ga.1` |
| Inline style/composer | `LX/8xf;` / `LX/8qj;` | `LX/09jq;` / `LX/09dm;` |
| UFI renderer | `LX/0sH.A00` | `LX/03hH.A00`, 22 contiguous argument registers |
| Media lookup | `LX/023.A0e` | `LX/0005.A0T(UserSession,String)` |
| Visibility modifier | `LX/A2m.A00` | `LX/0Ca6.A00(LX/08ub;,Function1)` |
| Remember observer | `LX/5mg;` | `LX/06sn;` |
| Media/permalink | `LX/6wn;` / `LX/7A4.Bwc` | `Media` / `Media.A7o()` |
| Caption/text | `LX/7A4.B2O` / `LX/6yd.CRt` | `Media.A31()` / `LX/00uR.Ckk()` |
| Proxy bootstrap DEX/next field | `classes10.dex`, `LX/319.A05` | `classes6.dex`, `LX/0143.A06` |

Unchanged semantic anchors include `UserSession`, `User.getId()`, callback
`onCancel`/`onSuccess`, and surface `ig_text_feed_profile`.

## Activity lifecycle hooks

`BarcelonaActivity.onResume` first establishes `A03` as the live
`UserSession`, rejects null, invokes its native resume path, and then reaches
the exact `invoke-super` anchor while `v6` still contains that same session.
The injected call is therefore `ModBootstrap.onResume(p0, v6)`. `onPause`
requires only `p0` and is inserted immediately after its superclass call.
Both anchors occur exactly once in the pristine class.

## Native direct-ID Block bridge

The 444 bridge uses five independently bounded private-seam regions for the
session cast, cache lookup, cache factory, null-seed cache get-or-put, and
guarded dispatch. Each fixed diagnostic literal is outside its private call's
try region.

- `LX/0036.A0a(UserSession,id)` calls the reviewed session `UserCache.A07(id)`.
- On a miss, the rendered bridge passes an exact null `LX/02ft` seed to
  `UserCache.A05(null,id)`; it does not perform profile-info lookup and does not
  construct the placeholder externally. The pristine callsite proof examines
  only `smali/X/02ja.smali` and `smali/X/02ja.1.smali`, then selects whichever
  declares `LX/02ja;`; the other must declare the unrelated `LX/02jA;`
  interface. Apktool may assign the `.1` suffix to either descriptor.
- `UserCache.A05` captures the nullable seed and ID in `LX/00I6`. In
  `LX/00I6.apply`, the null branch executes `new LX/02ft(id)`, reads the cache's
  session, and constructs `User` from that placeholder.
- `LX/02ft.<init>(String)` stores the immutable ID in `A8V`. The `User`
  placeholder path rebinds the same string into `LX/02ft`, and `User.getId()`
  ultimately reads that field. `ThreadsBlockBridge.prepareModel` compares the
  constructed/cached model ID to the immutable target before mutation.
- `UserExtKt.A0I(User)` selects friendship status hash `-0x24c70209`, then
  blocking property hash `-0x279c93cb`, and requires `Boolean.TRUE`.
- `LX/0AND.A00` calls `DWP` before scheduling native work. `LX/07F1` maps the
  failure path containing `post_block_failure` to `Dan` and the success path to
  `onSuccess`; `DtY`, `onCancel`, and terminal dispatch were separately
  recovered in the callback implementations.
- The exact mutation descriptor is
  `LX/0AND;->A00(Context,LX/02fv;,UserSession,LX/0LnI;,Integer,String,String,String,String,String,String,String,int)V`.
  The rendered bridge lays out `v0..v12` as context, model, session, callback,
  null Integer, two surface strings, five null strings, and integer zero, then
  uses one `invoke-static/range`.

Because `.locals 13` makes `p3`/`p4` exceed the nibble-register limit, the 444
template explicitly moves callback/target values into low registers before
all non-range calls. The immutable target copy is outside the narrow
`prepareModel` try. The exact rendered reference is pinned under
`assets/versioned/444.0.0.45.85/bridge-reference`; fresh rendering was
byte-identical to both reference files.

## Dual drawer rows

Threads 444 has two active feed-menu constructors. The resolution adds one
native keyed settings item in each, immediately before its own bottom spacer:

| Host | Receiver | Native spacer key | Rewrite rule |
|---|---|---|---|
| `smali_classes3/X/02Gf.smali` | `p1` | `feed-menu-bottom-spacer` | `drawer-settings-button-hook-v1` |
| `smali_classes4/X/00sD.smali` | `v3` | `feed-menu-bottom-spacer-v2` | `drawer-settings-button-hook-v2` |

Both call `LX/00LT.A01` with key `threadsmod-drawer-settings` and the singleton
`DrawerSettingsItem`. The versioned renderer uses `LX/09ud.A0d` on
`LX/09ud.A02`, renders `Clone Blocker settings` through native
`LX/02Gc.A02`, and its click path can only call the mod settings activity.
The second rewrite includes the preceding `other_feeds` row in its exact
anchor so the applied state cannot also match the pristine spacer suffix.

## Immutable inline snapshot, Share-adjacent control, and visibility

`LX/03gT` owns exactly two injected fields: `threadsmodMediaId` and the
immutable `threadsmodRequest`. In `LX/03gS`, immediately after the exact
`LX/03gT` constructor, the resolution obtains the current `A04` session and
calls one host-owned helper. The binding stores that request and obtains the
carrier ID through the stable `InlineBlockRequest.getMediaKey()` method;
`getMediaId()` is absent from the canonical class and the exact anchor. The
helper resolves, exactly once:

1. displayed media ID from `LX/00LX.CHe()`;
2. media from `LX/0005.A0T(session,mediaId)`;
3. author from `Media.A3N()`;
4. numeric author ID from `User.getId()`;
5. username from `User.A81()`;
6. one `InlineBlockRequest.createHostBound(mediaId,id,username,user,media)`.

The displayed ID's underlying host projection is also bounded: `LX/01AW`
reads `Media.A04.AAP`, the value reaches `LX/01JA` constructor parameter 10
and field `A0H`, and `LX/01cE.CHe()` returns that same field. The constructor
site copies high register `v27` to low scratch `v2` before either injected
`iput-object`, which was confirmed by Smali assembly.

The action-row rule replaces one exact sequence consisting of the native Share
call `LX/03ga.A01(...)` and its next config load. It first preserves the Share
call, then snapshots style `v57`, composer `v0`, config `p3`, request, and the
two native long colors from `v122`/`v120`; it finally invokes exactly one
`InlineActionRowAdapter.render`. The config/request field read aliases through
low `v1` before moving values into the contiguous `v88..v95` call range. There
is no second report sibling or legacy report render/tag in this rewrite.

The versioned inline templates bind native animation `LX/03hU`, UFI renderer
`LX/03hH`, modifier/composer symbols, and one visibility modifier
`LX/0Ca6`. The visibility element `LX/0Ca7` creates node `LX/0Fcm`; node
callback `Dcp(LX/08wx;)` uses attached predicate `D4A` plus clipped-root bounds
`LX/00cZ.A01(...,true)` and `LX/09ay.A07`. `LX/06sn` supplies the remember
lifecycle. Both registration entry points first prove the Android main looper.
An off-main geometry or remember entry clears local state and unconditionally
uses `AutoBlockSync.unregisterVisibleControl`, whose off-main path acquires the
admission lock before the visibility lock; no registration or visible grant is
attempted first. The callback otherwise forwards only the bounded memory
registration/update/unregister calls; database, scheduler, network, and bridge
work stay outside the geometry callback. The row adapter also rejects a null
report request immediately after the factory result and before any Compose
state, click, visibility, or render authority; every valid report-capable Block
state remains visible.

## Reporting media access

The row snapshot retains the exact `Media` object, so the versioned reporting
factory casts only that immutable object. It reads canonical permalink through
`Media.A7o()` and caption through `Media.A31()` followed by interface
`LX/00uR.Ckk()`. Raw host evidence binds `A7o` to backing `Media.A04` field
`LX/00vY.A7e` with the `permalink` semantic literal, and binds `A31` to
`LX/00vY.A2k` with the `caption` literal. The report template therefore does
not repeat media lookup, author lookup, author ID, or username private seams.

## Proxy bootstrap

The exact 444 Application entry is in
`smali_classes6/com/instagram/barcelona/app/BarcelonaAppShell.smali`:
`move v1,p1`, `move v0,p0`, superclass `attachBaseContext(v0,v1)`. The proxy
bootstrap call consumes the same `v1` context immediately after the superclass
call. The original next instruction is the static field read
`LX/0143;->A06:LX/0143;`. The before/after anchors preserve that instruction,
allowing the signed-Dex gate to reject entry-register, adjacency, DEX, or next-
field drift.

The merged manifest does not contain the base split's removed vending-splits
metadata. Proxy components are therefore anchored relative to the fused-module
metadata and its preceding activity-alias terminator. This prevents an applied
anchor from still matching its pristine suffix and composes deterministically
with the Settings activities that follow the fused metadata.

## Clone identity evidence incorporated

`identity-rewrites.json` is the reviewed identity candidate copied verbatim
from `work/identity-444/identity-rewrites.json`; both files had SHA-256
`67d6fa03c542a4c76b88be6a7aff25f7848c82cae6544af895f3aa457ffab758`.
It contains 63 rules and 85 exact replacements: 22 manifest rules/29
replacements, two resource rules/two replacements, and 39 Smali rules/54
replacements.

The resolution structurally binds seven provider authorities and their exact
counts. The AndroidX Startup authority occurs twice; the other six occur once.
It also binds six clone task affinities, including the new
`FeedCarouselBaselShareHandlerActivity` affinity. Five current account-type
representations are bounded across authenticator/runtime paths. The candidate
deliberately retains 77 exact official-package literals in 57 Smali files
where value flow identifies backend/product metadata, official-app probes,
external destinations, or shared string-table use. Component class descriptors
remain in their real `com.instagram...` namespaces because no DEX relocation
is performed.

## Exact validation performed

Patchlet 010 revision 3 and patchlet 050 revision 13 explicitly own the union
of their exact 415 and 444 rewrite-rule alternatives. Catalog validation scans
both reviewed resolution rewrite-set inventories, rejects duplicate owners,
requires every active 444 rule to have one explicit owner, and rejects any
owned rule absent from both reviewed exact versions. Patchlet 060's historical
415-only spacing rule is covered by the same proof without making it active in
the 444 resolution.

- Resolution JSON schema: passed.
- Exact three-member split-set inventory/hash contract: passed.
- Bound universal source SHA-256: matched.
- Pinned apktool, framework, JADX, and APKEditor hashes: matched at proof time.
- Semantic proof set: 73/73 matched against the pristine merged decode.
- Rewrite pristine-state scan: 77/77 rules pristine with no applied anchors.
- First work-tree replay: 77/77 rules applied.
- Second complete replay: 77/77 content-identical no-ops.
- Template render: nine versioned bridge/inline/report/settings Smali files,
  zero unresolved tokens.
- Rendered bridge reference: 2/2 byte-identical to fresh render.
- Report-permalink signed-Dex fixture gate: 444 direct-Media layout passed all
  20 fixtures with the fixed 21-argument contract; the same dynamically
  rendered fixture set also passed all 20 fixtures for the legacy 415 backing-
  interface layout.
- Focused patchlet 060 r12 host contracts accepted the stable `getMediaKey()`
  binding, the non-null immutable report-request guard, and main-only visibility
  registration with lock-serialized off-main revocation; seven targeted
  negative mutations were rejected.
- Focused Smali assembly: all nine rendered templates plus seven rewritten
  host classes compiled into a 210,660-byte DEX with SHA-256
  `472f78d3a17c2fcb2a7bd657db2fb002626149831043a7e0834c32b`.
  The carrier's later aapt2 resource link fails because that intentionally
  minimal carrier has an empty shared-resource package; the Smali stage itself
  completed without diagnostics. The real merged-resource round-trip had
  already built successfully as recorded above.

`Test-Resolution.ps1` was not promoted as a complete pass during the earlier
focused phase while shared signed-DEX fixture tooling was still being updated
in parallel; its asset pin check correctly stopped on a changed fixture tree.
Those shared-tool hashes must be rebound only after the fixture/tool revisions
freeze. This resolution must remain `review-required` until the complete
pristine replay, Java/D8 build, signed-Dex inspectors, archive/native/alignment/
signature/signer gates, and isolated Activity emulator probe pass on the final
candidate.

The shared host-asset gate is source-fixed for the assembled 444 flow.
Because Dalvik field format 22c permits only `v0..v15`, it requires the request
field to load into a low register and then requires exactly one alias into
render register `v91`. The first signed candidate recorded that corrected host
gate but failed later in the signed-Dex bridge verifier, so this source fix does
not promote the resolution or change its `review-required` status.

## First SignedReview replay and r47 correction boundary

The governed replay at
`work/patchlet-444-signed-review-20260903-a` reached a signed candidate only
inside its run-owned `work` directory. Complete-series reapplication was
content-identical across 124,320 files, 8,163 directories, and 132,483 entries,
with tree SHA-256
`ea55b8175e731b9a2ee2bf3e8d66d7959fbf10994eac96d28db9e3f5721294c4`
before and after.

The run then failed closed at `release-gates` with
`automatic_is_current_owner_shape`. Its build report records
`artifactProduced: false`; it has no `release-check.json`, made no publication
move, and created no `dist` artifact. The retained work-only APK is 135,133,736
bytes with SHA-256
`3c1e0c86a8c76f682f1aaf232ff7422c560a64d34899c250cf3836199f6d28d3`.
Its primary `classes.dex` is 11,623,852 bytes with SHA-256
`9ccf7441e567405f947037267e5fc1c4e779e2e2c3f369a9d3edd9ccfe677caa`.
Those bytes are failure evidence only and are not a reviewed or publishable
APK.

Direct inspection showed that the signed candidate already used the intended
immutable one-target owner, while the frozen verifier still expected the
retired mutable batch-owner shape. Patchlet 090 r47 source addresses that stale
verifier assumption and requires `ownerMode: single-target` for production.
Its intended combined bridge suite is exactly 315 cases: 279 legacy regression
cases plus 36 current single-target cases (one positive and 35 negatives). The
current lane covers the four final authority checks before target-budget
admission, passive-running persistence, attempt reservation, and bridge
dispatch; their shared-lock requirement; provisional target-budget cleanup on
every pre-reservation no-dispatch exit; rejection of retained or local target
`List` state and backward same-owner selection edges; and current started,
failure, success, watchdog, and fresh-drain bypasses. The legacy positive remains fixed
at automatic terminal/catch/paced-next counts 5 / 1 / 1; the current positive
and signed production candidate must be 3 / 1 / 0. The r47 release-tool graph
is required to contain exactly six callers, 22 contracts, and 26 invocations.
The focused generated-Smali combined harness report
`work/r47-authority-suite-final315-a-report.json`,
SHA-256 `3781b4e9259906eaff511ddcb706a826156670e0823fa139207e79a140fbfde7`,
records `status: passed` for all 315 fixtures. This is focused fixture evidence,
not a complete signed review or release: no fresh `SignedReview` has yet
validated the exact signed candidate, no human promotion has occurred, and a
fresh normal `Release` replay would still be required after promotion.

## Revision-47 canonical preflight

After the r47 tools, schema, manifest, and exact-resolution pins were rebound,
`Test-PatchletCatalog.ps1` and `Test-Resolution.ps1` passed against this 444
resolution and the exact deterministic merged source. The fresh release-tool
contract run at `work/r47-release-contract-canonical-final-b` also passed. Its
report
`work/r47-release-contract-canonical-final-b.json`
has SHA-256
`1a684966329e68d23390479ab872f68e620f8a5d890919e47341fa1c4b31c45b`.
It records the exact six-caller, 22-contract, 26-invocation graph; 30
mode-specific bridge-evidence expectations; 27 ordered semantic bridge
bindings across four non-crossing current/legacy lanes; and the 315-case
fixture count. Its negative fixtures also passed for invocation, evidence,
lane/binding, inspector-argument, proxy-bootstrap, permalink, update, split
source, path, archive, and publication boundaries.

This is canonical preflight evidence only. It did not rebuild or inspect a new
signed candidate, run the isolated Activity probe, promote the resolution,
publish an APK, install the clone, or exercise account/network/VPN behavior.
The resolution remains `review-required` pending a fresh complete
`SignedReview` and human review.
