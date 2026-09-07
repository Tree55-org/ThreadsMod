package threadsmod.update;

import android.content.Context;
import android.content.SharedPreferences;

/** Typed, synchronously committed storage for the last verified update policy. */
final class UpdateStore {
    static final int CURRENT_BINARY_MISMATCH = 0;
    static final int CURRENT_BINARY_ACTION_SUCCEEDED = 1;
    static final int CURRENT_BINARY_ACTION_FAILED = 2;
    static final String PREFS = "threadsmod_update";
    static final String KEY_ENVELOPE = "update_verified_envelope";
    static final String KEY_REVISION = "update_revision";
    static final String KEY_MOD_BUILD = "update_mod_build";
    static final String KEY_CHECK_NOT_BEFORE = "update_check_not_before";
    static final String KEY_DISMISSED_REVISION = "update_dismissed_revision";
    private static final int MAX_ENVELOPE_CHARS = 24 * 1024;
    private static boolean policyPersistenceUncertain;
    private static UpdateManifest policyPersistenceFloor;
    private static UpdateManifest lastVerifiedManifestForEnforcement;
    private static boolean cadencePersistenceUncertain;
    private static boolean dismissalPersistenceUncertain;

    private UpdateStore() {}

    interface CurrentBinaryAction {
        boolean run();
    }

    static synchronized UpdateManifest load(Context context, long nowMs) {
        try {
            if (policyPersistenceUncertain) {
                throw new IllegalStateException("update policy persistence is uncertain");
            }
            SharedPreferences preferences = prefs(context);
            java.util.Map<String, ?> all = preferences.getAll();
            Object rawEnvelope = all.get(KEY_ENVELOPE);
            Object rawRevision = all.get(KEY_REVISION);
            Object rawModBuild = all.get(KEY_MOD_BUILD);
            if (rawEnvelope == null && rawRevision == null && rawModBuild == null) return null;
            if (!(rawEnvelope instanceof String) || !(rawRevision instanceof Long)
                    || !(rawModBuild instanceof Long)) {
                throw new IllegalStateException("update manifest state is corrupt");
            }
            String envelope = (String) rawEnvelope;
            if (envelope.length() == 0 || envelope.length() > MAX_ENVELOPE_CHARS) {
                throw new IllegalStateException("update manifest state is corrupt");
            }
            UpdateManifest manifest = UpdateManifest.parseStored(envelope);
            if (manifest.revision != (Long) rawRevision
                    || manifest.modBuild != (Long) rawModBuild) {
                throw new IllegalStateException("update manifest binding is corrupt");
            }
            lastVerifiedManifestForEnforcement = manifest;
            return manifest;
        } catch (RuntimeException invalidState) {
            throw invalidState;
        } catch (Exception invalidState) {
            throw new IllegalStateException("update manifest state is invalid", invalidState);
        }
    }

