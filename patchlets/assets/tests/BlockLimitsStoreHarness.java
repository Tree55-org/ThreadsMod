package threadsmod.autoblock;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.ArrayDeque;
import java.util.Arrays;
import java.util.Deque;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;

/** Executable host-JVM proof for atomic passive-delay persistence and rollback. */
public final class BlockLimitsStoreHarness {
    private static final String[] LIMIT_KEYS = new String[] {
            BlockLimitsStore.KEY_PASSIVE_MIN_DELAY_MS,
            BlockLimitsStore.KEY_PASSIVE_MAX_DELAY_MS
    };
    private static final String[] RETIRED_LIMIT_KEYS = new String[] {
            "limit_manual_min_delay_ms",
            "limit_manual_max_delay_ms",
            "limit_automatic_min_delay_ms",
            "limit_automatic_max_delay_ms",
            "limit_automatic_per_hour",
            "limit_target_budget",
            "limit_total_per_hour",
            "limit_total_per_day",
            "limit_max_per_run"
    };

    private BlockLimitsStoreHarness() {}

    public static void main(String[] args) {
        verifyKeyTopology();
        verifyMissingDefaults();
        verifyRetiredKeysHaveNoReadAuthority();
        verifyAtomicSuccess();
        verifyRetiredKeysRestoredOnRollback();
        verifyRollback("integer", validIntegerSnapshot());
        verifyRollback("string", uniformSnapshot("corrupt"));
        verifyRollback("boolean", uniformSnapshot(Boolean.TRUE));
        verifyRollback("long", uniformSnapshot(Long.valueOf(7L)));
        verifyRollback("float", uniformSnapshot(Float.valueOf(1.5f)));
        verifyRollback("string-set", uniformSnapshot(
                new HashSet<String>(Arrays.asList("corrupt", "evidence"))));
        verifyRollback("missing", new LinkedHashMap<String, Object>());
        verifyPartialIntegerSnapshotsFailClosed();
        verifyWrongTypeSnapshotsFailClosed();
        verifyInvalidIntegerSnapshotsFailClosed();
        verifyRollbackCommitFailureLatchesUncertainty();
        verifyReadExceptionsFailClosed();
        System.out.println(
                "PASS passive-limits-store keys=2 retired=9 retired-authority=false deletion-only=true atomic=true rollback=all-types partial=true wrong-type=true invalid=true uncertainty=true read-errors=true failclosed=true");
    }

    private static void verifyKeyTopology() {
        require(LIMIT_KEYS.length == 2, "exact live key count");
        require(RETIRED_LIMIT_KEYS.length == 9, "exact retired key count");
        Set<String> liveKeys = new HashSet<String>(Arrays.asList(LIMIT_KEYS));
        Set<String> retiredKeys = new HashSet<String>(Arrays.asList(RETIRED_LIMIT_KEYS));
        require(liveKeys.size() == LIMIT_KEYS.length, "live keys unique");
        require(retiredKeys.size() == RETIRED_LIMIT_KEYS.length, "retired keys unique");
        for (String retiredKey : retiredKeys) {
            require(!liveKeys.contains(retiredKey), "retired key has no live authority " + retiredKey);
        }
    }

    private static void verifyMissingDefaults() {
        FakeContext context = new FakeContext();
        require(BlockLimitsStore.isValid(context), "missing snapshot validity");
        requireSame(BlockLimits.defaults(), BlockLimitsStore.load(context),
                "missing snapshot defaults");
    }

    private static void verifyRetiredKeysHaveNoReadAuthority() {
        FakeContext context = new FakeContext();
        for (int index = 0; index < RETIRED_LIMIT_KEYS.length; index++) {
            context.preferences.seed(RETIRED_LIMIT_KEYS[index], "retired-" + index);
        }
        Map<String, ?> before = context.preferences.getAll();
        require(BlockLimitsStore.isValid(context), "retired-only snapshot validity");
        requireSame(BlockLimits.defaults(), BlockLimitsStore.load(context),
                "retired-only snapshot defaults");
        require(before.equals(context.preferences.getAll()),
                "retired-only read does not rewrite storage");
        require(context.preferences.editCount == 0, "retired-only read uses no editor");
        require(context.preferences.commitCount == 0, "retired-only read uses no commit");
    }

