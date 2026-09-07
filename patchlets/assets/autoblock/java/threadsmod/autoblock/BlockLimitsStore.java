package threadsmod.autoblock;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/** Validated, all-or-nothing persistence for passive block pacing. */
public final class BlockLimitsStore {
    private static final String PREFS = "threadsmod_autoblock";
    private static final Object LOCK = new Object();
    private static boolean persistenceUncertain;

    public static final String KEY_PASSIVE_MIN_DELAY_MS = "limit_passive_min_delay_ms";
    public static final String KEY_PASSIVE_MAX_DELAY_MS = "limit_passive_max_delay_ms";
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

    private BlockLimitsStore() {}

    /** Missing configuration uses defaults; unreadable or invalid state exposes safe defaults. */
    public static BlockLimits load(Context context) {
        if (context == null) {
            return BlockLimits.defaults();
        }
        synchronized (LOCK) {
            if (persistenceUncertain) {
                return BlockLimits.defaults();
            }
            try {
                return readSnapshot(readAll(preferences(context))).limits;
            } catch (RuntimeException unreadable) {
                persistenceUncertain = true;
                return BlockLimits.defaults();
            }
        }
    }

    /** Missing configuration is valid defaults; partial, mistyped, or invalid state is not. */
    public static boolean isValid(Context context) {
        if (context == null) {
            return false;
        }
        synchronized (LOCK) {
            if (persistenceUncertain) {
                return false;
            }
            try {
                return readSnapshot(readAll(preferences(context))).valid;
            } catch (RuntimeException unreadable) {
                persistenceUncertain = true;
                return false;
            }
        }
    }

    /** Commits one complete validated snapshot; no partial delay pair is ever applied. */
    public static boolean save(Context context, BlockLimits limits) {
        if (context == null || limits == null) {
            return false;
        }
        try {
            BlockLimits.checked(limits.passiveMinDelayMs(), limits.passiveMaxDelayMs());
        } catch (IllegalArgumentException invalid) {
            return false;
        }
        synchronized (LOCK) {
            try {
                SharedPreferences preferences = preferences(context);
                Map<String, ?> before = readAll(preferences);
                boolean wasUncertain = persistenceUncertain;
                // The latch is set before commit because Android may update its process-local
                // map even when disk persistence returns false or throws.
                persistenceUncertain = true;
                SharedPreferences.Editor write = preferences.edit()
                        .putInt(KEY_PASSIVE_MIN_DELAY_MS, limits.passiveMinDelayMs())
                        .putInt(KEY_PASSIVE_MAX_DELAY_MS, limits.passiveMaxDelayMs());
                for (String retiredKey : RETIRED_LIMIT_KEYS) {
                    write.remove(retiredKey);
                }
                boolean committed = write.commit();
                if (committed) {
                    persistenceUncertain = false;
                    return true;
                }

                SharedPreferences.Editor restore = preferences.edit();
                restoreValue(restore, before, KEY_PASSIVE_MIN_DELAY_MS);
                restoreValue(restore, before, KEY_PASSIVE_MAX_DELAY_MS);
                for (String retiredKey : RETIRED_LIMIT_KEYS) {
                    restoreValue(restore, before, retiredKey);
                }
                if (restore.commit()) {
                    persistenceUncertain = wasUncertain;
                }
                return false;
            } catch (RuntimeException persistenceFailure) {
                persistenceUncertain = true;
                return false;
            }
        }
    }

    private static SharedPreferences preferences(Context context) {
        return context.getApplicationContext()
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    private static Map<String, ?> readAll(SharedPreferences preferences) {
        Map<String, ?> values = preferences.getAll();
        if (values == null) {
            throw new IllegalStateException("passive delay preferences returned no snapshot");
        }
        return values;
    }

    private static ReadResult readSnapshot(Map<String, ?> values) {
        boolean hasMinimum = values != null && values.containsKey(KEY_PASSIVE_MIN_DELAY_MS);
        boolean hasMaximum = values != null && values.containsKey(KEY_PASSIVE_MAX_DELAY_MS);
        if (!hasMinimum && !hasMaximum) {
            return new ReadResult(true, BlockLimits.defaults());
        }
        if (!hasMinimum || !hasMaximum
                || !(values.get(KEY_PASSIVE_MIN_DELAY_MS) instanceof Integer)
                || !(values.get(KEY_PASSIVE_MAX_DELAY_MS) instanceof Integer)) {
            return new ReadResult(false, BlockLimits.defaults());
        }
        try {
            return new ReadResult(true, BlockLimits.checked(
                    ((Integer) values.get(KEY_PASSIVE_MIN_DELAY_MS)).intValue(),
                    ((Integer) values.get(KEY_PASSIVE_MAX_DELAY_MS)).intValue()));
        } catch (IllegalArgumentException invalid) {
            return new ReadResult(false, BlockLimits.defaults());
        }
    }

    private static final class ReadResult {
        final boolean valid;
        final BlockLimits limits;

        ReadResult(boolean valid, BlockLimits limits) {
            this.valid = valid;
            this.limits = limits;
        }
    }

    private static void restoreValue(
            SharedPreferences.Editor editor, Map<String, ?> values, String key) {
        if (values == null || !values.containsKey(key)) {
            editor.remove(key);
            return;
        }
        Object value = values.get(key);
        if (value instanceof Integer) {
            editor.putInt(key, ((Integer) value).intValue());
        } else if (value instanceof String) {
            editor.putString(key, (String) value);
        } else if (value instanceof Boolean) {
            editor.putBoolean(key, ((Boolean) value).booleanValue());
        } else if (value instanceof Long) {
            editor.putLong(key, ((Long) value).longValue());
        } else if (value instanceof Float) {
            editor.putFloat(key, ((Float) value).floatValue());
        } else if (value instanceof Set<?>) {
            HashSet<String> copy = new HashSet<String>();
            for (Object member : (Set<?>) value) {
                if (!(member instanceof String)) {
                    editor.remove(key);
                    return;
                }
                copy.add((String) member);
            }
            editor.putStringSet(key, copy);
        } else {
            editor.remove(key);
        }
    }
}
