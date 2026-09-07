# Resolve split-source universalization

Use this task only to propose a new exact split APK source set and its deterministic standalone patch input. Do not edit the canonical resolution or production tree.

Inputs:

- the pristine APK delivery directory;
- a fresh run directory;
- the repository-pinned APKEditor JAR;
- the current catalog and schemas.

Required proposal evidence:

1. Enumerate every APK recursively and reject nested, missing, extra, duplicate, or renamed members. Record each exact leaf name, semantic role, byte size, SHA-256, package/version, split name, split type, `hasCode`, and signer lineage.
2. Record the aggregate APK-only tree SHA-256 using the repository tree-hash algorithm. Non-APK installer helpers are not source-set members.
3. Prove one base member, the selected ABI member, and the selected density member satisfy the reviewed device target. Do not silently discard another required split.
4. Bind APKEditor and ARSCLib versions, the JAR SHA-256, and the exact ordered merge arguments `m -i {sourceSet} -o {outputApk} -clean-meta -validate-modules -extractNativeLibs false`.
5. Run two merges into fresh paths. Require byte-identical outputs and propose their exact derived SHA-256 as `/source/sha256`.
6. Compare source and output ZIP entry paths and bytes. Prove all root DEX files, all selected-ABI native libraries, and all selected-density resource payloads are preserved. Report exact counts.
7. Use AAPT2 to prove the merged package/version/SDK values and density configurations, `extractNativeLibs=false`, and absence of `split`, `splitTypes`, `requiredSplitTypes`, and Play split-delivery metadata.
8. Prove the derived APK is unsigned. Signing belongs later in the normal release pipeline.
9. Return proposal JSON and bounded evidence only. A human must review any changed member topology, resource behavior, native ABI choice, SDK value, or merge-tool drift before promotion.

Never decode/rebuild a resource split with Apktool and never perform a raw ZIP graft. Both lose the reviewed semantic resource-table merge contract.