    private static void verifyAtomicSuccess() {
        FakeContext context = new FakeContext();
        context.preferences.seed("unrelated", "preserved");
        for (int index = 0; index < RETIRED_LIMIT_KEYS.length; index++) {
            context.preferences.seed(RETIRED_LIMIT_KEYS[index], Integer.valueOf(index + 1));
        }
        BlockLimits expected = BlockLimits.checked(2000, 7000);
        require(BlockLimitsStore.save(context, expected), "successful save result");
        require(context.preferences.editCount == 1, "successful save uses one editor");
        require(context.preferences.commitCount == 1, "successful save uses one commit");
        require("threadsmod_autoblock".equals(context.lastName), "preference file name");
        require(context.lastMode == Context.MODE_PRIVATE, "private preference mode");
        require(BlockLimitsStore.isValid(context), "successful snapshot validity");
        requireSame(expected, BlockLimitsStore.load(context), "successful snapshot values");
        require("preserved".equals(context.preferences.getAll().get("unrelated")),
                "unrelated preference preserved");
        for (String key : LIMIT_KEYS) {
            require(context.preferences.getAll().get(key) instanceof Integer,
                    "successful exact integer type for " + key);
        }
        for (String retiredKey : RETIRED_LIMIT_KEYS) {
            require(!context.preferences.getAll().containsKey(retiredKey),
                    "successful save deletes retired key " + retiredKey);
        }
    }

    private static void verifyRetiredKeysRestoredOnRollback() {
        Map<String, Object> before = validIntegerSnapshot();
        for (int index = 0; index < RETIRED_LIMIT_KEYS.length; index++) {
            Object value;
            switch (index % 6) {
                case 0:
                    value = Integer.valueOf(index + 1);
                    break;
                case 1:
                    value = "retired-" + index;
                    break;
                case 2:
                    value = Boolean.valueOf((index & 1) == 0);
                    break;
                case 3:
                    value = Long.valueOf(100L + index);
                    break;
                case 4:
                    value = Float.valueOf(index + 0.5f);
                    break;
                default:
                    value = new HashSet<String>(Arrays.asList("retired", "key-" + index));
                    break;
            }
            before.put(RETIRED_LIMIT_KEYS[index], value);
        }
        verifyRollback("integer", before);
    }

    private static void verifyRollback(String label, Map<String, Object> before) {
        FakeContext context = new FakeContext();
        context.preferences.seedAll(before);
        Map<String, ?> expected = context.preferences.getAll();
        context.preferences.commitResults(false, true);
        require(!BlockLimitsStore.save(context, BlockLimits.defaults()),
                label + " failed save result");
        require(context.preferences.editCount == 2, label + " rollback editor count");
        require(context.preferences.commitCount == 2, label + " rollback commit count");
        require(expected.equals(context.preferences.getAll()),
                label + " rollback exact snapshot");
        if (before.isEmpty()) {
            require(BlockLimitsStore.isValid(context), label + " missing snapshot restored");
        } else if ("integer".equals(label)) {
            require(BlockLimitsStore.isValid(context), label + " valid snapshot restored");
            requireSame(snapshotLimits(before), BlockLimitsStore.load(context),
                    label + " integer values restored");
        } else {
            require(!BlockLimitsStore.isValid(context),
                    label + " corrupt evidence remains fail-closed");
        }
    }

    private static void verifyPartialIntegerSnapshotsFailClosed() {
        for (String missingKey : LIMIT_KEYS) {
            Map<String, Object> partial = validIntegerSnapshot();
            partial.remove(missingKey);
            verifyStoredSnapshotInvalid("partial integer " + missingKey, partial);
        }
    }

    private static void verifyWrongTypeSnapshotsFailClosed() {
        for (String wrongTypeKey : LIMIT_KEYS) {
            Map<String, Object> wrongType = validIntegerSnapshot();
            wrongType.put(wrongTypeKey, "wrong-type");
            verifyStoredSnapshotInvalid("wrong type " + wrongTypeKey, wrongType);
        }
    }

    private static void verifyInvalidIntegerSnapshotsFailClosed() {
        verifyStoredIntegerInvalid("minimum below range", LIMIT_KEYS[0], 1000);
        verifyStoredIntegerInvalid("minimum above range", LIMIT_KEYS[0], 61000);
        verifyStoredIntegerInvalid("minimum off step", LIMIT_KEYS[0], 2500);
        verifyStoredIntegerInvalid("maximum below range", LIMIT_KEYS[1], 2000);
        verifyStoredIntegerInvalid("maximum above range", LIMIT_KEYS[1], 61000);
        verifyStoredIntegerInvalid("maximum off step", LIMIT_KEYS[1], 3500);

        Map<String, Object> inverted = validIntegerSnapshot();
        inverted.put(LIMIT_KEYS[0], Integer.valueOf(4000));
        verifyStoredSnapshotInvalid("inverted ordering", inverted);
    }

    private static void verifyStoredIntegerInvalid(String label, String key, int value) {
        Map<String, Object> invalid = validIntegerSnapshot();
        invalid.put(key, Integer.valueOf(value));
        verifyStoredSnapshotInvalid(label, invalid);
    }

