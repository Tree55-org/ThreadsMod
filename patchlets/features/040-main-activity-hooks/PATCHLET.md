# 040 — Main activity lifecycle hooks

This patchlet adds one stable bootstrap call after the reviewed `BarcelonaActivity.onResume()` superclass call and one after its `onPause()` superclass call.

The resume call passes the activity and the already-proven non-null `UserSession` register to `ModBootstrap.onResume`. The pause call passes only the activity to `ModBootstrap.onPause`. Future features should extend the stable bootstrap/feature registry instead of adding unrelated hooks to the obfuscated activity.

## Exact anchor contract

`hook-rewrites.json` points to complete before/after anchor files and declares an exact count of one. The engine applies the same two-state rule used by identity rewrites:

- exact before only: apply;
- exact after only: idempotent no-op;
- both, neither or any count drift: stop.

Line numbers are not anchors. The active resolution records the activity path and descriptor, session field/type, live register, proof snippets and rationale. All must bind to the exact source APK SHA-256.

## AI boundary

On a future build, AI may rank candidates for the launcher activity, lifecycle methods and session-bearing register using deterministic evidence. It may not inject code, change register counts, assume a register remains live, or select a null/unauthenticated session path. The imported proposal must include a fresh before/after anchor and a liveness/non-null proof.

## Gates

- Each hook after-anchor occurs exactly once.
- Resume and pause call the stable bootstrap descriptors exactly once.
- The selected session register is proven live and non-null at the resume anchor.
- Smali assembly succeeds.
- Targeted decompilation recovers the intended calls.
- Applying the patchlet again changes no file.

If lifecycle shape or session ownership changes, the correct outcome is a drift report and no APK—not a nearby best-effort insertion.
