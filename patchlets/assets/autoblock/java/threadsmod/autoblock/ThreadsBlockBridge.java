package threadsmod.autoblock;

import android.app.Activity;

/**
 * Compile-time stub. The generated smali is replaced by a direct bridge to the
 * obfuscated Threads classes, whose names cannot all be expressed in Java.
 */
public final class ThreadsBlockBridge {
    private ThreadsBlockBridge() {}

    /**
     * Compile-time shape for the exact-SHA Smali preflight. A null result means
     * the reviewed native model is not currently blocked; every non-null result
     * is either the internal already-blocked sentinel or a fixed bridge stage.
     */
    public static String passivePreflight(Object userSession, String targetId) {
        return "bridge_stub";
    }

    public static void block(
            Activity activity,
            Object userSession,
            String targetId,
            BridgeCallback callback) {
        BridgeCallbackDispatcher.failure(callback, targetId, "bridge_stub");
    }

    public static void blockResolved(
            Activity activity,
            Object userSession,
            Object resolvedAuthorModel,
            String targetId,
            BridgeCallback callback) {
        if (resolvedAuthorModel == null) {
            block(activity, userSession, targetId, callback);
            return;
        }
        BridgeCallbackDispatcher.failure(callback, targetId, "bridge_stub");
    }
}