    static synchronized UpdateManifest installVerified(
            Context context, UpdateManifest candidate, long nowMs) {
        if (candidate == null) throw new IllegalArgumentException("candidate");
        if (policyPersistenceUncertain) {
            if (policyPersistenceFloor == null) {
                throw new IllegalStateException("update policy persistence floor is unavailable");
            }
            requireMonotonicCandidate(candidate, policyPersistenceFloor);
        }
        SharedPreferences preferences = prefs(context);
        java.util.Map<String, ?> all;
        try {
            all = preferences.getAll();
        } catch (Throwable unreadable) {
            throw new IllegalStateException("update rollback state is unreadable", unreadable);
        }
        Object rawEnvelope = all.get(KEY_ENVELOPE);
        Object rawRevision = all.get(KEY_REVISION);
        Object rawModBuild = all.get(KEY_MOD_BUILD);
        boolean hasPolicyState = rawEnvelope != null || rawRevision != null || rawModBuild != null;
        if (hasPolicyState && (!(rawRevision instanceof Long) || (Long) rawRevision <= 0L
                || !(rawModBuild instanceof Long) || (Long) rawModBuild <= 0L)) {
            throw new IllegalStateException("update rollback floors are corrupt");
        }
        long revisionFloor = typedNonNegativeLong(rawRevision);
        long modBuildFloor = typedNonNegativeLong(rawModBuild);
        UpdateManifest envelopeFloor = null;
        if (rawEnvelope instanceof String) {
            try {
                envelopeFloor = UpdateManifest.parseStored((String) rawEnvelope);
            } catch (Throwable ignoredCorruptEnvelope) {
                // The separately typed floors below still constrain a live signed repair.
            }
        }
        boolean exactEnvelopeBinding = envelopeFloor != null
                && envelopeFloor.revision == revisionFloor
                && envelopeFloor.modBuild == modBuildFloor;
        long strongestRevisionFloor = envelopeFloor == null
                ? revisionFloor : Math.max(revisionFloor, envelopeFloor.revision);
        if (envelopeFloor != null) {
            if (candidate.revision < envelopeFloor.revision
                    || candidate.modBuild < envelopeFloor.modBuild) {
                throw new SecurityException("update manifest rollback rejected");
            }
            if (candidate.revision == envelopeFloor.revision
                    && !candidate.sameSignedRelease(envelopeFloor)) {
                throw new SecurityException("update manifest revision conflicts");
            }
            if (candidate.modBuild == envelopeFloor.modBuild
                    && !candidate.sameBinary(envelopeFloor)) {
                throw new SecurityException("update policy changes existing binary identity");
            }
            if (candidate.modBuild > envelopeFloor.modBuild
                    && candidate.versionCode <= envelopeFloor.versionCode) {
                throw new SecurityException("update version code rollback rejected");
            }
        }
        if (hasPolicyState && !exactEnvelopeBinding
                && candidate.revision <= strongestRevisionFloor) {
            throw new SecurityException("update manifest repair requires newer revision");
        }
        if (revisionFloor >= 0L && candidate.revision < revisionFloor
                || modBuildFloor >= 0L && candidate.modBuild < modBuildFloor) {
            throw new SecurityException("update manifest rollback rejected");
        }
        UpdateManifest previous = null;
        try {
            previous = load(context, nowMs);
        } catch (Throwable corruptEnvelope) {
            // A highest live signed manifest may repair corrupt envelope state. Independently
            // readable typed lower bounds above remain authoritative.
        }
        if (previous != null) {
            if (candidate.revision < previous.revision
                    || candidate.modBuild < previous.modBuild) {
                throw new SecurityException("update manifest rollback rejected");
            }
            if (candidate.revision == previous.revision) {
                if (!candidate.sameSignedRelease(previous)) {
                    throw new SecurityException("update manifest revision conflicts");
                }
                return previous;
            }
            if (candidate.modBuild == previous.modBuild && !candidate.sameBinary(previous)) {
                throw new SecurityException("update policy changes existing binary identity");
            }
            if (candidate.modBuild > previous.modBuild
                    && candidate.versionCode <= previous.versionCode) {
                throw new SecurityException("update version code rollback rejected");
            }
        }
        policyPersistenceFloor = candidate;
        policyPersistenceUncertain = true;
        boolean saved;
        try {
            saved = preferences.edit()
                    .putString(KEY_ENVELOPE, candidate.envelope)
                    .putLong(KEY_REVISION, candidate.revision)
                    .putLong(KEY_MOD_BUILD, candidate.modBuild)
                    .commit();
        } catch (Throwable failedCommit) {
            throw new IllegalStateException("update manifest persistence failed", failedCommit);
        }
        if (!saved) throw new IllegalStateException("update manifest persistence failed");
        lastVerifiedManifestForEnforcement = candidate;
        policyPersistenceUncertain = false;
        policyPersistenceFloor = null;
        return candidate;
    }

    static synchronized boolean hasRetainedRequiredForEnforcement(long currentModBuild) {
        if (!policyPersistenceUncertain || currentModBuild <= 0L) return false;
        UpdateManifest retained = lastVerifiedManifestForEnforcement;
        return retained != null && currentModBuild < retained.minimumModBuild;
    }

