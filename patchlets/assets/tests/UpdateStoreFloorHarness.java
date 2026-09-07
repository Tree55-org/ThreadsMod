package threadsmod.update;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/** Executes failed-commit anti-rollback repair cases against the production UpdateStore. */
public final class UpdateStoreFloorHarness {
    public static void main(String[] args) {
        FakeContext context = new FakeContext();
        UpdateManifest n = manifest(20L, 2L, 2L, 200L);
        context.preferences.failNextCommit = true;
        assertPersistenceFailure(context, n, "initial N failure");
        assertLoadRejected(context, "first-run uncertain load");
        assertTrue(!UpdateStore.hasRetainedRequiredForEnforcement(1L),
                "first-run failed commit manufactured a required policy");
        assertRejected(context, manifest(19L, 1L, 199L), "stale N-1 after failed N");
        UpdateManifest repaired = UpdateStore.installVerified(context, n, 1L);
        assertTrue(repaired.sameSignedRelease(n), "same N did not repair uncertainty");
        assertTrue(UpdateStore.load(context, 1L).sameSignedRelease(n),
                "same N repair was not readable");

        UpdateManifest n2 = manifest(21L, 3L, 0L, 201L);
        context.preferences.throwNextEdit = true;
        assertPersistenceFailure(context, n2, "thrown edit for N+1");
        assertLoadRejected(context, "replacement/offline uncertain load");
        assertTrue(UpdateStore.hasRetainedRequiredForEnforcement(1L),
                "committed required N was not retained after failed N+1");
        assertRejected(context, n, "previous committed N after failed N+1");
        UpdateManifest higher = manifest(22L, 4L, 2L, 202L);
        repaired = UpdateStore.installVerified(context, higher, 1L);
        assertTrue(repaired.sameSignedRelease(higher),
                "monotonic-higher candidate did not repair uncertainty");
        assertTrue(UpdateStore.load(context, 1L).sameSignedRelease(higher),
                "higher repair was not readable");

        UpdateManifest lowerEnvelope = manifest(30L, 5L, 300L);
        context.preferences.setPolicyState(lowerEnvelope.envelope, 31L, 6L);
        assertRejected(context, manifest(31L, 6L, 301L),
                "equal typed revision repaired envelope-below-typed mismatch");
        UpdateManifest aboveLowerMismatch = manifest(32L, 6L, 301L);
        repaired = UpdateStore.installVerified(context, aboveLowerMismatch, 1L);
        assertTrue(repaired.sameSignedRelease(aboveLowerMismatch),
                "strictly newer envelope-below-typed repair failed");

        UpdateManifest higherEnvelope = manifest(40L, 8L, 400L);
        context.preferences.setPolicyState(higherEnvelope.envelope, 39L, 7L);
        assertRejected(context, higherEnvelope,
                "equal envelope revision repaired envelope-above-typed mismatch");
        UpdateManifest aboveHigherMismatch = manifest(41L, 8L, 400L);
        repaired = UpdateStore.installVerified(context, aboveHigherMismatch, 1L);
        assertTrue(repaired.sameSignedRelease(aboveHigherMismatch),
                "strictly newer envelope-above-typed repair failed");

        UpdateManifest optional = manifest(42L, 9L, 0L, 401L);
        repaired = UpdateStore.installVerified(context, optional, 1L);
        assertTrue(repaired.sameSignedRelease(optional), "optional baseline commit failed");
        UpdateManifest optionalNext = manifest(43L, 10L, 0L, 402L);
        context.preferences.failNextCommit = true;
        assertPersistenceFailure(context, optionalNext, "optional N+1 failure");
        assertTrue(!UpdateStore.hasRetainedRequiredForEnforcement(1L),
                "committed optional policy manufactured a required lock");
        UpdateStore.installVerified(context, optionalNext, 1L);

        System.out.println(
                "PASS update-store-floor false-commit=true thrown-edit=true uncertain-load-rejected=true stale-rejected=true same-repair=true higher-repair=true envelope-below-typed=true envelope-above-typed=true mismatch-equal-rejected=true mismatch-newer-repair=true retained-required=true first-run-no-lock=true optional-no-lock=true");
    }

    private static UpdateManifest manifest(long revision, long modBuild, long versionCode) {
        return manifest(revision, modBuild, 0L, versionCode);
    }

    private static UpdateManifest manifest(
            long revision, long modBuild, long minimumModBuild, long versionCode) {
        return new UpdateManifest(
                revision, modBuild, minimumModBuild, versionCode,
                "release-" + revision, "binary-" + modBuild + "-" + versionCode);
    }

    private static void assertPersistenceFailure(
            FakeContext context, UpdateManifest manifest, String label) {
        try {
            UpdateStore.installVerified(context, manifest, 1L);
        } catch (IllegalStateException expected) {
            return;
        }
        throw new AssertionError(label + " was accepted");
    }

    private static void assertRejected(
            FakeContext context, UpdateManifest manifest, String label) {
        try {
            UpdateStore.installVerified(context, manifest, 1L);
        } catch (SecurityException expected) {
            return;
        }
        throw new AssertionError(label + " was accepted");
    }

    private static void assertLoadRejected(FakeContext context, String label) {
        try {
            UpdateStore.load(context, 1L);
        } catch (IllegalStateException expected) {
            return;
        }
        throw new AssertionError(label + " was accepted");
    }

    private static void assertTrue(boolean value, String message) {
        if (!value) throw new AssertionError(message);
    }

    private static final class FakeContext extends Context {
        final FakePreferences preferences = new FakePreferences();

        @Override public SharedPreferences getSharedPreferences(String name, int mode) {
            return preferences;
        }
    }

    private static final class FakePreferences implements SharedPreferences {
        private final Map<String, Object> values = new HashMap<String, Object>();
        boolean failNextCommit;
        boolean throwNextEdit;

        @Override public Map<String, ?> getAll() {
            return new HashMap<String, Object>(values);
        }

        @Override public Editor edit() {
            if (throwNextEdit) {
                throwNextEdit = false;
                throw new IllegalStateException("fixture edit failure");
            }
            return new FakeEditor();
        }

        void setPolicyState(String envelope, long revision, long modBuild) {
            values.clear();
            values.put(UpdateStore.KEY_ENVELOPE, envelope);
            values.put(UpdateStore.KEY_REVISION, revision);
            values.put(UpdateStore.KEY_MOD_BUILD, modBuild);
        }

        private final class FakeEditor implements Editor {
            private final Map<String, Object> pending = new HashMap<String, Object>();
            private final Set<String> removed = new HashSet<String>();

            @Override public Editor putString(String key, String value) {
                pending.put(key, value);
                return this;
            }

            @Override public Editor putStringSet(String key, Set<String> value) {
                pending.put(key, new HashSet<String>(value));
                return this;
            }

            @Override public Editor putInt(String key, int value) {
                pending.put(key, value);
                return this;
            }

            @Override public Editor putLong(String key, long value) {
                pending.put(key, value);
                return this;
            }

            @Override public Editor putFloat(String key, float value) {
                pending.put(key, value);
                return this;
            }

            @Override public Editor putBoolean(String key, boolean value) {
                pending.put(key, value);
                return this;
            }

            @Override public Editor remove(String key) {
                removed.add(key);
                return this;
            }

            @Override public boolean commit() {
                if (failNextCommit) {
                    failNextCommit = false;
                    return false;
                }
                for (String key : removed) values.remove(key);
                values.putAll(pending);
                return true;
            }
        }
    }
}
