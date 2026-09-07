package android.content;

import java.util.Map;
import java.util.Set;

/** Minimal host-test surface matching the value types used by BlockLimitsStore. */
public interface SharedPreferences {
    Map<String, ?> getAll();

    Editor edit();

    interface Editor {
        Editor putString(String key, String value);
        Editor putStringSet(String key, Set<String> values);
        Editor putInt(String key, int value);
        Editor putLong(String key, long value);
        Editor putFloat(String key, float value);
        Editor putBoolean(String key, boolean value);
        Editor remove(String key);
        boolean commit();
    }
}