    private static void verifyStoredSnapshotInvalid(String label, Map<String, Object> invalid) {
        FakeContext context = new FakeContext();
        context.preferences.seedAll(invalid);
        Map<String, ?> before = context.preferences.getAll();
        require(!BlockLimitsStore.isValid(context), label + " validity");
        requireSame(BlockLimits.defaults(), BlockLimitsStore.load(context),
                label + " safe load");
        require(before.equals(context.preferences.getAll()), label + " remains unchanged");
    }

    private static void verifyRollbackCommitFailureLatchesUncertainty() {
        FakeContext context = new FakeContext();
        Map<String, Object> before = validIntegerSnapshot();
        context.preferences.seedAll(before);
        BlockLimits replacement = BlockLimits.checked(3000, 7000);
        context.preferences.commitBehavior(false, true);
        context.preferences.commitBehavior(false, false);
        require(!BlockLimitsStore.save(context, replacement),
                "double failed commit result");
        require(Integer.valueOf(3000).equals(
                context.preferences.getAll().get(BlockLimitsStore.KEY_PASSIVE_MIN_DELAY_MS)),
                "failed rollback may leave replacement visible in process map");
        require(!BlockLimitsStore.isValid(context),
                "uncertainty latch blocks exposed replacement");
        requireSame(BlockLimits.defaults(), BlockLimitsStore.load(context),
                "uncertainty latch returns safe display values");

        BlockLimits recovery = BlockLimits.checked(4000, 8000);
        context.preferences.commitBehavior(false, true);
        context.preferences.commitBehavior(true, true);
        require(!BlockLimitsStore.save(context, recovery),
                "failed full save with successful rollback remains unsuccessful");
        require(!BlockLimitsStore.isValid(context),
                "successful rollback cannot clear prior uncertainty");
        require(BlockLimitsStore.save(context, recovery), "later full save recovers uncertainty");
        require(BlockLimitsStore.isValid(context), "successful recovery clears uncertainty");
        requireSame(recovery, BlockLimitsStore.load(context), "recovered snapshot");
    }

    private static void verifyReadExceptionsFailClosed() {
        FakeContext context = new FakeContext();
        context.preferences.seedAll(validIntegerSnapshot());
        context.preferences.throwOnNextGetAll();
        require(!BlockLimitsStore.isValid(context), "isValid read exception");
        require(!BlockLimitsStore.isValid(context), "read exception latches uncertainty");
        require(BlockLimitsStore.save(context, BlockLimits.defaults()),
                "successful save clears validity-read uncertainty");

        context.preferences.throwOnNextGetAll();
        requireSame(BlockLimits.defaults(), BlockLimitsStore.load(context),
                "load read exception fallback");
        require(!BlockLimitsStore.isValid(context), "load exception latches uncertainty");
        require(BlockLimitsStore.save(context, BlockLimits.defaults()),
                "successful save clears load-read uncertainty");

        context.preferences.throwOnNextGetAll();
        require(!BlockLimitsStore.save(context, BlockLimits.defaults()),
                "save snapshot read exception");
        require(!BlockLimitsStore.isValid(context), "save read exception latches uncertainty");
        require(BlockLimitsStore.save(context, BlockLimits.defaults()),
                "later save clears save-read uncertainty");

        context.preferences.returnNullOnNextGetAll();
        require(!BlockLimitsStore.isValid(context), "null snapshot fails closed");
        require(!BlockLimitsStore.isValid(context), "null snapshot latches uncertainty");
        require(BlockLimitsStore.save(context, BlockLimits.defaults()),
                "later save clears null-read uncertainty");
    }

    private static Map<String, Object> uniformSnapshot(Object value) {
        Map<String, Object> values = new LinkedHashMap<String, Object>();
        for (String key : LIMIT_KEYS) {
            values.put(key, copyValue(value));
        }
        return values;
    }

    private static Map<String, Object> validIntegerSnapshot() {
        Map<String, Object> values = new LinkedHashMap<String, Object>();
        values.put(LIMIT_KEYS[0], Integer.valueOf(2000));
        values.put(LIMIT_KEYS[1], Integer.valueOf(3000));
        return values;
    }

    private static BlockLimits snapshotLimits(Map<String, Object> values) {
        return BlockLimits.checked(
                integer(values, LIMIT_KEYS[0]),
                integer(values, LIMIT_KEYS[1]));
    }

    private static int integer(Map<String, Object> values, String key) {
        return ((Integer) values.get(key)).intValue();
    }

    private static void requireSame(BlockLimits expected, BlockLimits actual, String label) {
        List<Integer> expectedValues = values(expected);
        List<Integer> actualValues = values(actual);
        require(expectedValues.equals(actualValues), label + " expected=" + expectedValues
                + " actual=" + actualValues);
    }

