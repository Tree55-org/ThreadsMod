package android.content;

/** Minimal host-test surface used only to execute SharedPreferences-backed patchlet code. */
public abstract class Context {
    public static final int MODE_PRIVATE = 0;

    public Context getApplicationContext() {
        return this;
    }

    public abstract SharedPreferences getSharedPreferences(String name, int mode);
}