    private static void requireMonotonicCandidate(
            UpdateManifest candidate, UpdateManifest floor) {
        if (candidate.revision < floor.revision || candidate.modBuild < floor.modBuild) {
            throw new SecurityException("update manifest rollback rejected");
        }
        if (candidate.revision == floor.revision
                && !candidate.sameSignedRelease(floor)) {
            throw new SecurityException("update manifest revision conflicts");
        }
        if (candidate.modBuild == floor.modBuild && !candidate.sameBinary(floor)) {
            throw new SecurityException("update policy changes existing binary identity");
        }
        if (candidate.modBuild > floor.modBuild
                && candidate.versionCode <= floor.versionCode) {
            throw new SecurityException("update version code rollback rejected");
        }
    }

    static synchronized int runIfCurrentBinary(
            Context context, long nowMs, UpdateManifest expected,
            CurrentBinaryAction action) {
        if (expected == null || action == null) {
            throw new IllegalArgumentException("current update binary action is invalid");
        }
        UpdateManifest latest = load(context, nowMs);
        if (latest == null || !latest.sameBinary(expected)) {
            return CURRENT_BINARY_MISMATCH;
        }
        return action.run()
                ? CURRENT_BINARY_ACTION_SUCCEEDED : CURRENT_BINARY_ACTION_FAILED;
    }

    private static long typedNonNegativeLong(Object value) {
        return value instanceof Long && (Long) value >= 0L ? (Long) value : -1L;
    }

    static synchronized long checkNotBefore(Context context, long nowMs, long maximumFutureMs) {
        try {
            if (cadencePersistenceUncertain) {
                throw new IllegalStateException("update cadence persistence is uncertain");
            }
            Object raw = prefs(context).getAll().get(KEY_CHECK_NOT_BEFORE);
            if (raw == null) return 0L;
            if (!(raw instanceof Long)) throw new IllegalStateException("update cadence state is corrupt");
            long value = (Long) raw;
            if (value < 0L || value > nowMs + maximumFutureMs) {
                throw new IllegalStateException("update cadence state is corrupt");
            }
            return value;
        } catch (RuntimeException invalidState) {
            throw invalidState;
        } catch (Throwable invalidState) {
            throw new IllegalStateException("update cadence state is unreadable", invalidState);
        }
    }

    static synchronized boolean setCheckNotBefore(Context context, long value) {
        if (value <= 0L) return false;
        cadencePersistenceUncertain = true;
        try {
            boolean saved = prefs(context).edit()
                    .putLong(KEY_CHECK_NOT_BEFORE, value).commit();
            if (saved) cadencePersistenceUncertain = false;
            return saved;
        } catch (Throwable ignored) {
            return false;
        }
    }

    static synchronized long dismissedRevision(Context context) {
        try {
            if (dismissalPersistenceUncertain) {
                throw new IllegalStateException("update dismissal persistence is uncertain");
            }
            Object raw = prefs(context).getAll().get(KEY_DISMISSED_REVISION);
            if (raw == null) return 0L;
            if (!(raw instanceof Long) || (Long) raw < 0L) {
                throw new IllegalStateException("update dismissal state is corrupt");
            }
            return (Long) raw;
        } catch (RuntimeException invalidState) {
            throw invalidState;
        } catch (Throwable invalidState) {
            throw new IllegalStateException("update dismissal state is unreadable", invalidState);
        }
    }

    static synchronized boolean dismiss(Context context, long revision) {
        if (revision <= 0L) return false;
        dismissalPersistenceUncertain = true;
        try {
            boolean saved = prefs(context).edit()
                    .putLong(KEY_DISMISSED_REVISION, revision).commit();
            if (saved) dismissalPersistenceUncertain = false;
            return saved;
        } catch (Throwable ignored) {
            return false;
        }
    }

    private static SharedPreferences prefs(Context context) {
        return context.getApplicationContext().getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }
}