    private static List<Integer> values(BlockLimits limits) {
        return Arrays.asList(
                Integer.valueOf(limits.passiveMinDelayMs()),
                Integer.valueOf(limits.passiveMaxDelayMs()));
    }

    private static Object copyValue(Object value) {
        if (value instanceof Set<?>) {
            return new HashSet<Object>((Set<?>) value);
        }
        return value;
    }

    private static void require(boolean value, String label) {
        if (!value) {
            throw new AssertionError(label);
        }
    }

    private static final class FakeContext extends Context {
        final FakeSharedPreferences preferences = new FakeSharedPreferences();
        String lastName;
        int lastMode = -1;

        @Override
        public SharedPreferences getSharedPreferences(String name, int mode) {
            lastName = name;
            lastMode = mode;
            return preferences;
        }
    }

    private static final class FakeSharedPreferences implements SharedPreferences {
        private Map<String, Object> values = new LinkedHashMap<String, Object>();
        private final Deque<Boolean> commitResults = new ArrayDeque<Boolean>();
        private final Deque<Boolean> commitApplies = new ArrayDeque<Boolean>();
        private int getAllFailures;
        private int getAllNulls;
        int editCount;
        int commitCount;

        void seed(String key, Object value) {
            values.put(key, copyValue(value));
        }

        void seedAll(Map<String, Object> source) {
            values = deepCopy(source);
        }

        void commitResults(boolean... results) {
            for (boolean result : results) {
                commitBehavior(result, true);
            }
        }

        void commitBehavior(boolean result, boolean applyProcessMap) {
            commitResults.addLast(Boolean.valueOf(result));
            commitApplies.addLast(Boolean.valueOf(applyProcessMap));
        }

        void throwOnNextGetAll() {
            getAllFailures++;
        }

        void returnNullOnNextGetAll() {
            getAllNulls++;
        }

        @Override
        public Map<String, ?> getAll() {
            if (getAllFailures > 0) {
                getAllFailures--;
                throw new IllegalStateException("simulated getAll failure");
            }
            if (getAllNulls > 0) {
                getAllNulls--;
                return null;
            }
            return deepCopy(values);
        }

        @Override
        public Editor edit() {
            editCount++;
            return new FakeEditor(this);
        }

        private static Map<String, Object> deepCopy(Map<String, ?> source) {
            Map<String, Object> copy = new LinkedHashMap<String, Object>();
            for (Map.Entry<String, ?> entry : source.entrySet()) {
                copy.put(entry.getKey(), copyValue(entry.getValue()));
            }
            return copy;
        }
    }

    private static final class FakeEditor implements SharedPreferences.Editor {
        private final FakeSharedPreferences owner;
        private final Map<String, Object> changes = new HashMap<String, Object>();
        private final Set<String> removals = new HashSet<String>();

        FakeEditor(FakeSharedPreferences owner) {
            this.owner = owner;
        }

        @Override
        public SharedPreferences.Editor putString(String key, String value) {
            return put(key, value);
        }

        @Override
        public SharedPreferences.Editor putStringSet(String key, Set<String> values) {
            return put(key, values == null ? null : new HashSet<String>(values));
        }

        @Override
        public SharedPreferences.Editor putInt(String key, int value) {
            return put(key, Integer.valueOf(value));
        }

        @Override
        public SharedPreferences.Editor putLong(String key, long value) {
            return put(key, Long.valueOf(value));
        }

        @Override
        public SharedPreferences.Editor putFloat(String key, float value) {
            return put(key, Float.valueOf(value));
        }

        @Override
        public SharedPreferences.Editor putBoolean(String key, boolean value) {
            return put(key, Boolean.valueOf(value));
        }

        @Override
        public SharedPreferences.Editor remove(String key) {
            changes.remove(key);
            removals.add(key);
            return this;
        }

        @Override
        public boolean commit() {
            Map<String, Object> next = FakeSharedPreferences.deepCopy(owner.values);
            for (String key : removals) {
                next.remove(key);
            }
            for (Map.Entry<String, Object> change : changes.entrySet()) {
                next.put(change.getKey(), copyValue(change.getValue()));
            }
            boolean applyProcessMap = owner.commitApplies.isEmpty()
                    || owner.commitApplies.removeFirst().booleanValue();
            if (applyProcessMap) {
                owner.values = next;
            }
            owner.commitCount++;
            return owner.commitResults.isEmpty()
                    || owner.commitResults.removeFirst().booleanValue();
        }

        private SharedPreferences.Editor put(String key, Object value) {
            removals.remove(key);
            changes.put(key, copyValue(value));
            return this;
        }
    }
}
